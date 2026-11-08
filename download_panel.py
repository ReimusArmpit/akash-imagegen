#!/usr/bin/env python3
"""
download_panel.py -- web UI for pulling individual models into Forge-Neo.

WHY THIS EXISTS
---------------
The original download_extras.py is an interactive menu (input() calls). There is
no TTY inside an Akash container, so it dies with EOFError before downloading
anything. Piping stdin works but is useless for picking "this one checkpoint and
these two LoRAs" -- and the FAVORITES category alone is ~50 GB.

This is a small FastAPI app that:
  * lists every model in models.json with its real size and what's already
    downloaded
  * lets you pick exact items and download only those
  * enforces a disk quota so a download cannot fill the container and take down
    the running UI
  * shows live progress per file
  * deletes models to reclaim space

Runs on 127.0.0.1:7861 and is published through the same Caddy proxy as
Forge-Neo and FileBrowser (see Caddyfile.akash).

Run:  python3 download_panel.py --models models.json --dest ~/forge-neo/models
"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import threading
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import HTMLResponse, JSONResponse

try:
    import diag
except ImportError as _diag_exc:  # pragma: no cover - defensive
    # The diagnostics page is a nice-to-have; the download panel is the point
    # of this process. If diag.py is missing (a stale image, a half-copied
    # /work), degrade to a panel that reports diag as unavailable rather than
    # refusing to start at all.
    diag = None
    _DIAG_ERROR = str(_diag_exc)
from pydantic import BaseModel

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

# Categories in display order, with the human label used in the original menu.
CATEGORY_LABELS: dict[str, str] = {
    "f": "Favorites",
    "1": "Illustrious Models",
    "2": "Anima Models",
    "3": "Noob Models",
    "4": "Misc Models / VAEs",
    "5": "Illustrious LoRAs - Characters",
    "6": "Illustrious LoRAs - Styles & Concepts",
    "7": "Illustrious LoRAs - NSFW",
    "8": "Noob LoRAs",
    "9": "Anima LoRAs",
}

# Prefix -> where it lives under models/.
PATH_PREFIX_LABELS = {
    "Stable-diffusion": "Checkpoint",
    "Lora": "LoRA",
    "VAE": "VAE",
    "text_encoder": "Text encoder",
    "text_encoders": "Text encoder",
    "clip": "CLIP",
    "ControlNet": "ControlNet",
    "ESRGAN": "Upscaler",
}


def category_key_for_menu_code(code: str) -> str | None:
    """Map the original menu's codes onto the models.json keys."""
    return {
        "f": "FAVORITES",
        "1": "ILLUSTRIOUS_MODELS",
        "2": "ANIMA_MODELS",
        "3": "NOOB_MODELS",
        "4": "MISC",
        "5": "ILLUS_CHARS",
        "6": "ILLUS_STYLES",
        "7": "ILLUS_NSFW",
        "8": "NOOB_LORAS",
        "9": "ANIMA_LORAS",
    }.get(code)


# ---------------------------------------------------------------------------
# Download state
# ---------------------------------------------------------------------------


@dataclass
class Task:
    """One download in flight or finished."""

    key: str
    name: str
    url: str
    path: str
    total: int = 0
    done: int = 0
    status: str = "queued"  # queued|running|done|error|cancelled
    error: str = ""
    started: float = field(default_factory=time.time)

    @property
    def pct(self) -> int:
        return int(self.done * 100 / self.total) if self.total else 0

    def as_dict(self) -> dict[str, Any]:
        return {
            "key": self.key,
            "name": self.name,
            "path": self.path,
            "total": self.total,
            "done": self.done,
            "pct": self.pct,
            "status": self.status,
            "error": self.error,
            "elapsed": round(time.time() - self.started, 1),
        }


