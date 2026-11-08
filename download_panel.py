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

    def __init__(self, models_path: Path, dest: Path, quota_gb: float) -> None:
        self.models_path = models_path
        self.dest = dest
        self.quota_bytes = int(quota_gb * 1024**3)
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
    args = ap.parse_args()

    dest = Path(args.dest).expanduser()
    dest.mkdir(parents=True, exist_ok=True)
    store = Store(Path(args.models).expanduser(), dest, args.quota_gb)

    import uvicorn
    uvicorn.run(app, host=args.host, port=args.port, log_level="warning")


if __name__ == "__main__":
    main()
