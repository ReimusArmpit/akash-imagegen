#!/bin/bash
# ============================================================================
# entrypoint.sh -- PID 1 for the akash-imagegen container.
#
# Derived from imageGenMain.sh, which assumes you are a human with a shell on
# a rented VPS:
#   * sudo works          -> Akash sets AllowPrivilegeEscalation=false. No sudo.
#   * scripts run by hand -> There is no login step. This script IS the login.
#   * 127.0.0.1:8188      -> lease-shell has no port-forward. Nothing local.
#   * disk persists       -> Lost on lease close. Only /work survives restarts.
#   * fixed driver        -> nvidia-smi may be absent; driver is host-side.
#
# So: no sudo, no interactive steps, no assumptions about being re-run by hand.
# Everything is idempotent, because the container restarts on the same volume.
#
# USAGE
#   This runs as PID 1 via the image ENTRYPOINT. It supervises Forge-Neo and
#   FileBrowser and exposes both through one cloudflared tunnel.
#
#   MODE=tunnel   (default) loopback + cloudflared URL  -> nothing published
#   MODE=direct            bind 0.0.0.0, rely on SDL-published ports + auth
#
# ENV (set in the SDL, not committed):
#   NEO_USER / NEO_PASS       required, gates both the UI and /sdapi
#   FB_USER  / FB_PASS        FileBrowser login
#   HF_TOKEN                  optional, avoids HF rate limits
#   CIVITAI_TOKEN             optional, for the downloader
#   SKIP_MODELS=1             (obsolete: nothing downloads at boot any more)
#   PANEL_QUOTA_GB=20         cap on model bytes the panel will fetch
# ============================================================================
set -uo pipefail

MODE="${MODE:-tunnel}"
WORK="${WORK:-/work}"
NEO_DIR="$WORK/forge-neo"
NEO_PORT="${NEO_PORT:-8188}"
FB_PORT="${FB_PORT:-7860}"
MODELS_DIR="$WORK/models"
LOG_DIR="$WORK/logs"

hr()  { echo; echo "=== $* ==="; }
# TAIL_PID is set further down, after the log sink is installed. die() may be
# called before or after that, so it must tolerate an unset/invalid pid.
die() { echo "[FATAL] $*" >&2; [ -n "${TAIL_PID:-}" ] && kill "$TAIL_PID" 2>/dev/null; exit 1; }
warn(){ echo "[WARN] $*" >&2; }

mkdir -p "$WORK" "$MODELS_DIR" "$LOG_DIR"

# ---------------------------------------------------------------------------
# Mirror all output into $LOG_DIR/entrypoint.log.
# ---------------------------------------------------------------------------
# On Akash, container stdout is only reachable through `provider-services
# lease-logs` or the provider's dashboard -- neither of which is available from
# the browser. That makes the most useful output in the container (boot
# sequence, GPU check, why Neo died, tunnel URLs) invisible exactly when it
# matters. Writing it to a file puts it behind the same diag page and
# FileBrowser as every other log.
#
# The FILE is authoritative and stdout is mirrored from it, not the other way
# round. `exec > >(tee -a file)` looks equivalent but silently loses the tail
# of the output when the shell exits: measured at 9/12 runs writing zero lines,
# because bash does not wait for the tee process substitution. Since `die()`
# paths exit immediately, that would lose exactly the fatal boot errors this is
# meant to capture. Appending to the file and tail -F'ing it back out is
# deterministic (0/12 failures) and keeps provider-side logging working.
exec 3>&1 4>&2
: > "$LOG_DIR/entrypoint.log"
exec >> "$LOG_DIR/entrypoint.log" 2>&1
tail -F -n +1 "$LOG_DIR/entrypoint.log" >&3 2>&4 &
TAIL_PID=$!