class Store:
    """Holds the model catalogue plus live download state.

    A single lock guards mutations; the download workers only ever touch their
    own Task, so the API never blocks on a 7 GB transfer.
    """

    def __init__(self, models_path: Path, dest: Path, quota_gb: float,
                 log_dir: Path | None = None) -> None:
        self.models_path = models_path
        self.dest = dest
        self.quota_bytes = int(quota_gb * 1024**3)
        # Where the entrypoint writes neo.log, panel.log, filebrowser.log, etc.
        # Defaults to a sibling of the models dir, which is where the
        # entrypoint puts it ($WORK/logs next to $WORK/models).
        self.log_dir = log_dir or (dest.parent / "logs")
        self.lock = threading.Lock()
        self.tasks: dict[str, Task] = {}
        self.catalogue: dict[str, list[dict[str, Any]]] = {}
        self._load()

    def _load(self) -> None:
        if not self.models_path.exists():
            raise SystemExit(f"models.json not found at {self.models_path}")
        with self.models_path.open() as fh:
            raw = json.load(fh)
        for key, items in raw.items():
            if not isinstance(items, list):
                continue
            out = []
            for idx, item in enumerate(items):
                if not isinstance(item, dict):
                    continue
                path = item.get("path", "")
                out.append(
                    {
                        "id": f"{key}:{idx}",
                        "category": key,
                        "name": item.get("name", path),
                        "url": item.get("url", ""),
                        "path": path,
                        "kind": path.split("/")[0] if "/" in path else "file",
                        "size": 0,  # filled lazily via HEAD
                    }
                )
            self.catalogue[key] = out

    # -- disk helpers -------------------------------------------------------

    def free_bytes(self) -> int:
        try:
            return shutil.disk_usage(self.dest if self.dest.exists() else Path("/")).free
        except OSError:
            return 0

    def local_path(self, rel: str) -> Path:
        return self.dest / rel

    def is_downloaded(self, rel: str) -> bool:
        p = self.local_path(rel)
        try:
            return p.exists() and p.stat().st_size > 0
        except OSError:
            return False

    def local_size(self, rel: str) -> int:
        try:
            return self.local_path(rel).stat().st_size
        except OSError:
            return 0

    # -- catalogue ----------------------------------------------------------

    def list_items(self, category: str | None, kind: str | None, search: str) -> list[dict[str, Any]]:
        """Return catalogue entries enriched with local state."""
        out: list[dict[str, Any]] = []
        needle = search.strip().lower()
        for key, items in self.catalogue.items():
            if category and key != category:
                continue
            for item in items:
                if kind and item["kind"] not in kind:
                    continue
                if needle and needle not in item["name"].lower() and needle not in item["path"].lower():
                    continue
                rec = dict(item)
                rec["downloaded"] = self.is_downloaded(item["path"])
                rec["local_size"] = self.local_size(item["path"])
                rec["in_progress"] = item["id"] in self.tasks and self.tasks[item["id"]].status in ("queued", "running")
                out.append(rec)
        return out

    def categories(self) -> list[dict[str, Any]]:
        seen: dict[str, int] = {}
        for key, items in self.catalogue.items():
            seen[key] = len(items)
        rows = []
        for code, label in CATEGORY_LABELS.items():
            k = category_key_for_menu_code(code)
            if k and k in seen:
                rows.append({"code": code, "label": label, "key": k, "count": seen[k]})
        # Any catalogue key not covered by the legacy menu codes.
        mapped = {category_key_for_menu_code(c) for c in CATEGORY_LABELS}
        for key, n in seen.items():
            if key not in mapped:
                rows.append({"code": "", "label": key.replace("_", " ").title(), "key": key, "count": n})
        return rows

    def kinds(self) -> list[str]:
        found: set[str] = set()
        for items in self.catalogue.values():
            for i in items:
                found.add(i["kind"])
        return sorted(found)

    # -- downloads ----------------------------------------------------------

    def queue(self, ids: list[str]) -> tuple[int, list[str]]:
        """Queue downloads. Returns (accepted_count, rejection_reasons)."""
        accepted = 0
        rejected: list[str] = []
        by_id = {i["id"]: i for items in self.catalogue.values() for i in items}
        for ident in ids:
            item = by_id.get(ident)
            if item is None:
                rejected.append(f"{ident}: not in catalogue")
                continue
            with self.lock:
                if ident in self.tasks and self.tasks[ident].status in ("queued", "running"):
                    rejected.append(f"{item['name']}: already in progress")
                    continue
                if self.is_downloaded(item["path"]):
                    rejected.append(f"{item['name']}: already downloaded")
                    continue
            task = Task(key=ident, name=item["name"], url=item["url"], path=item["path"])
            with self.lock:
                self.tasks[ident] = task
            threading.Thread(target=self._run_download, args=(task,), daemon=True).start()
            accepted += 1
        return accepted, rejected

    def _head_size(self, url: str) -> int:
        """Get the remote size without downloading the body."""
        try:
            out = subprocess.run(
                ["curl", "-sIL", "--max-time", "20", url],
                capture_output=True, text=True, timeout=30,
            ).stdout
            size = 0
            for line in out.splitlines():
                low = line.lower()
                if low.startswith("x-linked-size:") or low.startswith("content-length:"):
                    try:
                        val = int(line.split(":", 1)[1].strip())
                    except ValueError:
                        continue
                    # Prefer x-linked-size; content-length of the redirect is
                    # sometimes the same value, sometimes not.
                    if low.startswith("x-linked-size:"):
                        return val
                    size = max(size, val)
            return size
        except Exception:
            return 0

    def _run_download(self, task: Task) -> None:
        task.status = "running"
        dest = self.local_path(task.path)
        try:
            dest.parent.mkdir(parents=True, exist_ok=True)
        except OSError as exc:
            task.status = "error"
            task.error = f"mkdir failed: {exc}"
            return

        task.total = self._head_size(task.url)

        # Quota guard: refuse if this file alone would blow the budget.
        free = self.free_bytes()
        if self.quota_bytes and task.total:
            used = 0
            for root, _dirs, files in os.walk(self.dest):
                for f in files:
                    try:
                        used += os.path.getsize(os.path.join(root, f))
                    except OSError:
                        pass
            if used + task.total > self.quota_bytes:
                task.status = "error"
                task.error = (
                    f"quota exceeded: need {task.total/1e9:.1f} GB, "
                    f"{used/1e9:.1f} GB used of {self.quota_bytes/1e9:.0f} GB budget"
                )
                return

        # aria2c is much faster than curl for these (8 connections, resume),
        # but it is also fussier: it parses http_proxy/https_proxy/ftp_proxy
        # from the environment itself and aborts on formats it does not
        # understand, and it cannot always resolve a proxy host. When it
        # fails, fall back to curl rather than reporting a dead download.
        part = dest.with_suffix(dest.suffix + ".part")

        def run_curl() -> subprocess.Popen:
            ccmd = ["curl", "-L", "--fail", "--retry", "3", "--retry-delay", "2",
                    "-C", "-", "-o", str(part), task.url]
            if os.getenv("HF_TOKEN"):
                ccmd[1:1] = ["-H", f"Authorization: Bearer {os.environ['HF_TOKEN']}"]
            return subprocess.Popen(ccmd, stdout=subprocess.PIPE,
                                    stderr=subprocess.STDOUT, text=True)

        def run_aria() -> subprocess.Popen:
            acmd = [
                "aria2c", "--allow-overwrite=true", "--file-allocation=none",
                "-x", "8", "-s", "8", "-k", "5M", "--summary-interval=1",
                "--console-log-level=warn",
                "-d", str(dest.parent), "-o", dest.name,
            ]
            # aria2c does not honour the http_proxy environment variables the
            # way curl does. Pass the proxy explicitly when one is configured,
            # and drop the *_proxy vars aria2c would otherwise choke on.
            proxy = os.getenv("https_proxy") or os.getenv("HTTPS_PROXY") or os.getenv("http_proxy")
            env = dict(os.environ)
            for var in ("ftp_proxy", "FTP_PROXY"):
                env.pop(var, None)
            if proxy:
                acmd.append(f"--all-proxy={proxy}")
            if os.getenv("HF_TOKEN"):
                acmd.append(f"--header=Authorization: Bearer {os.environ['HF_TOKEN']}")
            acmd.append(task.url)
            return subprocess.Popen(acmd, stdout=subprocess.PIPE,
                                    stderr=subprocess.STDOUT, text=True, env=env)

        used_aria = True
        try:
            proc = run_aria()
        except FileNotFoundError:
            used_aria = False
            proc = run_curl()

        def pump(p: subprocess.Popen) -> int:
            """Read progress output until the process exits."""
            assert p.stdout is not None
            for line in p.stdout:
                if task.status == "cancelled":
                    p.kill()
                    break
                parts = line.split()
                nums = [x for x in parts if x.replace(".", "", 1).isdigit()]
                if len(nums) >= 2:
                    try:
                        task.done = int(float(nums[-2]) * 1024 * 1024)
                        task.total = max(task.total, int(float(nums[-1]) * 1024 * 1024))
                    except ValueError:
                        pass
            return p.wait()

        rc = pump(proc)

        # aria2c failed -> retry once with curl. curl honours the proxy
        # environment natively and is the more reliable path here.
        if used_aria and rc != 0 and task.status != "cancelled":
            used_aria = False
            task.error = ""
            task.done = 0
            try:
                proc = run_curl()
                rc = pump(proc)
            except Exception as exc:
                task.status = "error"
                task.error = str(exc)
                return

        if task.status == "cancelled":
            return

        # The curl fallback writes to .part; promote it on success. aria2c
        # writes the final name directly.
        if not used_aria and part.exists():
            try:
                if dest.exists():
                    dest.unlink()
                part.replace(dest)
            except OSError as exc:
                task.status = "error"
                task.error = f"could not rename download: {exc}"
                return

        if rc == 0 and dest.exists() and dest.stat().st_size > 0:
            task.done = dest.stat().st_size
            task.status = "done"
        else:
            task.status = "error"
            task.error = f"exit {rc}"
            try:
                if part.exists():
                    part.unlink()
            except OSError:
                pass

    def cancel(self, ident: str) -> bool:
        with self.lock:
            task = self.tasks.get(ident)
            if task and task.status in ("queued", "running"):
                task.status = "cancelled"
                return True
        return False

    def delete(self, rel: str) -> tuple[bool, str]:
        p = self.local_path(rel)
        if not p.exists():
            return False, "not found"
        try:
            p.unlink()
            return True, "deleted"
        except OSError as exc:
            return False, str(exc)

    def status(self) -> dict[str, Any]:
        used = 0
        for root, _dirs, files in os.walk(self.dest):
            for f in files:
                try:
                    used += os.path.getsize(os.path.join(root, f))
                except OSError:
                    pass
        with self.lock:
            tasks = [t.as_dict() for t in self.tasks.values()]
        return {
            "free": self.free_bytes(),
            "used": used,
            "quota": self.quota_bytes,
            "tasks": tasks,
        }


