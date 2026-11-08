#!/usr/bin/env python3
"""System diagnostics for the akash-imagegen container.

WHY
---
Forge-Neo shows its own Gradio errors, and the download panel shows its own
download state. But when something goes wrong at the *system* level -- the
container OOMs, the root filesystem fills, Neo gets a GPU with less VRAM than
advertised, a tunnel dies -- there is nowhere in the browser to see it.

This module collects that state and the tail of each service log so the
panel can serve it as one page.

GPU
---
The image is nvidia/cuda:12.8.1-runtime, which ships the CUDA runtime
libraries but NOT nvidia-utils, so there is no `nvidia-smi` binary. The
nvidia driver is host-side anyway; the container only gets the device node
and the userspace libraries. So GPU facts come from torch, which talks to
the driver directly:

    torch.cuda.get_device_properties(0)
        .name        -> "NVIDIA GeForce RTX 3060"
        .total_memory-> bytes of VRAM
        .major/.minor-> compute capability

That is exactly the information needed to catch the nasty failure: a
provider advertising a 12 GB 3060 that actually hands you a 6 GB one, so
every generation dies with a CUDA OOM that looks like a bug in your prompt.
"""

from __future__ import annotations

import os
import platform
import shutil
import subprocess
import time
from pathlib import Path
from typing import Any

# How many bytes of each log to return. 64 KB is enough to see a traceback
# and small enough to keep the response snappy.
LOG_TAIL_BYTES = 64 * 1024


def _read_tail(path: Path, limit: int = LOG_TAIL_BYTES) -> str:
    """Return the last `limit` bytes of a file, as text.

    Seeks to the end rather than reading the whole file: logs can be large
    and this is called on every poll.
    """
    try:
        size = path.stat().st_size
        with path.open("rb") as fh:
            if size > limit:
                fh.seek(size - limit)
            data = fh.read()
    except OSError as exc:
        return f"<unreadable: {exc}>"
    return data.decode("utf-8", errors="replace")


def _tail_lines(path: Path, lines: int = 200) -> list[str]:
    """Return the last N lines of a file."""
    try:
        with path.open("rb") as fh:
            fh.seek(0, os.SEEK_END)
            size = fh.tell()
            # Read backwards in chunks until we have enough newlines.
            block = 8192
            data = b""
            while size > 0 and data.count(b"\n") <= lines:
                read_size = min(block, size)
                size -= read_size
                fh.seek(size)
                data = fh.read(read_size) + data
                if size == 0:
                    break
        return data.decode("utf-8", errors="replace").splitlines()[-lines:]
    except OSError:
        return []


def gpu_info() -> dict[str, Any]:
    """GPU facts from torch. Never raises -- torch may be missing or broken."""
    info: dict[str, Any] = {"available": False, "error": None}
    try:
        import torch  # noqa: PLC0415 - optional, and slow to import
    except Exception as exc:  # noqa: BLE001
        info["error"] = f"torch not importable: {exc}"
        return info

    try:
        info["torch_version"] = torch.__version__
        info["torch_cuda_build"] = torch.version.cuda
    except Exception:  # noqa: BLE001
        pass

    try:
        if not torch.cuda.is_available():
            info["error"] = "torch.cuda.is_available() is False"
            return info
        count = torch.cuda.device_count()
        info["available"] = True
        info["device_count"] = count
        devices = []
        for i in range(count):
            p = torch.cuda.get_device_properties(i)
            free, total = torch.cuda.mem_get_info(i)
            devices.append({
                "index": i,
                "name": p.name,
                "total_vram": p.total_memory,
                "total_vram_gb": round(p.total_memory / 1024**3, 2),
                "free_vram": free,
                "free_vram_gb": round(free / 1024**3, 2),
                "compute_capability": f"{p.major}.{p.minor}",
                "multi_processor_count": p.multi_processor_count,
            })
        info["devices"] = devices
    except Exception as exc:  # noqa: BLE001
        info["error"] = f"cuda query failed: {exc}"
    return info


def _run(cmd: list[str], timeout: float = 5.0) -> str | None:
    """Run a command and return stdout, or None if it failed."""
    try:
        proc = subprocess.run(
            cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            text=True, timeout=timeout,
        )
        out = (proc.stdout or "").strip()
        return out or None
    except (OSError, subprocess.SubprocessError):
        return None