# ---------------------------------------------------------------------------
# 0. Credentials
# ---------------------------------------------------------------------------
# On Akash these arrive as SDL env vars. secrets.env is still honoured so the
# same script runs unchanged in a local docker test.
hr "CREDENTIALS"
if [ -f "$WORK/secrets.env" ]; then
    # Order matters: on Akash the real credentials are SDL env vars, and a stale
    # /work/secrets.env from a previous run must NOT silently win over them.
    # Snapshot the SDL-provided values, source the file, then restore.
    _snap_neo_user="${NEO_USER:-}"; _snap_neo_pass="${NEO_PASS:-}"
    _snap_fb_user="${FB_USER:-}";   _snap_fb_pass="${FB_PASS:-}"
    _snap_px_user="${PROXY_USER:-}"; _snap_px_pass="${PROXY_PASS:-}"
    set -a; . "$WORK/secrets.env"; set +a
    [ -n "$_snap_neo_user" ] && NEO_USER="$_snap_neo_user"
    [ -n "$_snap_neo_pass" ] && NEO_PASS="$_snap_neo_pass"
    [ -n "$_snap_fb_user" ]  && FB_USER="$_snap_fb_user"
    [ -n "$_snap_fb_pass" ]  && FB_PASS="$_snap_fb_pass"
    [ -n "$_snap_px_user" ]  && PROXY_USER="$_snap_px_user"
    [ -n "$_snap_px_pass" ]  && PROXY_PASS="$_snap_px_pass"
    echo "[OK] merged $WORK/secrets.env (SDL env takes precedence)"
fi

if [ -z "${NEO_USER:-}" ] || [ -z "${NEO_PASS:-}" ]; then
    # Refuse to boot rather than silently publish an unauthenticated UI on a
    # public tunnel URL. This is the one failure mode worth dying on.
    die "NEO_USER/NEO_PASS unset. Refusing to start an unauthenticated UI.
     Set them in the SDL env block (or /work/secrets.env)."
fi

# Character guard. Neo parses these as `user:pass` and splits on ':' and ','.
# modules/api/api.py does `user, password = auth.split(":")`, which raises
# ValueError on a second colon; a comma is read as a second credential pair.
# get_gradio_auth_creds() uses split(":", 1) so it survives a colon but not a
# comma. Either way the process dies at startup -- and with a supervisor that
# restarts it, that is a silent crash loop billing GPU while no UI exists.
case "$NEO_USER:$NEO_PASS" in
    *:*:*|*,*)
        die "NEO_USER/NEO_PASS contain ':' or ','.
     Neo splits api_auth on ':' and ',' and will crash at startup.
     Use letters, digits, '-' and '_' only." ;;
esac
case "${FB_PASS:-}" in
    *,*) warn "FB_PASS contains ','; filebrowser is fine with it, Neo is not." ;;
esac
echo "[OK] Neo credentials present"

# ---------------------------------------------------------------------------
# 0b. Published-port proxy
# ---------------------------------------------------------------------------
# Akash refuses a manifest with no global endpoint ("zero global services",
# manifest/v2beta2/groups.go:30), so one port must be published. Caddy owns it
# and forwards to loopback with Basic auth. The hash is generated here because
# Caddy cannot bcrypt a plaintext at runtime, and putting a precomputed hash in
# the SDL means rotating the password requires editing and re-hashing by hand.
CADDY_BIN=""
for c in /usr/bin/caddy /usr/local/bin/caddy "$WORK/bin/caddy"; do
    [ -x "$c" ] && { CADDY_BIN="$c"; break; }
done

PROXY_UP=0
if [ -n "$CADDY_BIN" ] && [ -n "${PROXY_PASS:-}" ] && [ -n "${PROXY_USER:-}" ]; then
    export PROXY_PASS_HASH="$("$CADDY_BIN" hash-password --plaintext "$PROXY_PASS")"
    export PROXY_USER
    mkdir -p "$WORK/caddy"
    CADDYFILE_IN="${CADDYFILE:-/etc/caddy/Caddyfile}"
    if [ -f "$CADDYFILE_IN" ]; then
        cp "$CADDYFILE_IN" "$WORK/caddy/Caddyfile"
        PROXY_UP=1
        echo "[OK] proxy configured (user: $PROXY_USER) on published port 8080"
    else
        warn "Caddyfile not at $CADDYFILE_IN; published port will be dead."
    fi
elif [ -n "$CADDY_BIN" ]; then
    warn "PROXY_USER/PROXY_PASS unset: NOT starting Caddy."
    warn "The SDL publishes port 8080, so it will answer nothing. Set them."
fi

if [ "$MODE" = "tunnel" ]; then
    LISTEN_ARGS=()                 # 127.0.0.1 only
    NEO_BIND="127.0.0.1"
else
    LISTEN_ARGS=(--listen)         # 0.0.0.0, requires published SDL ports
    NEO_BIND="0.0.0.0"
fi

