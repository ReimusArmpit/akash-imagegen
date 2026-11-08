# ============================================================================
# akash-imagegen -- Forge-Neo image for Akash GPU leases.
#
# ONE image, ONE boot path. The container entrypoint (entrypoint.sh) supervises
# Forge-Neo, the model download panel and FileBrowser, and publishes them
# through Caddy (basic auth) and optionally a cloudflared tunnel.
#
# WHY THIS BASE AND THESE PINS
#
# CUDA 12.8 + torch 2.9.1+cu128:
#   * 12.8 is the newest CUDA that still has a torch 2.9.x wheel with wide
#     arch coverage. Neo's own default is torch 2.14.0+cu130, but cu130
#     wheels are built for sm_100/sm_120 only in some builds and require a
#     >=580 host driver. Akash providers hand you whatever driver the host
#     has, and you do not control it.
#   * torch 2.9.x +cu128 supports sm_75 (T4) through sm_90 (H100), which
#     covers every card Akash actually offers.
#   * 13.x dropped Maxwell/Pascal/Volta (sm_50-sm_72); 12.8 keeps sm_75.
#
# TORCH_CUDA_ARCH_LIST: compile the wheels we bake for the cards that matter.
#   7.5  = T4        8.0 = A100     8.6 = A10G/3060/3090
#   8.9 = 4080/4090/Ada  9.0 = H100
#   Not 12.0 (consumer Blackwell) -- that needs cu128+ and a 570+ driver.
#
# XFORMERS: deliberately NOT installed.
#   Neo's backend/memory_management.py wraps the import in try/except and
#   falls back to False, so Forge runs fine on PyTorch native SDPA. xformers
#   wheels are pinned to exact torch versions (0.0.33 -> torch==2.9.0) and
#   are the single most likely thing to break a build or a boot. The panel
#   and the UI work without it; we can add it later as a one-line change.
#
# WHY ONE VENV AND NOT TWO:
#   The old kit had separate venvs for ComfyUI and Forge because their torch
#   pins collided. This image is Forge-only, so there is nothing to collide
#   with. ComfyUI and llama.cpp were removed outright -- see the block near
#   the bottom of this file for why.
#
# SIZE: the root fs on the SDL is 50GiB and must hold the whole image plus
#   your models. Torch alone is ~6 GB of that. ComfyUI + llama.cpp (which
#   compiles CUDA kernels at build time) roughly doubles the image.
# ============================================================================
# ---------------------------------------------------------------------------
# Base image.
#
# Why ubuntu24.04 and not 22.04:
#
#   1. Neo's requirements.txt pins Pillow==13.0.0 and numpy==2.3.5, both of
#      which declare requires_python >=3.11. Ubuntu 22.04 ships Python 3.10,
#      so `pip install -r requirements.txt` CANNOT succeed there -- pip
#      reports "Could not find a version that satisfies the requirement
#      Pillow==13.0.0". Ubuntu 24.04 ships Python 3.12, where every Neo pin
#      resolves (verified against the full dependency graph).
#
#   2. glibc 2.39 instead of 2.35, which is what the llama.cpp CUDA
#      prebuilts need (they require glibc 2.38). Not used right now, but it
#      means a future llama.cpp addition is a 179MB COPY rather than a
#      15-minute CUDA compile.
#
# Why the plain `runtime` tag and not `cudnn-runtime`:
#
#   The torch 2.9.1+cu128 wheel declares the whole CUDA userspace stack as
#   pip dependencies (nvidia-cudnn-cu12==9.10.2.21, nvidia-cublas-cu12,
#   nvidia-nccl-cu12, triton, ...). They land in the venv and torch loads
#   them from there. The base image's own cudnn/cublas copies are therefore
#   duplicated weight -- the cudnn-runtime tag is ~2.6GB compressed vs
#   ~2.0GB for runtime, and both are dwarfed by the pip nvidia-* wheels.
#   The base only really needs to provide glibc, ld.so, and the NVIDIA
#   driver mount point (the driver itself comes from the Akash host).
#
#   We keep `runtime` rather than `base` anyway: it provides the CUDA
#   loader (libcuda stub handling / cudart) that some of the nvidia pip
#   wheels still dlopen by soname, and it is only ~2GB.
# ---------------------------------------------------------------------------
ARG CUDA_VERSION=12.8.1
FROM nvidia/cuda:${CUDA_VERSION}-runtime-ubuntu24.04

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_ROOT_USER_ACTION=ignore \
    HF_HOME=/models/hf \
    HF_HUB_ENABLE_HF_TRANSFER=1 \
    HF_XET_HIGH_PERFORMANCE=1 \
    TORCH_CUDA_ARCH_LIST="7.5 8.0 8.6 8.9 9.0" \
    PATH="/opt/venv/bin:${PATH}" \
    VIRTUAL_ENV=/opt/venv