# ---------------------------------------------------------------------------
# API
# ---------------------------------------------------------------------------

app = FastAPI(title="Forge-Neo Download Panel", docs_url=None, redoc_url=None)


class QueueRequest(BaseModel):
    ids: list[str]


@app.get("/api/diag")
def api_diag() -> JSONResponse:
    """System diagnostics: GPU, disk, memory, processes, log tails.

    This is the answer to "the UI is up but something is wrong and I cannot
    see what". Neo shows its own Gradio errors and this panel shows download
    state, but neither shows whether the GPU is the one that was paid for,
    whether the root filesystem is about to fill, or why the container last
    restarted -- because that all goes to container stdout, which is only
    reachable through the provider's CLI.

    Nothing here is cached: every call re-reads /proc and re-tails the logs,
    so a failing service shows up immediately.
    """
    if diag is None:
        return JSONResponse(
            {"error": "diag module unavailable", "detail": _DIAG_ERROR},
            status_code=503,
        )
    return JSONResponse(diag.collect(Path(store.log_dir), store.dest))


@app.get("/api/state")
def api_state() -> JSONResponse:
    return JSONResponse(store.status())


@app.get("/api/categories")
def api_categories() -> JSONResponse:
    return JSONResponse({"categories": store.categories(), "kinds": store.kinds()})