def system_info(paths: dict[str, Path] | None = None) -> dict[str, Any]:
    """Filesystem, memory and load information."""
    info: dict[str, Any] = {}

    # Filesystem usage for the paths that matter. The root fs is what the
    # image and the models live on; a full root fs is the classic silent
    # killer in this setup. A path that does not exist is skipped rather than
    # reported as an error: /work only exists once the entrypoint has created
    # it, and an error entry there is just noise.
    disks = []
    seen = set()
    for path in (paths or {"root": Path("/")}).values():
        try:
            resolved = str(path.resolve())
        except OSError:
            continue
        if resolved in seen:
            continue
        seen.add(resolved)
        if not Path(resolved).exists():
            continue
        try:
            usage = shutil.disk_usage(resolved)
            disks.append({
                "path": resolved,
                "total": usage.total,
                "used": usage.used,
                "free": usage.free,
                "total_gb": round(usage.total / 1024**3, 2),
                "used_gb": round(usage.used / 1024**3, 2),
                "free_gb": round(usage.free / 1024**3, 2),
                "percent_used": round(100 * usage.used / usage.total, 1)
                if usage.total else None,
            })
        except OSError:
            continue
    info["disks"] = disks

    # Memory. /proc/meminfo is the portable-enough source inside a container;
    # `free` is not always installed.
    mem = {}
    try:
        with open("/proc/meminfo") as fh:
            for line in fh:
                key, _, rest = line.partition(":")
                val = rest.strip().split(" ")[0]
                if key in ("MemTotal", "MemAvailable", "MemFree", "SwapTotal", "SwapFree"):
                    mem[key] = int(val) * 1024
    except (OSError, ValueError):
        pass
    if mem:
        info["memory"] = mem
        info["memory_gb"] = {
            "total": round(mem.get("MemTotal", 0) / 1024**3, 2),
            "available": round(mem.get("MemAvailable", 0) / 1024**3, 2),
        }

    # Load average and uptime.
    try:
        info["loadavg"] = list(os.getloadavg())
    except OSError:
        pass
    uptime = _run(["cat", "/proc/uptime"])
    if uptime:
        try:
            info["uptime_seconds"] = round(float(uptime.split()[0]))
        except (ValueError, IndexError):
            pass

    info["host"] = {
        "platform": platform.platform(),
        "python": platform.python_version(),
        "pid1": _run(["cat", "/proc/1/comm"]) or "unknown",
    }
    return info


def processes() -> list[dict[str, Any]]:
    """A process listing with RSS, so an OOM can be traced to a culprit."""
    out = []
    try:
        for pid in sorted(os.listdir("/proc")):
            if not pid.isdigit():
                continue
            try:
                with open(f"/proc/{pid}/stat") as fh:
                    stat = fh.read()
                # comm can contain spaces and parentheses; split around them.
                rparen = stat.rfind(")")
                name = stat[stat.find("(") + 1:rparen]
                fields = stat[rparen + 2:].split()
                # field 22 (1-indexed in proc(5)) is RSS in pages
                rss_pages = int(fields[21])
                utime = int(fields[11])
                stime = int(fields[12])
                out.append({
                    "pid": int(pid),
                    "name": name,
                    "rss": rss_pages * os.sysconf("SC_PAGE_SIZE"),
                    "rss_mb": round(rss_pages * os.sysconf("SC_PAGE_SIZE") / 1024**2, 1),
                    "cpu_seconds": round((utime + stime) / os.sysconf("SC_CLK_TCK"), 1),
                })
            except (OSError, ValueError, IndexError):
                continue
    except OSError:
        pass
    out.sort(key=lambda p: -p["rss"])
    return out[:25]


def collect(log_dir: Path, models_dir: Path | None = None,
            extra_paths: dict[str, Path] | None = None) -> dict[str, Any]:
    """Full diagnostic snapshot."""
    paths: dict[str, Path] = {"root": Path("/")}
    if extra_paths:
        paths.update(extra_paths)
    work = Path(os.environ.get("WORK", "/work"))
    if work.exists():
        paths["work"] = work

    data: dict[str, Any] = {
        "timestamp": time.time(),
        "gpu": gpu_info(),
        "system": system_info(paths),
        "processes": processes(),
        "logs": {},
    }

    # Tail each log file the entrypoint writes.
    try:
        log_files = sorted(p for p in log_dir.glob("*.log") if p.is_file())
    except OSError:
        log_files = []
    for path in log_files:
        try:
            size = path.stat().st_size
            mtime = path.stat().st_mtime
        except OSError:
            continue
        data["logs"][path.name] = {
            "size": size,
            "modified": mtime,
            "age_seconds": round(time.time() - mtime),
            "lines": _tail_lines(path, 200),
        }

    if models_dir is not None:
        data["models_dir"] = str(models_dir)
        try:
            usage = shutil.disk_usage(models_dir if models_dir.exists() else Path("/"))
            data["models_disk"] = {
                "total_gb": round(usage.total / 1024**3, 2),
                "used_gb": round(usage.used / 1024**3, 2),
                "free_gb": round(usage.free / 1024**3, 2),
            }
        except OSError:
            pass

    return data


if __name__ == "__main__":
    import json
    import sys

    log_dir = Path(sys.argv[1] if len(sys.argv) > 1 else "/work/logs")
    print(json.dumps(collect(log_dir), indent=2))