# Pinnable refs -- bump deliberately, not implicitly.
ARG FORGE_REF=neo
ARG CADDY_VERSION=2.8.4
ARG FILEBROWSER_VERSION=2.63.23
# Caddy 2.8.4 and 2.9.x differ in the basic_auth hash format handling; the
# entrypoint generates the hash at runtime with `caddy hash-password`, so the
# version only has to support the same Caddyfile syntax.

# hadolint ignore=DL3008
RUN apt-get update && apt-get install -y --no-install-recommends \
      python3 python3-pip python3-dev python3-venv \
      git git-lfs curl ca-certificates jq tini unzip \
      ffmpeg libgl1 libglib2.0-0 libsm6 libxext6 libxrender1 \
      aria2 \
    && rm -rf /var/lib/apt/lists/*

# --- Caddy: reverse proxy + HTTP basic auth in front of the web UIs.
# Forge-Neo ships with no auth of its own beyond --gradio-auth/--api-auth,
# but an exposed Akash hostname is world-reachable, so an unauthenticated UI
# is someone else spending your credit.
#
# pipefail matters here: without it, `curl | tar` succeeds even when curl
# fails, because tar gets an empty stream and exits 0. The build would then
# produce an image with no caddy and the container would start with a dead
# published port and no obvious error.
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
RUN curl -fsSL "https://github.com/caddyserver/caddy/releases/download/v${CADDY_VERSION}/caddy_${CADDY_VERSION}_linux_amd64.tar.gz" \
      | tar -xz -C /usr/local/bin caddy \
    && chmod +x /usr/local/bin/caddy \
    && caddy version

# --- FileBrowser: static binary, installed to /usr/local/bin.
# The entrypoint also supports a userland install on $WORK, but baking it
# means one fewer network fetch at boot on a possibly flaky link.
RUN curl -fsSL --retry 3 \
      "https://github.com/filebrowser/filebrowser/releases/download/v${FILEBROWSER_VERSION}/linux-amd64-filebrowser.tar.gz" \
      | tar -xz -C /usr/local/bin filebrowser \
    && chmod +x /usr/local/bin/filebrowser \
    && filebrowser version

# --- cloudflared: optional tunnel for MODE=tunnel.
RUN curl -fsSL --retry 3 -o /usr/local/bin/cloudflared \
      "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64" \
    && chmod +x /usr/local/bin/cloudflared \
    && cloudflared --version

# ---------------------------------------------------------------------------
# Python env + torch.
# The venv is at /opt/venv and is on PATH, so `python3` in the entrypoint is
# the venv python and everything Neo installs lands in the same place.
# ---------------------------------------------------------------------------
RUN python3 -m venv /opt/venv
# hadolint ignore=DL3013
RUN pip install --upgrade pip setuptools wheel \
    && pip install --index-url https://download.pytorch.org/whl/cu128 \
         torch==2.9.1+cu128 torchvision==0.24.1+cu128 torchaudio==2.9.1+cu128

# ---------------------------------------------------------------------------
# Forge-Neo -- Haoming02/sd-webui-forge-classic, branch `neo`.
#
# This is the classic Forge codebase with the Neo extensions: Flux/Illustrious
# support, the newer samplers and the ADetailer-Neo line. It is NOT
# lllyasviel/stable-diffusion-webui-forge, which is a different codebase
# with different flags and different extension compatibility.
#
# torch and torchvision are already installed and importable, so Neo's
# prepare_environment() skips its own torch install (it checks
# `not is_installed("torch")`). That keeps boot fast and stops Neo from
# swapping in a cu130 wheel that the host driver may not support.
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# Order matters here: gradio FIRST, then requirements.txt.
#
# gradio 4.40.0 declares `pillow<11.0`, but Neo's requirements.txt pins
# `Pillow==13.0.0`. The two cannot be satisfied at the same time. Upstream
# Neo resolves it by installing gradio first and requirements.txt second
# (see launch_utils.py: gradio install at ~line 404, requirements install at
# ~line 409), so requirements.txt wins and the final Pillow is 13.0.0 with
# gradio left holding an unsatisfied `pillow<11` upper bound.
#
# We match that order deliberately. Two reasons:
#
#   1. requirements_met() (launch_utils.py:251) reads the pinned version out
#      of requirements.txt and compares it against what is importable. If
#      Pillow ends up at 10.x, requirements_met() returns False at EVERY
#      boot and Neo re-runs `pip install -r requirements.txt` -- a slow,
#      network-dependent step that happens while the GPU lease is billing.
#      Ending with Pillow 13.0.0 keeps that check satisfied forever.
#   2. pillow-heif 1.8.1 (Neo's pin) requires pillow>=11.1.0, so Pillow
#      <11 would break HEIC/AVIF support outright.
#
# gradio 4.40.0 works fine with Pillow 13 in practice -- the upper bound is
# conservative and the APIs it uses are unchanged.
# ---------------------------------------------------------------------------
RUN pip install "gradio==4.40.0" "gradio_rangeslider==0.0.8" \
    && git clone --depth 1 --branch ${FORGE_REF} \
         https://github.com/Haoming02/sd-webui-forge-classic.git /opt/forge \
    && pip install -r /opt/forge/requirements.txt \
    && pip install "uvicorn>=0.30,<0.34" \
    && rm -rf /opt/forge/.git \
    && python -c "import gradio, fastapi, uvicorn, PIL; \
print('gradio', gradio.__version__, '| pillow', PIL.__version__)"

# ---------------------------------------------------------------------------
# Extensions.
#
# These are the ones the imagegen workflow actually uses. They are cloned at
# BUILD time, not boot time, so a lease starts instantly. ADetailer-Neo pulls
# ultralytics+mediapipe via its own install.py at launch, so bake those too
# -- a runtime pip install on a cold container is slow and eats GPU billing.
# ---------------------------------------------------------------------------
RUN git clone --depth 1 https://github.com/Haoming02/ADetailer-Neo.git \
      /opt/forge/extensions/ADetailer-Neo \
    && git clone --depth 1 https://github.com/altoiddealer/--sd-webui-ar-plusplus.git \
      /opt/forge/extensions/sd-webui-ar-plusplus \
    && git clone --depth 1 https://github.com/RJSprod/sd-dynamic-prompts_neo.git \
      /opt/forge/extensions/sd-dynamic-prompts \
    && git clone --depth 1 https://github.com/Coyote-A/ultimate-upscale-for-automatic1111 \
      /opt/forge/extensions/ultimate-upscale-for-automatic1111 \
    && pip install -q ultralytics==8.3.253 mediapipe==0.10.35 \
    && rm -rf /opt/forge/extensions/*/.git