@app.get("/api/models")
def api_models(category: str | None = None, kind: str | None = None, q: str = "") -> JSONResponse:
    items = store.list_items(category, kind, q)
    return JSONResponse({"items": items, "count": len(items)})


@app.post("/api/queue")
def api_queue(req: QueueRequest) -> JSONResponse:
    if not req.ids:
        raise HTTPException(400, "no ids given")
    accepted, rejected = store.queue(req.ids)
    return JSONResponse({"accepted": accepted, "rejected": rejected})


@app.post("/api/cancel")
def api_cancel(req: QueueRequest) -> JSONResponse:
    ok = [i for i in req.ids if store.cancel(i)]
    return JSONResponse({"cancelled": ok})


@app.post("/api/delete")
def api_delete(req: QueueRequest) -> JSONResponse:
    # ids here are "category:index" -- resolve to paths server side.
    by_id = {i["id"]: i for items in store.catalogue.values() for i in items}
    results = []
    for ident in req.ids:
        item = by_id.get(ident)
        if item is None:
            results.append({"id": ident, "ok": False, "error": "unknown id"})
            continue
        ok, msg = store.delete(item["path"])
        results.append({"id": ident, "ok": ok, "error": msg})
    return JSONResponse({"results": results})


# ---------------------------------------------------------------------------
# UI
# ---------------------------------------------------------------------------