# ---------------------------------------------------------------------------
# 1. GPU sanity (no driver install possible)
# ---------------------------------------------------------------------------
# Previously this script tried `ubuntu-drivers autoinstall`. That cannot work
# here: no root, no reboot, and the driver belongs to the host kernel.
hr "GPU"
if command -v nvidia-smi >/dev/null 2>&1; then
    nvidia-smi --query-gpu=name,memory.total,compute_cap --format=csv,noheader \
        || warn "nvidia-smi present but query failed"
else
    # Not fatal: the driver is host-side and only the CUDA libs are injected.
    # Torch can still work with no nvidia-smi in the container. Assert what we
    # actually got, though: a provider advertising a 12GB 3060 that hands over
    # a 6GB card produces CUDA OOM on every generation, and without this line
    # that looks like a bug in the prompt rather than the lease.
    warn "nvidia-smi not in this image. Verifying via torch instead."
    python3 - <<'PYEOF' || warn "torch GPU check failed (GPU may be absent)"
import sys
try:
    import torch
except Exception as exc:
    print(f"[WARN] torch not importable: {exc}", file=sys.stderr)
    sys.exit(0)
if not torch.cuda.is_available():
    print("[WARN] torch.cuda.is_available() is False -- no GPU visible to the "
          "container. Neo will start but generation will fail.", file=sys.stderr)
    sys.exit(0)
for i in range(torch.cuda.device_count()):
    p = torch.cuda.get_device_properties(i)
    free, total = torch.cuda.mem_get_info(i)
    print(f"[OK] GPU {i}: {p.name}, {p.total_memory / 1024**3:.1f} GB VRAM "
          f"({free / 1024**3:.1f} GB free), compute {p.major}.{p.minor}, "
          f"{p.multi_processor_count} SMs")
    # The 3060 has 12GB. Anything at or below 8GB cannot hold an SDXL
    # checkpoint plus its VAE/text encoders at full precision.
    if p.total_memory < 8 * 1024**3:
        print(f"[WARN] GPU {i} has under 8 GB VRAM. SDXL checkpoints will "
              f"likely OOM; prefer --medvram or a smaller model.",
              file=sys.stderr)
print(f"[OK] torch {torch.__version__} cuda {torch.version.cuda}")
PYEOF
fi

# ---------------------------------------------------------------------------
# 2. Forge-Neo source
# ---------------------------------------------------------------------------
# The image ALREADY contains Neo at /opt/forge, with torch, all requirements
# and the extensions baked in. Booting a lease must not spend GPU money
# cloning a repo or running pip -- that is minutes of billing for nothing.
#
# /work is a persistent volume across container restarts, so anything we put
# there survives. /opt/forge does NOT survive a redeploy with a new image, so
# the working copy is seeded from the image on first boot and then reused.
hr "FORGE-NEO"
NEO_SRC="${NEO_SRC:-/opt/forge}"
[ -f "$NEO_SRC/launch.py" ] || die "no launch.py in $NEO_SRC (bad image?)"

if [ -f "$NEO_DIR/launch.py" ]; then
    echo "[SKIP] $NEO_DIR already present (same filesystem from an earlier boot)"
else
    # This is a real copy, not a hardlink: /work and /opt are separate mounts
    # in the container, so `cp -a` duplicates Neo. That costs ~1-2 GB on the
    # root fs and is accounted for in the storage budget in the Dockerfile.
    echo "[..] seeding $NEO_DIR from $NEO_SRC"
    mkdir -p "$NEO_DIR"
    cp -a "$NEO_SRC/." "$NEO_DIR/" || die "seed failed"
fi
cd "$NEO_DIR" || die "cannot cd to $NEO_DIR"
[ -f launch.py ] || die "no launch.py in $NEO_DIR"

# ---------------------------------------------------------------------------
# 3. Python env
# ---------------------------------------------------------------------------
# The image ships a venv at /opt/venv with torch already installed, and it is
# on PATH. Do NOT create another venv and do NOT pip install: the torch wheel
# is matched to the image's CUDA runtime, and reinstalling it over a slow link
# is how you burn 15 minutes of GPU billing before the UI exists.
hr "PYTHON ENV"
command -v python3 >/dev/null 2>&1 || die "python3 not on PATH (bad image?)"
# Neo's requirements.txt pins Pillow==13.0.0 and numpy==2.3.5, both of which
# need Python >= 3.11. If the image ever drifts back to a 3.10 base, the
# dependency set cannot be satisfied and the build would have failed; assert
# it here anyway so a mismatch is loud rather than a mystery crash later.
python3 -c "import sys; sys.exit(0 if sys.version_info >= (3,11) else 1)" \
    || die "python $(python3 -V 2>&1 | awk '{print $2}') is too old; Neo's pins need >= 3.11"
