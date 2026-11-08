#!/usr/bin/env bash
# build.sh — build and push the image, then print the exact pinned reference
# to paste into the SDL. Akash rejects :latest and untagged images, so the
# default tag is a short git hash (or $TAG).
#
# Build time: ~8-15 min on a laptop. The old 4-mode image took 25-40 min
# because it compiled llama.cpp's CUDA kernels and installed torch twice.
# This one is Forge-only with torch baked in, so it is a git clone and a pip
# resolve. Do this BEFORE you start watching for the card — you do not want
# to be building while a 1-of-1 GPU sits idle.
#
# ENV
#   REGISTRY / USER_NS / NAME / TAG   image coordinates
#   CUDA_VERSION  12.8.1              base CUDA tag
#   FORGE_REF     neo                 the Forge-Neo branch
#   NO_PUSH=1                          build only
#   NO_ANON_PULL_CHECK=1               skip the manifest check
#
# There are no optional blocks. ComfyUI and llama.cpp were removed — see the
# comment block in the Dockerfile for why, and for what it would cost to add
# llama.cpp back (a 179MB prebuilt tarball, not a 15-minute CUDA compile).

set -euo pipefail
cd "$(dirname "$0")"

REGISTRY="${REGISTRY:-docker.io}"
USER_NS="${USER_NS:-YOURUSER}"
NAME="${NAME:-akash-imagegen}"
TAG="${TAG:-$(git rev-parse --short HEAD 2>/dev/null || date +%Y%m%d%H%M)}"
IMAGE="${REGISTRY}/${USER_NS}/${NAME}:${TAG}"

echo "==> image: ${IMAGE}"

# --- build -----------------------------------------------------------------
DOCKER_BUILDKIT=1 docker build \
  --build-arg CUDA_VERSION="${CUDA_VERSION:-12.8.1}" \
  ${FORGE_REF:+--build-arg FORGE_REF="$FORGE_REF"} \
  -t "$IMAGE" .

# Docker Hub's anonymous pull rate limit is 100 pulls / 6h per IP — a provider
# IP is shared, so a busy box can fail to pull for reasons that have nothing to
# do with you. Pushing to GHCR (or making the Docker Hub repo public) avoids it.
# Set PUSH_REGISTRY=ghcr.io and PUSH_USER= to use GitHub instead.
if [[ "${NO_PUSH:-0}" != "1" ]]; then
  echo "==> pushing"
  docker push "$IMAGE"
else
  echo "==> NO_PUSH=1, skipping push"
fi

# Verify the remote is anonymously pullable — providers pull without creds.
if [[ "${NO_ANON_PULL_CHECK:-0}" != "1" ]]; then
  echo "==> checking anonymous pull"
  if docker manifest inspect "$IMAGE" >/dev/null 2>&1; then
    echo "    ok: manifest visible"
  else
    echo "    WARN: manifest not publicly visible. Make the repo public or the"
    echo "          provider cannot pull it and the lease will fail to start."
  fi
fi

cat <<EOF

==> done
Paste this into sdl/forge-3060-tunnel.yaml:

  image: ${IMAGE}

Then verify the SDL before you touch the marketplace:

  ./deploy-test.sh preflight

preflight renders the credentials into a private copy and checks the SDL
structurally. It does not spend anything. The GPU rental starts at
./deploy-test.sh create.
EOF