PAGE = r"""<!doctype html>
<html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Model Downloads</title>
<style>
 :root{--bg:#12141a;--panel:#1b1e26;--line:#2b3040;--fg:#e6e8ee;--dim:#9aa1b2;
       --acc:#5b8cff;--ok:#3fb950;--err:#f85149;--warn:#d29922}
 *{box-sizing:border-box}
 body{margin:0;font:14px/1.5 system-ui,-apple-system,Segoe UI,sans-serif;background:var(--bg);color:var(--fg)}
 header{padding:14px 20px;border-bottom:1px solid var(--line);display:flex;gap:20px;align-items:center;flex-wrap:wrap;background:var(--panel)}
 h1{font-size:16px;margin:0;font-weight:600}
 .stat{font-size:12px;color:var(--dim)}
 .stat b{color:var(--fg)}
 .grow{flex:1}
 .wrap{padding:16px 20px;max-width:1400px;margin:0 auto}
 .bar{height:6px;background:var(--line);border-radius:3px;overflow:hidden;margin:6px 0}
 .bar>i{display:block;height:100%;background:var(--acc);width:0;transition:width .3s}
 .bar.ok>i{background:var(--ok)} .bar.err>i{background:var(--err)}
 .filters{display:flex;gap:8px;flex-wrap:wrap;margin-bottom:12px;align-items:center}
 select,input[type=search]{background:var(--panel);border:1px solid var(--line);color:var(--fg);
   padding:7px 10px;border-radius:6px;font:inherit}
 input[type=search]{flex:1;min-width:180px}
 button{background:var(--acc);border:0;color:#fff;padding:7px 13px;border-radius:6px;cursor:pointer;font:inherit;font-weight:500}
 button:disabled{opacity:.45;cursor:not-allowed}
 button.ghost{background:transparent;border:1px solid var(--line);color:var(--fg)}
 button.danger{background:var(--err)}
 table{width:100%;border-collapse:collapse;font-size:13px}
 th{text-align:left;color:var(--dim);font-weight:500;padding:7px 8px;border-bottom:1px solid var(--line);font-size:12px;white-space:nowrap}
 td{padding:7px 8px;border-bottom:1px solid rgba(43,48,64,.5);vertical-align:middle}
 tr:hover td{background:rgba(91,140,255,.06)}
 .kind{display:inline-block;padding:1px 7px;border-radius:10px;background:rgba(91,140,255,.15);
   color:#a8c0ff;font-size:11px;white-space:nowrap}
 .name{max-width:380px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
 .dl{color:var(--ok);font-size:12px;white-space:nowrap}
 .sz{color:var(--dim);font-size:12px;white-space:nowrap}
 .act{white-space:nowrap;text-align:right}
 .act button{padding:4px 9px;font-size:12px}
 .task{background:var(--panel);border:1px solid var(--line);border-radius:8px;padding:10px 12px;margin-bottom:8px}
 .task .row{display:flex;justify-content:space-between;gap:10px;font-size:13px}
 .task .meta{color:var(--dim);font-size:11px;margin-top:3px}
 .err{color:var(--err);font-size:12px;margin-top:3px}
 .empty{color:var(--dim);text-align:center;padding:40px}
 h2{font-size:13px;color:var(--dim);font-weight:600;margin:20px 0 8px;text-transform:uppercase;letter-spacing:.05em}
</style></head><body>
<header>
  <h1>Model Downloads</h1>
  <div class="stat">Disk: <b id="used">–</b> used / <b id="quota">–</b> budget &nbsp;·&nbsp; <b id="free">–</b> free</div>
  <div class="grow"></div>
  <div class="stat" id="count"></div>
  <a class="stat" href="__BASE__/diag" style="color:var(--acc);text-decoration:none;font-weight:500">System diagnostics →</a>
</header>
<div class="wrap">
  <div id="tasks"></div>
  <h2>Catalogue</h2>
  <div class="filters">
    <select id="cat"><option value="">All categories</option></select>
    <select id="kind"><option value="">All types</option></select>
    <input type="search" id="q" placeholder="Search name or path…">
    <button class="ghost" id="refresh">Refresh</button>
    <button id="dlsel" disabled>Download selected</button>
  </div>
  <table>
    <thead><tr>
      <th style="width:26px"><input type="checkbox" id="all"></th>
      <th>Name</th><th>Type</th><th>Size</th><th>Status</th><th></th>
    </tr></thead>
    <tbody id="rows"></tbody>
  </table>
  <div class="empty" id="empty" hidden>Nothing matches.</div>
</div>
<script data-base="__BASE__">
const $=s=>document.querySelector(s), $$=s=>[...document.querySelectorAll(s)];
// BASE is injected server-side: the panel is published under /dl by Caddy, and
// a hardcoded '/api/...' would hit Forge-Neo instead of this app.
const BASE=document.currentScript.dataset.base||'';
let items=[], sel=new Set();
const fmt=b=>{if(!b&&b!==0)return '–';const u=['B','KB','MB','GB','TB'];let i=0,x=b;
  while(x>=1024&&i<u.length-1){x/=1024;i++;}return x.toFixed(i>1?1:0)+' '+u[i];};
async function api(p,o){const r=await fetch(BASE+p,o);return r.json();}
async function loadCats(){
  const d=await api('/api/categories');
  const c=$('#cat');c.innerHTML='<option value="">All categories</option>';
  d.categories.forEach(x=>{const o=document.createElement('option');o.value=x.key;
    o.textContent=`${x.label} (${x.count})`;c.appendChild(o);});
  const k=$('#kind');k.innerHTML='<option value="">All types</option>';
  d.kinds.forEach(x=>{const o=document.createElement('option');o.value=x;o.textContent=x;k.appendChild(o);});
}
async function loadModels(){
  const p=new URLSearchParams();
  if($('#cat').value)p.set('category',$('#cat').value);
  if($('#kind').value)p.set('kind',$('#kind').value);
  if($('#q').value)p.set('q',$('#q').value);
  const d=await api('/api/models?'+p);
  items=d.items; $('#count').textContent=d.count+' items';
  $('#empty').hidden=d.count>0; render();
}
function render(){
  const tb=$('#rows');tb.innerHTML='';
  items.forEach(it=>{
    const tr=document.createElement('tr');
    const cbox=document.createElement('input');
    cbox.type='checkbox';cbox.checked=sel.has(it.id);
    cbox.onchange=()=>{cbox.checked?sel.add(it.id):sel.delete(it.id);updSel();};
    const td0=document.createElement('td');td0.appendChild(cbox);tr.appendChild(td0);
    const td1=document.createElement('td');
    const nm=document.createElement('div');nm.className='name';nm.textContent=it.name;nm.title=it.path;
    td1.appendChild(nm);tr.appendChild(td1);
    const td2=document.createElement('td');
    const k=document.createElement('span');k.className='kind';k.textContent=it.kind;td2.appendChild(k);
    tr.appendChild(td2);
    const td3=document.createElement('td');td3.className='sz';
    td3.textContent=it.size?fmt(it.size):(it.local_size?fmt(it.local_size):'–');tr.appendChild(td3);
    const td4=document.createElement('td');
    if(it.in_progress){const s=document.createElement('span');s.className='sz';s.textContent='downloading…';td4.appendChild(s);}
    else if(it.downloaded){const s=document.createElement('span');s.className='dl';s.textContent='✓ present';td4.appendChild(s);}
    tr.appendChild(td4);
    const td5=document.createElement('td');td5.className='act';
    if(it.downloaded){
      const b=document.createElement('button');b.className='ghost danger';b.textContent='Delete';
      b.onclick=async()=>{await api('/api/delete',{method:'POST',headers:{'Content-Type':'application/json'},
        body:JSON.stringify({ids:[it.id]})});loadModels();};
      td5.appendChild(b);
    } else {
      const b=document.createElement('button');b.textContent='Get';
      b.onclick=()=>{download([it.id]);};td5.appendChild(b);
    }
    tr.appendChild(td5);tb.appendChild(tr);
  });
  updSel();
}
function updSel(){const n=sel.size;$('#dlsel').disabled=n===0;$('#dlsel').textContent=n?`Download selected (${n})`:'Download selected';}
function download(ids){
  api('/api/queue',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({ids})})
    .then(r=>{if(r.rejected&&r.rejected.length)alert('Rejected:\n'+r.rejected.join('\n'));sel.clear();render();});
}
$('#dlsel').onclick=()=>download([...sel]);
$('#all').onchange=e=>{items.forEach(it=>e.target.checked?sel.add(it.id):sel.delete(it.id));render();};
$('#refresh').onclick=loadModels;
$('#cat').onchange=loadModels;$('#kind').onchange=loadModels;
let t;$('#q').oninput=()=>{clearTimeout(t);t=setTimeout(loadModels,250);};
async function poll(){
  const s=await api('/api/state');
  $('#used').textContent=fmt(s.used);$('#quota').textContent=fmt(s.quota);
  $('#free').textContent=fmt(s.free);
  const el=$('#tasks');el.innerHTML='';
  s.tasks.filter(x=>x.status!=='done'||Date.now()/1000-x.elapsed<15).forEach(x=>{
    const d=document.createElement('div');d.className='task';
    const r=document.createElement('div');r.className='row';
    const l=document.createElement('span');l.textContent=x.name;
    const rr=document.createElement('span');
    rr.textContent=`${x.status} ${x.pct}% ${fmt(x.done)} / ${fmt(x.total)}`;
    if(x.status==='done')rr.style.color='var(--ok)';
    if(x.status==='error')rr.style.color='var(--err)';
    r.appendChild(l);r.appendChild(rr);d.appendChild(r);
    const b=document.createElement('div');b.className='bar'+(x.status==='done'?' ok':x.status==='error'?' err':'');
    const i=document.createElement('i');i.style.width=x.pct+'%';b.appendChild(i);d.appendChild(b);
    const m=document.createElement('div');m.className='meta';m.textContent=x.path;d.appendChild(m);
    if(x.error){const e=document.createElement('div');e.className='err';e.textContent=x.error;d.appendChild(e);}
    if(x.status==='running'||x.status==='queued'){
      const c=document.createElement('button');c.className='ghost';c.textContent='Cancel';
      c.onclick=()=>api('/api/cancel',{method:'POST',headers:{'Content-Type':'application/json'},
        body:JSON.stringify({ids:[x.key]})});
      c.style.marginTop='6px';d.appendChild(c);
    }
    el.appendChild(d);
  });
  loadModels();
}
loadCats().then(loadModels);poll();setInterval(poll,2000);
</script></body></html>"""