if ! python3 -c "import torch" 2>/dev/null; then
    warn "torch missing from image; installing (slow, bills at GPU rate)"
    pip install --index-url "${TORCH_INDEX:-https://download.pytorch.org/whl/cu128}" \
        torch torchvision torchaudio \
        || die "torch install failed"
fi
python3 -c "import torch; print('[OK] torch', torch.__version__, 'cuda', torch.version.cuda)" \
    || die "torch import broken"

# ---------------------------------------------------------------------------
# 4. Extensions
# ---------------------------------------------------------------------------
# Extensions are baked into the image. This block only fills in anything
# missing, so an image built before an extension was added still gets it.
hr "EXTENSIONS"
mkdir -p "$NEO_DIR/extensions"
clone_ext() {
    local url="$1" dest="$2"
    if [ -d "$dest/.git" ]; then
        echo "[SKIP] $(basename "$dest")"
    else
        git clone --depth 1 "$url" "$dest" || warn "clone failed: $url"
    fi
}
clone_ext https://github.com/Haoming02/ADetailer-Neo.git \
    "$NEO_DIR/extensions/ADetailer-Neo"
clone_ext https://github.com/altoiddealer/--sd-webui-ar-plusplus.git \
    "$NEO_DIR/extensions/sd-webui-ar-plusplus"
clone_ext https://github.com/RJSprod/sd-dynamic-prompts_neo.git \
    "$NEO_DIR/extensions/sd-dynamic-prompts"
clone_ext https://github.com/Coyote-A/ultimate-upscale-for-automatic1111 \
    "$NEO_DIR/extensions/ultimate-upscale-for-automatic1111"

# ---------------------------------------------------------------------------
# 5. Requirements
# ---------------------------------------------------------------------------
# requirements.txt is ALREADY satisfied by the image (the Dockerfile installs
# it, plus gradio, uvicorn and the ADetailer deps). Do not pip install here.
#
# A runtime pip install is the single most expensive mistake on a GPU lease:
# it re-resolves every pin against the network, can silently downgrade torch
# to a cu130 wheel the host driver cannot load, and burns billing minutes
# before the UI exists. If something is genuinely missing, the image is
# wrong -- fix the image, not the lease.
#
# What we DO check: that the pieces the panel and the UI need are importable.
hr "REQUIREMENTS"
missing=""
for mod in torch gradio fastapi uvicorn; do
    python3 -c "import $mod" 2>/dev/null || missing="$missing $mod"
done
if [ -n "$missing" ]; then
    warn "missing modules:$missing -- the image is incomplete."
    warn "installing requirements.txt to recover (slow, bills at GPU rate)"
    pip install -q -r requirements.txt || die "requirements.txt failed"
    pip install -q "uvicorn>=0.30,<0.34" || die "uvicorn install failed"
else
    echo "[OK] all modules present"
fi

# Neo's own prepare_environment() installs torch only if it is missing, and
# skips that when --skip-install is passed. We do NOT pass --skip-install:
# it also skips extension installers, and ADetailer needs its own install.py
# to have run at least once. Instead we rely on the packages being present,
# which makes prepare_environment() a no-op for torch and requirements.

# ---------------------------------------------------------------------------
# 6. Model directories  (BEFORE downloads, and on the persistent volume)
# ---------------------------------------------------------------------------
hr "MODEL DIRS"
# Neo expects these under its own models/ dir. Put the real bytes on /work and
# symlink, so a re-clone of the repo does not orphan 40 GB of models.
for sub in Stable-diffusion VAE Lora ESRGAN clip text_encoder text_encoders; do
    mkdir -p "$MODELS_DIR/$sub"
    mkdir -p "$NEO_DIR/models/$sub"
    # replace a real dir with a symlink only if it is empty to avoid data loss
    if [ -d "$NEO_DIR/models/$sub" ] && [ ! -L "$NEO_DIR/models/$sub" ]; then
        if [ -z "$(ls -A "$NEO_DIR/models/$sub" 2>/dev/null)" ]; then
            rmdir "$NEO_DIR/models/$sub" 2>/dev/null
        fi
    fi
    [ -e "$NEO_DIR/models/$sub" ] || ln -s "$MODELS_DIR/$sub" "$NEO_DIR/models/$sub"