# ===========================================================================
# NO OPTIONAL MODES.
#
# ComfyUI and llama.cpp were previously here behind build ARGs
# (WITH_COMFYUI / WITH_LLAMA). They are removed rather than left disabled:
#
#   * ComfyUI -- not used. It needs its own venv and a second torch install
#     (another ~6GB) for a node-graph UI that Forge already covers.
#   * llama.cpp -- not used on this host, and there is no exec/shell access
#     to the container, so a llama-server binary would be unreachable. It
#     would also need a GGUF model, and there is no upload path for one:
#     the panel only serves the 298 catalogue entries and FileBrowser can
#     move files but cannot fetch them.
#
# If llama.cpp is ever wanted here, the cheap route is the prebuilt CUDA
# tarball (179MB, no compile):
#     curl -fsSL -o /tmp/ll.tgz \
#       https://github.com/ggml-org/llama.cpp/releases/download/b12198/llama-b12198-bin-ubuntu-cuda-12.8-x64.tar.gz
# It needs glibc >= 2.38, which is why the base is ubuntu24.04.
# ===========================================================================

# ---------------------------------------------------------------------------
# Runtime pieces
# ---------------------------------------------------------------------------
# models.json is the catalogue the download panel reads (298 items across 11
# categories). Bake it at BUILD time so a lease does not need a network fetch
# before the panel can start -- and so a failure to reach HF at boot cannot
# leave you with a UI but no way to get models.
RUN curl -fsSL --retry 3 -o /opt/akash/models.json \
      "https://huggingface.co/datasets/Plaguis/AnimeStaples/resolve/main/models.json" \
    && python3 -c "import json;d=json.load(open('/opt/akash/models.json'));\
print('models.json:', sum(len(v) for v in d.values() if isinstance(v,list)), 'items')"

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY Caddyfile /etc/caddy/Caddyfile
COPY download_panel.py /opt/akash/download_panel.py
RUN chmod +x /usr/local/bin/entrypoint.sh

# MODE: tunnel (default, cloudflared only) | direct (bind 0.0.0.0, SDL ports)
ENV MODE=tunnel \
    PORT=8080 \
    WORK=/work \
    NEO_PORT=8188 \
    FB_PORT=7860 \
    PANEL_PORT=7861 \
    PANEL_QUOTA_GB=28

EXPOSE 8080
# tini reaps zombie children; without it the container eventually wedges.
ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["/usr/local/bin/entrypoint.sh"]