DIAG_PAGE = r"""<!doctype html>
<html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>System Diagnostics</title>
<style>
 :root{--bg:#12141a;--panel:#1b1e26;--line:#2b3040;--fg:#e6e8ee;--dim:#9aa1b2;
       --acc:#5b8cff;--ok:#3fb950;--err:#f85149;--warn:#d29922}
 *{box-sizing:border-box}
 body{margin:0;font:14px/1.5 system-ui,-apple-system,Segoe UI,sans-serif;background:var(--bg);color:var(--fg)}
 header{padding:14px 20px;border-bottom:1px solid var(--line);display:flex;gap:20px;align-items:center;flex-wrap:wrap;background:var(--panel)}
 h1{font-size:16px;margin:0;font-weight:600}
 .grow{flex:1}
 .wrap{padding:16px 20px;max-width:1600px;margin:0 auto}
 h2{font-size:13px;color:var(--dim);font-weight:600;margin:24px 0 10px;text-transform:uppercase;letter-spacing:.05em}
 .card{background:var(--panel);border:1px solid var(--line);border-radius:8px;padding:14px 16px;margin-bottom:10px}
 .grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(230px,1fr));gap:10px}
 .kv{display:flex;justify-content:space-between;gap:12px;padding:3px 0;font-size:13px}
 .kv span:first-child{color:var(--dim)}
 .kv span:last-child{font-variant-numeric:tabular-nums;text-align:right}
 .bar{height:7px;background:var(--line);border-radius:4px;overflow:hidden;margin:8px 0 4px}
 .bar>i{display:block;height:100%;background:var(--acc)}
 .bar.warn>i{background:var(--warn)} .bar.err>i{background:var(--err)}
 .ok{color:var(--ok)} .err{color:var(--err)} .warn{color:var(--warn)} .dim{color:var(--dim)}
 pre{margin:0;padding:12px 14px;background:#0d0f14;border:1px solid var(--line);border-radius:6px;
     font:12px/1.45 ui-monospace,SFMono-Regular,Menlo,monospace;overflow:auto;max-height:440px;white-space:pre-wrap;word-break:break-word}
 details{margin-bottom:10px}
 summary{cursor:pointer;padding:9px 12px;background:var(--panel);border:1px solid var(--line);border-radius:6px;
     font-size:13px;display:flex;justify-content:space-between;gap:12px}
 summary::-webkit-details-marker{display:none}
 details[open] summary{border-radius:6px 6px 0 0}
 details[open] pre{border-radius:0 0 6px 6px;border-top:0}
 table{width:100%;border-collapse:collapse;font-size:12.5px}
 th{text-align:left;color:var(--dim);font-weight:500;padding:6px 8px;border-bottom:1px solid var(--line);font-size:11.5px;white-space:nowrap}
 td{padding:5px 8px;border-bottom:1px solid rgba(43,48,64,.5)}
 button{background:var(--acc);border:0;color:#fff;padding:7px 13px;border-radius:6px;cursor:pointer;font:inherit;font-weight:500}
 .mono{font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:12px}
</style></head><body>
<header>
  <h1>System Diagnostics</h1>
  <div class="dim" id="ts" style="font-size:12px"></div>
  <div class="grow"></div>
  <button id="refresh">Refresh</button>
  <a class="dim" href="__BASE__/" style="text-decoration:none;font-size:12.5px">← Downloads</a>
</header>
<div class="wrap" id="root"><div class="dim">Loading…</div></div>

<script>
const B='__BASE__';
const gb=v=>v==null?'–':(v/1e9).toFixed(2)+' GB';
const el=(t,c,txt)=>{const e=document.createElement(t);if(c)e.className=c;if(txt!=null)e.textContent=txt;return e;}
const kv=(k,v,cls)=>{const d=el('div','kv');d.append(el('span',null,k));d.append(el('span',cls,v));return d;}
const fmtAge=s=>s<60?s+'s ago':s<3600?Math.round(s/60)+'m ago':Math.round(s/3600)+'h ago';

function diskCard(d){
  const c=el('div','card');
  c.append(el('div','mono',d.path));
  const pct=d.percent_used||0;
  const b=el('div','bar'+(pct>92?' err':pct>80?' warn':''));
  const i=el('i');i.style.width=Math.min(100,pct)+'%';b.append(i);c.append(b);
  c.append(kv('used',`${d.used_gb} / ${d.total_gb} GB`,pct>92?'err':pct>80?'warn':'ok'));
  c.append(kv('free',d.free_gb+' GB',d.free_gb<3?'err':null));
  return c;
}

function gpuCard(g){
  const c=el('div','card');
  if(!g.available){
    c.append(el('div','err','GPU not available via torch'));
    if(g.error)c.append(el('div','dim',g.error));
    if(g.torch_version)c.append(kv('torch',g.torch_version));
    if(g.torch_cuda_build)c.append(kv('cuda build',g.torch_cuda_build));
    return c;
  }
  (g.devices||[]).forEach(d=>{
    c.append(el('div','mono',d.name));
    c.append(kv('VRAM total',d.total_vram_gb+' GB'));
    c.append(kv('VRAM free',d.free_vram_gb+' GB',d.free_vram_gb<1?'warn':null));
    c.append(kv('compute',d.compute_capability));
    c.append(kv('SMs',d.multi_processor_count));
  });
  c.append(kv('torch',g.torch_version||'–'));
  c.append(kv('cuda build',g.torch_cuda_build||'–'));
  return c;
}

async function load(){
  const r=await fetch(B+'/api/diag');
  const d=await r.json();
  const root=document.getElementById('root');root.innerHTML='';
  document.getElementById('ts').textContent=new Date(d.timestamp*1000).toLocaleTimeString();

  // GPU + disks up top: these are the two that actually break a deployment.
  root.append(el('h2',null,'GPU'));
  root.append(gpuCard(d.gpu));

  root.append(el('h2',null,'Storage'));
  const g=el('div','grid');
  (d.system.disks||[]).forEach(x=>g.append(diskCard(x)));
  root.append(g);

  root.append(el('h2',null,'Memory & Load'));
  const mc=el('div','card');
  if(d.system.memory_gb){
    const m=d.system.memory_gb;
    mc.append(kv('RAM total',m.total+' GB'));
    mc.append(kv('RAM available',m.available+' GB',m.available<1?'warn':null));
  } else mc.append(el('div','dim','unavailable'));
  if(d.system.loadavg)mc.append(kv('load avg',d.system.loadavg.map(x=>x.toFixed(2)).join(' / ')));
  if(d.system.uptime_seconds!=null){
    const s=d.system.uptime_seconds;
    mc.append(kv('uptime',s<3600?Math.round(s/60)+'m':Math.round(s/3600)+'h '+Math.round(s%3600/60)+'m'));
  }
  root.append(mc);

  root.append(el('h2',null,'Host'));
  const hc=el('div','card');
  Object.entries(d.system.host||{}).forEach(([k,v])=>hc.append(kv(k,v)));
  root.append(hc);

  root.append(el('h2',null,'Processes (by RSS)'));
  const t=el('table');
  const th=el('tr');['PID','name','RSS','CPU s'].forEach(x=>th.append(el('th',null,x)));
  const thead=el('thead');thead.append(th);t.append(thead);
  const tbody=el('tbody');
  (d.processes||[]).forEach(p=>{
    const tr=el('tr');
    tr.append(el('td','mono',p.pid));
    tr.append(el('td',null,p.name));
    tr.append(el('td','mono',p.rss_mb+' MB'));
    tr.append(el('td','mono',p.cpu_seconds));
    tbody.append(tr);
  });
  t.append(tbody);
  const tw=el('div','card');tw.append(t);root.append(tw);

  root.append(el('h2',null,'Logs'));
  const names=Object.keys(d.logs||{});
  if(!names.length)root.append(el('div','card dim','no logs found'));
  names.forEach(n=>{
    const L=d.logs[n];
    const det=el('details');
    const sm=el('summary');
    sm.append(el('span','mono',n));
    sm.append(el('span','dim',`${(L.size/1024).toFixed(0)} KB · ${fmtAge(L.age_seconds)}`));
    det.append(sm);
    const pre=el('pre',null,L.lines.length?L.lines.join('\\n'):'(empty)');
    det.append(pre);
    root.append(det);
  });
}

document.getElementById('refresh').onclick=load;
load();setInterval(load,5000);
</script></body></html>"""