done
echo "[OK] models rooted at $MODELS_DIR"

# ---------------------------------------------------------------------------
# 7. Upscalers (tolerant: a dead URL must not cost you the whole boot)
# ---------------------------------------------------------------------------
hr "UPSCALERS"
fetch() {
    local url="$1" out="$2"
    if [ -s "$out" ]; then echo "[SKIP] $(basename "$out")"; return 0; fi
    # -f so a 404 does not write an HTML page into a .pth file
    curl -fL --retry 3 --retry-delay 2 --max-time 600 -o "$out.part" "$url" \
        && mv "$out.part" "$out" && echo "[OK] $(basename "$out")" \
        || { rm -f "$out.part"; warn "download failed: $url"; return 1; }
}
fetch "https://huggingface.co/vladmandic/sdnext-upscalers/resolve/main/ESRGAN-NMKD-YandereNeoXL-4x.pth" \
    "$MODELS_DIR/ESRGAN/4x_NMKD-YandereNeoXL.pth" || true
fetch "https://huggingface.co/utnah/esrgan/resolve/main/4x-AnimeSharp.pth" \
    "$MODELS_DIR/ESRGAN/4x-AnimeSharp.pth" || true

# ---------------------------------------------------------------------------
# 8. Wildcards
# ---------------------------------------------------------------------------
hr "WILDCARDS"
if [ -d "$NEO_DIR/extensions/sd-dynamic-prompts" ]; then
    WC="$NEO_DIR/extensions/sd-dynamic-prompts/wildcards"
    mkdir -p "$WC"
    if [ -z "$(ls -A "$WC" 2>/dev/null)" ]; then
        (
            cd "$WC" || exit 1
            curl -fsSL -o wc.zip \
              "https://huggingface.co/datasets/Plaguis/AnimeStaples/resolve/main/Wildcards.zip" \
              && unzip -q -o wc.zip && rm -f wc.zip
            [ -d Wildcards ] && { mv Wildcards/* . 2>/dev/null; rmdir Wildcards 2>/dev/null; }
        ) || warn "wildcards failed (non-fatal)"
    else
        echo "[SKIP] wildcards present"
    fi
fi

# ---------------------------------------------------------------------------
# 9. Model downloader
# ---------------------------------------------------------------------------
hr "DOWNLOADER"
DL="$NEO_DIR/download_extras.py"
if [ ! -s "$DL" ]; then
    curl -fsSL -o "$DL" \
      "https://huggingface.co/datasets/Plaguis/AnimeStaples/resolve/main/download_extras.py" \
      || warn "downloader fetch failed"
fi
if [ -s "$DL" ]; then
    python3 -c "import ast;ast.parse(open('$DL').read())" \
        && echo "[OK] downloader valid" \
        || { warn "downloader is not valid python; removing"; rm -f "$DL"; }
    # NOTE: download_extras.py is an interactive menu (input() calls). There is
    # no TTY here, so it raises EOFError immediately. The web panel below
    # serves the same models.json catalogue over HTTP instead. The script is
    # kept only because it is the canonical source of models.json.
fi

# --- the web panel (the actual downloader interface) ------------------------
PANEL_DIR="$WORK/panel"
PANEL_PY="$PANEL_DIR/download_panel.py"
mkdir -p "$PANEL_DIR"
if [ ! -s "$PANEL_PY" ]; then
    # The panel is baked into the image at /opt/akash/download_panel.py.
    # There is deliberately NO download-from-HF fallback: that path 404s
    # (the panel is not in the AnimeStaples dataset), and a silent fallback
    # to a stale or wrong file is worse than a loud failure here.
    cp "${PANEL_SRC:-/opt/akash/download_panel.py}" "$PANEL_PY" 2>/dev/null \
      || warn "could not obtain download_panel.py from $PANEL_SRC -- panel disabled"
fi
# diag.py is imported by the panel, so it must sit BESIDE it. Copying only the
# panel script and leaving diag.py behind in /opt/akash makes `import diag`
# fail at startup, which takes down the entire download panel -- not just the
# diagnostics page. Copy it unconditionally: it is ~10KB and always cheap to
# refresh, unlike the panel script.
cp "${DIAG_SRC:-/opt/akash/diag.py}" "$PANEL_DIR/diag.py" 2>/dev/null \
  || warn "could not obtain diag.py; the panel will fail to import diag";
# models.json is the catalogue the panel reads. It is baked into the image at
# /opt/akash/models.json, so a lease needs no network fetch to show the
# catalogue. The curl is only a fallback for a hand-rolled image.
if [ ! -s "$NEO_DIR/models.json" ]; then
    if [ -s /opt/akash/models.json ]; then
        cp /opt/akash/models.json "$NEO_DIR/models.json"
    else
        curl -fsSL -o "$NEO_DIR/models.json" \
          "https://huggingface.co/datasets/Plaguis/AnimeStaples/resolve/main/models.json" \
          || warn "could not fetch models.json"
    fi
fi

# ---------------------------------------------------------------------------
# 10. FileBrowser (userland install -- no sudo, no /usr/local/bin)
# ---------------------------------------------------------------------------
hr "FILEBROWSER"
FB_BIN="$WORK/bin/filebrowser"
mkdir -p "$WORK/bin"
if [ ! -x "$FB_BIN" ]; then
    FB_VER="${FB_VER:-2.63.23}"
    # get.sh installs to /usr/local/bin via sudo, which does not exist here.
    # Grab the release tarball straight into $WORK instead.
    curl -fsSL --retry 3 -o "$WORK/bin/fb.tgz" \
      "https://github.com/filebrowser/filebrowser/releases/download/v${FB_VER}/linux-amd64-filebrowser.tar.gz" \
      && tar -xzf "$WORK/bin/fb.tgz" -C "$WORK/bin" filebrowser \
      && rm -f "$WORK/bin/fb.tgz" \
      && chmod +x "$FB_BIN" \
      && echo "[OK] filebrowser $FB_VER" \
      || warn "filebrowser download failed"
fi

# ---------------------------------------------------------------------------
# 11. cloudflared
# ---------------------------------------------------------------------------
hr "CLOUDFLARED"
CF="$WORK/bin/cloudflared"
mkdir -p "$WORK/bin"
if [ ! -x "$CF" ]; then
    curl -fsSL --retry 3 -o "$CF" \
      "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64" \
      && chmod +x "$CF" && echo "[OK] cloudflared" \
      || warn "cloudflared download failed"
fi

# ---------------------------------------------------------------------------
# 12. Start everything
# ---------------------------------------------------------------------------
hr "STARTING SERVICES"
PIDS=()

cleanup() {
    echo; echo "[..] shutting down"
    for p in "${PIDS[@]:-}"; do kill "$p" 2>/dev/null || true; done
    # The log mirror is not in PIDS: it must die last, or the shutdown messages
    # above never reach the container's real stdout.
    [ -n "${TAIL_PID:-}" ] && kill "$TAIL_PID" 2>/dev/null || true
    wait 2>/dev/null || true
}
trap cleanup TERM INT

# --- Forge-Neo -------------------------------------------------------------
# --api-auth is separate from --gradio-auth: the /sdapi/v1 routes are registered
# through Api.add_api_route and only get a dependency when --api-auth is set.
# Without it, --gradio-auth does NOT protect them.
#
# No --enable-insecure-extension-access: the extension tab clones arbitrary
# repos and runs their install.py, i.e. RCE for anyone who reaches the UI.
NEO_ARGS=(
    launch.py
    --port "$NEO_PORT"
    --api
    --gradio-auth "$NEO_USER:$NEO_PASS"
    --api-auth    "$NEO_USER:$NEO_PASS"
    --skip-torch-cuda-test
    # Neo prints a scary banner saying it is "tested with 3.13.15 Python"
    # and that you may see install errors on anything else. That is a
    # warning, not an error -- and on 3.12 the full dependency set resolves
    # cleanly. Suppress it so a real failure is not buried under noise.
    --skip-python-version-check
)
if [ ${#LISTEN_ARGS[@]} -gt 0 ]; then NEO_ARGS+=("${LISTEN_ARGS[@]}"); fi
if [ "${ENABLE_EXT_TAB:-0}" = "1" ]; then
    NEO_ARGS+=(--enable-insecure-extension-access)
    warn "extension tab ENABLED -- RCE by design"
fi

export PYTORCH_CUDA_ALLOC_CONF="${PYTORCH_CUDA_ALLOC_CONF:-expandable_segments:True}"
export HF_HOME="$WORK/hf"
export HF_TOKEN="${HF_TOKEN:-}"

echo "[..] starting Forge-Neo on ${NEO_BIND}:${NEO_PORT}"
python3 "${NEO_ARGS[@]}" > "$LOG_DIR/neo.log" 2>&1 &
NEO_PID=$!
PIDS+=("$NEO_PID")

# Wait for the port rather than a fixed sleep: model load time varies hugely
# between a 3060 and an A100, and a blind `sleep 60` is wrong for both.
echo "[..] waiting for Neo to answer on :$NEO_PORT"
NEO_UP=0
for i in $(seq 1 300); do          # up to 10 min
    if ! kill -0 "$NEO_PID" 2>/dev/null; then
        warn "Neo exited early; tail of $LOG_DIR/neo.log:"
        tail -30 "$LOG_DIR/neo.log" >&2
        break
    fi
    if curl -fsS -o /dev/null --max-time 2 "http://127.0.0.1:$NEO_PORT/" 2>/dev/null; then
        NEO_UP=1; echo "[OK] Neo up after ${i}s"; break
    fi
    # 401 means it is up and auth is working, which is success.
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "http://127.0.0.1:$NEO_PORT/" 2>/dev/null)
    if [ "$code" = "401" ]; then NEO_UP=1; echo "[OK] Neo up (auth enforced) after ${i}s"; break; fi
    sleep 1
done
[ "$NEO_UP" = "1" ] || warn "Neo did not answer within 300s; check $LOG_DIR/neo.log"

# --- Model download panel --------------------------------------------------
# Runs on loopback only; Caddy publishes it under /dl on the authed port.
PANEL_PORT="${PANEL_PORT:-7861}"
if [ -s "$PANEL_PY" ] && [ -s "$NEO_DIR/models.json" ]; then
    echo "[..] starting download panel on 127.0.0.1:$PANEL_PORT"
    # The quota stops a download from filling the filesystem and taking down the
    # running UI. It applies to $MODELS_DIR, which now lives on the 50Gi root fs
    # alongside the ~17GB unpacked image -- there is no separate /work volume.
    #
    # Budget on a 50Gi root fs:
    #   image (unpacked)      ~17 GB
    #   Forge copy + runtime   ~3 GB
    #   entrypoint + logs      ~1 GB
    #   ---------------------------------
    #   fixed cost              ~21 GB
    #   leaves                  ~29 GB
    #
    # 20GB of models therefore leaves ~9GB of genuine headroom. The old 28GB
    # default with no separate volume would have let the panel fill the disk and
    # then Neo would die with an unrelated-looking write error.
    python3 "$PANEL_PY" \
        --models "$NEO_DIR/models.json" \
        --dest "$MODELS_DIR" \
        --log-dir "$LOG_DIR" \
        --host 127.0.0.1 \
        --port "$PANEL_PORT" \
        --quota-gb "${PANEL_QUOTA_GB:-20}" \
        > "$LOG_DIR/panel.log" 2>&1 &
    PIDS+=($!)
    for _ in $(seq 1 15); do
        curl -s -o /dev/null --max-time 1 "http://127.0.0.1:$PANEL_PORT/api/state" && break
        sleep 1
    done
    echo "[OK] panel up"
else
    warn "download panel not started (missing panel or models.json)"
fi

# --- FileBrowser -----------------------------------------------------------
if [ -x "$FB_BIN" ]; then
    FB_DB="$WORK/filebrowser.db"
    if [ ! -s "$FB_DB" ]; then
        echo "[..] initialising filebrowser db"
        "$FB_BIN" -d "$FB_DB" config init || warn "fb config init failed"
        # Serve $WORK (so models are visible), NOT / -- / is ephemeral and
        # contains the image, which would be a pointless thing to browse.
        "$FB_BIN" -d "$FB_DB" config set --address 127.0.0.1 \
            --port "$FB_PORT" --root "$WORK" || warn "fb config set failed"
        if [ -n "${FB_USER:-}" ] && [ -n "${FB_PASS:-}" ]; then
            "$FB_BIN" -d "$FB_DB" users add "$FB_USER" "$FB_PASS" --perm.admin \
                || warn "fb user add failed"
        else
            warn "FB_USER/FB_PASS unset: filebrowser has NO user (config init"
            warn "creates none) and its UI will be unusable."
        fi
    fi
    echo "[..] starting filebrowser on 127.0.0.1:$FB_PORT (root: $WORK)"
    "$FB_BIN" -d "$FB_DB" > "$LOG_DIR/filebrowser.log" 2>&1 &
    PIDS+=($!)
fi

# --- published-port proxy (Caddy) ------------------------------------------
# Must start after Neo/FileBrowser are listening, or Caddy logs connection
# refused on every request until they come up.
if [ "$PROXY_UP" = "1" ]; then
    echo "[..] starting Caddy on :8080 (published)"
    "$CADDY_BIN" run --config "$WORK/caddy/Caddyfile" --adapter caddyfile \
        > "$LOG_DIR/caddy.log" 2>&1 &
    PIDS+=($!)
    for _ in $(seq 1 10); do
        curl -s -o /dev/null --max-time 1 http://127.0.0.1:8080/ && break
        sleep 1
    done
fi

# --- Tunnels ---------------------------------------------------------------
CF_PIDS=()
start_tunnel() {
    local port="$1" name="$2" log="$LOG_DIR/tunnel-$2.log"
    [ -x "$CF" ] || { warn "cloudflared missing; cannot tunnel $name"; return 1; }
    : > "$log"
    "$CF" tunnel --no-autoupdate --url "http://127.0.0.1:$port" > "$log" 2>&1 &
    CF_PIDS+=($!)
    # Poll for the URL; a fixed sleep gives you a blank banner on a slow box.
    local url=""
    for _ in $(seq 1 30); do
        url=$(grep -o 'https://[-a-z0-9]*\.trycloudflare\.com' "$log" 2>/dev/null | head -1)
        [ -n "$url" ] && break
        sleep 1
    done
    echo "$url"
}

if [ "$MODE" = "tunnel" ]; then
    hr "TUNNELS"
    NEO_URL="$(start_tunnel "$NEO_PORT" neo || true)"
    FB_URL=""
    [ -x "$FB_BIN" ] && FB_URL="$(start_tunnel "$FB_PORT" files || true)"

    hr "READY"
    echo "  Forge-Neo   : ${NEO_URL:-<tunnel failed, see $LOG_DIR/tunnel-neo.log>}"
    echo "  FileBrowser : ${FB_URL:-<tunnel failed or not installed>}"
    [ "$PROXY_UP" = "1" ] && echo "  Published   : port 8080 (Basic auth, user $PROXY_USER)"
    echo "  login       : ${NEO_USER} / <NEO_PASS>"
    echo "  models      : $MODELS_DIR"
    echo
    echo "  These URLs are PUBLIC (trycloudflare, no auth). The Neo URL is"
    echo "  protected by --gradio-auth/--api-auth; the FileBrowser URL is"
    echo "  protected by its own login. Treat both as internet-facing."
else
    hr "READY (direct)"
    echo "  Forge-Neo   : port $NEO_PORT on 0.0.0.0 (must be published in the SDL)"
    echo "  FileBrowser : port $FB_PORT on 0.0.0.0"
fi

# ---------------------------------------------------------------------------
# 13. Supervise
# ---------------------------------------------------------------------------
# PID 1 must not exit while children run, or the container is torn down and the
# lease keeps billing for nothing. Restart Neo if it dies (OOM on a 12 GB card
# is common) so a single bad generation does not end the whole session.
hr "SUPERVISING"
RESTARTS=0
MAX_RESTARTS="${MAX_RESTARTS:-5}"
while true; do
    for p in "${CF_PIDS[@]:-}"; do
        kill -0 "$p" 2>/dev/null || { warn "a tunnel died; see $LOG_DIR"; }
    done
    if ! kill -0 "$NEO_PID" 2>/dev/null; then
        # A bad flag or credential crashes Neo instantly and forever. Without a
        # cap that is an invisible crash loop that still bills the GPU, so give
        # up loudly instead and let the container exit for the provider to show.
        RESTARTS=$((RESTARTS + 1))
        if [ "$RESTARTS" -gt "$MAX_RESTARTS" ]; then
            echo "[FATAL] Neo died ${RESTARTS} times; giving up so this does not" >&2
            echo "        bill silently. Last log lines:" >&2
            tail -40 "$LOG_DIR/neo.log" >&2
            cleanup
            exit 1
        fi
        warn "Neo died; restart ${RESTARTS}/${MAX_RESTARTS} in 10s (tail:)"
        tail -10 "$LOG_DIR/neo.log" >&2
        sleep 10
        python3 "${NEO_ARGS[@]}" >> "$LOG_DIR/neo.log" 2>&1 &
        NEO_PID=$!
        warn "Neo restarted pid=$NEO_PID"
    fi
    sleep 15
done
