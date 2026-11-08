#!/usr/bin/env python3
"""
monitor_build.py -- watch the GitHub Actions image build from a second pane.

Usage:
    python3 monitor_build.py            follow the newest run until it finishes
    python3 monitor_build.py --once     one snapshot and exit
    python3 monitor_build.py --logs     also tail the running step's log

No dependencies (stdlib only). The run/job/step state needs no API token --
the repo is public, so anonymous read access covers it.

GitHub gates the log endpoints behind authentication even for public repos
(403 without a token), so `--logs` needs a token:

    export GITHUB_TOKEN=ghp_xxx      # or GH_TOKEN

A `gh.env` file containing `GITHUB_TOKEN=ghp_xxx` is picked up automatically
(looked up next to this script, in the cwd, and in ~/tmp). The value is read
from disk and never printed.

Nothing is written to disk. This only reads the GitHub API.
"""

from __future__ import annotations

import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

REPO = os.environ.get("REPO", "ReimusArmpit/akash-imagegen")
API = "https://api.github.com"
POLL = 10

C = {
    "reset": "\033[0m", "dim": "\033[2m", "bold": "\033[1m",
    "green": "\033[32m", "yellow": "\033[33m", "red": "\033[31m",
    "cyan": "\033[36m", "grey": "\033[90m",
}
if not sys.stdout.isatty() or os.environ.get("NO_COLOR"):
    C = {k: "" for k in C}


def _load_token_file() -> str | None:
    """Read a token from a gh.env-style file without echoing it.

    Accepts either form:
        GITHUB_TOKEN=ghp_xxx     (KEY=VALUE)
        ghp_xxx                   (bare token on its own line)

    Looked up next to the script, in the cwd, and in ~/tmp.
    The value is read from disk and never printed.
    """
    prefixes = ("ghp_", "gho_", "ghu_", "ghs_", "ghr_", "github_pat_")
    candidates = [
        os.path.join(os.path.dirname(os.path.abspath(__file__)), "gh.env"),
        os.path.join(os.getcwd(), "gh.env"),
        os.path.join(os.path.expanduser("~"), "tmp", "gh.env"),
    ]
    for path in candidates:
        try:
            with open(path) as fh:
                for line in fh:
                    line = line.strip()
                    if not line or line.startswith("#"):
                        continue
                    if "=" in line:
                        key, _, val = line.partition("=")
                        if key.strip().upper() in ("GITHUB_TOKEN", "GH_TOKEN"):
                            val = val.strip().strip("'\"")
                            if val:
                                return val
                        continue
                    # bare token form
                    if line.startswith(prefixes):
                        return line
        except OSError:
            continue
    return None


def _headers() -> dict:
    h = {"Accept": "application/vnd.github+json", "User-Agent": "akash-build-monitor"}
    tok = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN") or _load_token_file()
    if tok:
        h["Authorization"] = "Bearer " + tok
    return h


def _opener():
    """Opener that drops Authorization when a redirect changes host.

    GitHub's log endpoints answer 302 to a signed blob URL on a different
    host. urllib copies the Authorization header onto that new request and
    the blob store rejects it with 401. curl drops the header when the host
    changes; we do the same, which is why curl succeeds and urllib didn't.
    """
    class _StripAuthOnRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, req, fp, code, msg, headers, newurl):
            new = super().redirect_request(req, fp, code, msg, headers, newurl)
            if new is not None:
                old_host = urllib.parse.urlparse(req.full_url).netloc
                new_host = urllib.parse.urlparse(newurl).netloc
                if old_host != new_host:
                    new.remove_header("Authorization")
            return new

    return urllib.request.build_opener(_StripAuthOnRedirect())


def get(path: str, raw: bool = False):
    req = urllib.request.Request(API + path, headers=_headers())
    with _opener().open(req, timeout=30) as r:
        return r.read().decode("utf-8", "replace") if raw else json.load(r)


def glyph(status: str, conclusion: str | None) -> str:
    if status == "completed":
        if conclusion == "success":
            return C["green"] + "OK  " + C["reset"]
        if conclusion in ("cancelled", "skipped"):
            return C["grey"] + "--  " + C["reset"]
        return C["red"] + "FAIL" + C["reset"]
    if status == "in_progress":
        return C["yellow"] + "RUN " + C["reset"]
    return C["dim"] + "WAIT" + C["reset"]


def latest_run() -> dict | None:
    d = get(f"/repos/{REPO}/actions/runs")
    runs = d.get("workflow_runs") or []
    return runs[0] if runs else None


def jobs_of(run_id: int) -> list:
    d = get(f"/repos/{REPO}/actions/runs/{run_id}/jobs")
    return d.get("jobs") or []