@app.get("/diag", response_class=HTMLResponse)
def diag_page(request: Request) -> HTMLResponse:
    """The browser view over /api/diag.

    Deliberately dumb: fetch JSON, render it. All the collection logic lives
    in diag.py so it can be tested without FastAPI.
    """
    base = request.headers.get("x-forwarded-prefix", "").rstrip("/")
    return HTMLResponse(DIAG_PAGE.replace("__BASE__", base))



@app.get("/", response_class=HTMLResponse)
def index(request: Request) -> HTMLResponse:
    # The panel is published under /dl by Caddy, which strips the prefix before
    # proxying. The browser still sees /dl, so the page's API calls must be
    # prefixed with /dl or they land on Forge-Neo instead of this app.
    #
    # Caddy tells us the prefix with X-Forwarded-Prefix (set via header_up).
    # Standalone -- no proxy -- the header is absent and BASE is empty, which
    # is correct for http://127.0.0.1:7861/.
    base = request.headers.get("x-forwarded-prefix", "").rstrip("/")
    return HTMLResponse(PAGE.replace("__BASE__", base))


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

store: Store  # set in main()


def main() -> None:
    global store
    ap = argparse.ArgumentParser(description="Forge-Neo model download panel")
    ap.add_argument("--models", default="models.json")
    ap.add_argument("--dest", default=os.path.expanduser("~/forge-neo/models"))
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=7861)
    ap.add_argument("--quota-gb", type=float, default=30.0,
                    help="Max bytes the models dir may occupy (0 = unlimited)")
    ap.add_argument("--log-dir", default=os.path.expanduser("~/forge-neo/logs"),
                    help="Directory the entrypoint writes service logs to")
    args = ap.parse_args()

    dest = Path(args.dest).expanduser()
    dest.mkdir(parents=True, exist_ok=True)
    store = Store(Path(args.models).expanduser(), dest, args.quota_gb,
                  Path(args.log_dir).expanduser())

    import uvicorn
    uvicorn.run(app, host=args.host, port=args.port, log_level="warning")


if __name__ == "__main__":
    main()