def tail_job_log(job_id: int, n: int = 18) -> tuple[list[str], str | None]:
    """Return the last n non-empty lines of a job log, or an error string."""
    try:
        text = get(f"/repos/{REPO}/actions/jobs/{job_id}/logs", raw=True)
    except urllib.error.HTTPError as e:
        return [], f"HTTP {e.code}"
    except Exception as e:  # noqa: BLE001
        return [], str(e)
    lines = [ln for ln in text.splitlines() if ln.strip()]
    return lines[-n:], None


def package_tags() -> list[str]:
    """Tags published to GHCR for this repo, newest first."""
    owner, name = REPO.split("/", 1)
    try:
        d = get(f"/users/{owner}/packages/container/{name}/versions")
    except Exception:  # noqa: BLE001
        return []
    out = []
    for v in d:
        meta = (v.get("metadata") or {}).get("container") or {}
        tags = meta.get("tags") or []
        out.append(tags[0] if tags else v.get("name", "?"))
    return out


def render(run: dict, show_logs: bool, log_cache: dict) -> None:
    print(f"\033[H\033[2J", end="")  # home + clear
    title = run.get("name", "?")
    print(f"{C['bold']}{REPO}{C['reset']}  {title}")
    print(f"  status    {run.get('status')}  {C['dim']}{run.get('conclusion') or '-'}{C['reset']}")
    print(f"  branch    {run.get('head_branch')}  {C['dim']}@{run.get('head_sha','')[:8]}{C['reset']}")
    print(f"  url       {run.get('html_url')}")
    print(f"  started   {run.get('created_at')}")

    jobs = jobs_of(run["id"])
    for j in jobs:
        print()
        print(f"  {C['bold']}job {j['name']}{C['reset']}  {glyph(j['status'], j.get('conclusion'))}")
        for s in j.get("steps") or []:
            g = glyph(s.get("status", ""), s.get("conclusion"))
            started = s.get("started_at")
            took = ""
            if started and s.get("completed_at"):
                try:
                    a = time.mktime(time.strptime(started, "%Y-%m-%dT%H:%M:%SZ"))
                    b = time.mktime(time.strptime(s["completed_at"], "%Y-%m-%dT%H:%M:%SZ"))
                    took = f" {C['dim']}{int(b - a)}s{C['reset']}"
                except Exception:  # noqa: BLE001
                    pass
            print(f"    {g} {s['name']}{took}")

        if show_logs:
            if not _headers().get("Authorization"):
                print(f"    {C['dim']}log tail needs a token (set GITHUB_TOKEN) -- "
                      f"step status is still shown above{C['reset']}")
            else:
                running = [s for s in (j.get("steps") or [])
                           if s.get("status") == "in_progress"]
                key = (j["id"], running[0]["name"] if running else None)
                if key not in log_cache:
                    lines, err = tail_job_log(j["id"])
                    log_cache[key] = (lines, err)
                lines, err = log_cache[key]
                if err:
                    print(f"    {C['dim']}log unavailable ({err}){C['reset']}")
                elif lines:
                    print(f"    {C['grey']}{'─' * 60}{C['reset']}")
                    for ln in lines:
                        print(f"    {C['grey']}{ln[:160]}{C['reset']}")

    tags = package_tags()
    if tags:
        print()
        print(f"  {C['cyan']}GHCR{C['reset']} {C['dim']}ghcr.io/{REPO}{C['reset']}")
        for t in tags[:6]:
            print(f"    - {t}")
    print()


def main() -> int:
    args = sys.argv[1:]
    once = "--once" in args
    show_logs = "--logs" in args

    log_cache: dict = {}
    last_sig = None
    while True:
        try:
            run = latest_run()
            if run is None:
                print(f"{C['dim']}no runs yet for {REPO}{C['reset']}")
            else:
                sig = (run["id"], run.get("status"), run.get("conclusion"))
                if sig != last_sig or once:
                    render(run, show_logs, log_cache)
                    last_sig = sig
                else:
                    # refresh just the log tail while a step is in flight
                    if show_logs:
                        render(run, show_logs, log_cache)
                if run.get("status") == "completed":
                    ok = run.get("conclusion") == "success"
                    print(f"{C['bold']}{'BUILD SUCCEEDED' if ok else 'BUILD FAILED'}{C['reset']}")
                    print(f"  {run.get('html_url')}")
                    tags = package_tags()
                    if tags:
                        print(f"  pull: {C['cyan']}ghcr.io/{REPO}:{tags[0]}{C['reset']}")
                    return 0 if ok else 1
        except urllib.error.HTTPError as e:
            print(f"{C['red']}HTTP {e.code}{C['reset']} from GitHub API")
        except Exception as e:  # noqa: BLE001
            print(f"{C['red']}error:{C['reset']} {e}")

        if once:
            return 0
        time.sleep(POLL)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print()
        sys.exit(130)
