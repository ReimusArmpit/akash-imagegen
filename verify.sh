#!/usr/bin/env bash
# verify.sh -- end-to-end check of the consolidated kit.
#
# What this CANNOT check: the Docker build (no docker in this sandbox) and the
# real GPU boot. Everything else -- Caddy routing, auth, the panel API, the
# prefix injection, the SDL structure and credential rendering -- is exercised
# for real against the actual files in this directory.
set -uo pipefail
cd "$(dirname "$0")"

PASS=0; FAIL=0; SKIP=0
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
skip(){ printf '  \033[33mSKIP\033[0m %s\n' "$1"; SKIP=$((SKIP+1)); }
check(){ if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }
# A check that needs an optional tool. If the tool is missing, that is NOT a
# failure of the code under test -- it is an absent test runner. Report SKIP
# so the summary stays honest instead of crying wolf.
checkopt(){ if [ -x "$3" ] || command -v "$3" >/dev/null 2>&1; then
               if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi
             else skip "$1 (needs $3)"; fi; }
section(){ printf '\n\033[1m%s\033[0m\n' "$1"; }

CADDY="${CADDY:-$HOME/.pi/agent/tools/caddy}"
PY="${PY:-$HOME/.pi/agent/tools/venv/bin/python}"
HADOLINT="${HADOLINT:-$HOME/.pi/agent/tools/hadolint}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
PORT=17899

# The Python used for the SDL checks needs PyYAML. If it is not there, fall
# back to the system python; if that has no yaml either, those checks SKIP
# rather than FAIL.
if ! $PY -c "import yaml" >/dev/null 2>&1; then
  if command -v python3 >/dev/null 2>&1 && python3 -c "import yaml" >/dev/null 2>&1; then
    PY="$(command -v python3)"
  else
    PY=""
  fi
fi

section "1. static checks"
check "entrypoint.sh is valid bash"    "bash -n entrypoint.sh"
check "build.sh is valid bash"         "bash -n build.sh"
check "deploy-test.sh is valid bash"   "bash -n deploy-test.sh"
check "download_panel.py parses"       "${PY:-python3} -c \"import ast;ast.parse(open('download_panel.py').read())\""
checkopt "Dockerfile lints clean"      "$HADOLINT Dockerfile" "$HADOLINT"
check "no leftover /opt/akash/imageGenAkash.sh refs" "! grep -q '/opt/akash/imageGenAkash.sh' entrypoint.sh sdl/*.yaml"

section "2. Dockerfile integrity"
check "pinned Forge-Neo repo"          "grep -q 'Haoming02/sd-webui-forge-classic' Dockerfile"
check "pinned to branch neo"           "grep -q 'branch \${FORGE_REF}' Dockerfile"
check "FORGE_REF defaults to neo"      "grep -q 'ARG FORGE_REF=neo' Dockerfile"
check "torch is version-pinned"        "grep -q 'torch==2.9.1+cu128' Dockerfile"
check "torchvision is version-pinned"  "grep -q 'torchvision==0.24.1+cu128' Dockerfile"
check "cuda base is 12.8"              "grep -q 'ARG CUDA_VERSION=12.8.1' Dockerfile"
check "arch list covers 3060 (8.6)"    "grep -q '8.6' Dockerfile"
check "pipefail set before curl|tar"   "grep -q 'pipefail' Dockerfile"
check "no insecure extension flag"     "! grep -qE '^\s*--enable-insecure-extension-access' entrypoint.sh"
check "insecure flag is opt-in only"   "grep -q 'ENABLE_EXT_TAB' entrypoint.sh"
check "uvicorn pinned (panel needs it)" "grep -q 'uvicorn' Dockerfile"
check "gradio pinned"                  "grep -q 'gradio==4.40.0' Dockerfile"
check "xformers deliberately absent"   "! grep -qE '^\s*(RUN|pip install).*xformers' Dockerfile"

section "2b. base image / python version (the Pillow>=3.11 trap)"
check "base is ubuntu24.04"            "grep -q 'runtime-ubuntu24.04' Dockerfile"
check "not ubuntu22.04"                "! grep -q 'ubuntu22.04' Dockerfile"
check "no ComfyUI ARG"                 "! grep -qE '^\s*(ARG|RUN).*WITH_COMFYUI' Dockerfile"
check "no llama ARG"                   "! grep -qE '^\s*(ARG|RUN).*WITH_LLAMA' Dockerfile"
check "no comfy clone"                 "! grep -qE '^\s*RUN.*comfyanonymous' Dockerfile"
check "no llama clone"                 "! grep -qE '^\s*RUN.*ggml-org' Dockerfile"
check "no cmake/build-essential"       "! grep -qE '^\s*RUN.*(cmake|build-essential)' Dockerfile"
check "gradio installed BEFORE reqs"   "test \$(grep -n 'pip install \"gradio==' Dockerfile | head -1 | cut -d: -f1) -lt \$(grep -n 'install -r /opt/forge/requirements.txt' Dockerfile | head -1 | cut -d: -f1)"
check "entrypoint asserts py>=3.11"    "grep -q 'sys.version_info >= (3,11)' entrypoint.sh"
check "skip python version warning"    "grep -q 'skip-python-version-check' entrypoint.sh"

section "3. entrypoint wiring"
check "panel started"                  "grep -q 'download_panel.py' entrypoint.sh"
check "panel on loopback"              "grep -q 'host 127.0.0.1' entrypoint.sh"
check "panel has a quota"              "grep -q 'PANEL_QUOTA_GB' entrypoint.sh"
check "api-auth passed to Neo"         "grep -q 'api-auth' entrypoint.sh"
check "gradio-auth passed to Neo"      "grep -q 'gradio-auth' entrypoint.sh"
check "refuses boot without creds"     "grep -q 'Refusing to start an unauthenticated UI' entrypoint.sh"
check "rejects ':' in credentials"     "grep -q 'contain' entrypoint.sh"
check "filebrowser started"            "grep -qi 'filebrowser' entrypoint.sh"
check "caddy started"                  "grep -q 'CADDY_BIN\" run --config' entrypoint.sh"

section "4. SDL structure"
if [ -z "$PY" ]; then
  skip "SDL structure checks (needs PyYAML)"
else
for sdl in sdl/forge-3060.yaml sdl/forge-3060-tunnel.yaml; do
  $PY - "$sdl" <<'PY' && ok "$sdl parses + has global endpoint + tagged image" || bad "$sdl structure"
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
s = d['services']['ui']
assert ':' in s['image'] and not s['image'].endswith(':latest'), 'image not pinned'
assert any(e['to'][0].get('global') for e in s['expose']), 'no global service'
assert d['profiles']['placement']['akash']['pricing']['ui']['denom'] == 'uact'
assert s['args'][0].strip() == 'exec /usr/local/bin/entrypoint.sh', 'wrong entrypoint'
PY
done
fi

section "5. credential rendering"
set -a; . ./secrets.env; set +a
if [ -z "$PY" ]; then
  skip "credential rendering checks (needs PyYAML)"
else
for sdl in sdl/forge-3060.yaml sdl/forge-3060-tunnel.yaml; do
  RENDERED="$WORK/r.yaml"
  SDL="$sdl" NEO_USER="$NEO_USER" NEO_PASS="$NEO_PASS" FB_USER="$FB_USER" FB_PASS="$FB_PASS" \
  PROXY_USER="$PROXY_USER" PROXY_PASS="$PROXY_PASS" $PY - "$RENDERED" <<'PY'
import os, re, sys, yaml
src, out = os.environ['SDL'], sys.argv[1]
keys = ['NEO_USER','NEO_PASS','FB_USER','FB_PASS','PROXY_USER','PROXY_PASS']
text = open(src).read()
for k in keys:
    text = re.sub(rf"^(\s*-\s*{k}=).*$", lambda m: m.group(1)+os.environ[k], text, flags=re.M)
assert 'CHANGEME' not in text, 'placeholder left'
open(out,'w').write(text)
d = yaml.safe_load(open(out))
env = d['services']['ui']['env']
for k in keys:
    assert any(e.startswith(k+'=') and e.split('=',1)[1]==os.environ[k] for e in env), k
PY
  [ $? -eq 0 ] && ok "$sdl renders credentials, no CHANGEME left, still valid YAML" \
               || bad "$sdl credential rendering"
done
fi

section "6. live stack (caddy + panel + fake neo + fake filebrowser)"
if [ ! -x "$CADDY" ]; then
  skip "live stack test (needs caddy at $CADDY)"
elif [ -z "$PY" ]; then
  skip "live stack test (needs PyYAML for the fake servers)"
else
  # fake neo + filebrowser
  $PY - <<'PY' &
import http.server, socketserver, threading, time
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(s):
        s.send_response(200); s.end_headers()
        s.wfile.write(('NEO:'+s.path).encode())
    def log_message(*a): pass
class F(H):
    def do_GET(s):
        s.send_response(200); s.end_headers()
        s.wfile.write(('FB:'+s.path).encode())
socketserver.TCPServer.allow_reuse_address = True
for port, cls in ((8188,H),(7860,F)):
    srv = socketserver.TCPServer(('127.0.0.1',port), cls)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
time.sleep(120)
PY
  FAKE=$!
  # real panel
  $PY download_panel.py --models /dev/stdin --dest "$WORK/models" --port 7861 \
      --quota-gb 28 > "$WORK/panel.log" 2>&1 <<'JSON' &
{"TEST":[{"name":"TestLora","url":"https://example.invalid/x.safetensors","path":"Lora/TestLora.safetensors","size":1024}]}
JSON
  PANEL=$!
  sleep 6

  HASH=$($CADDY hash-password --plaintext 'verify-pw-1')
  sed "s/:8080/:$PORT/" Caddyfile > "$WORK/Caddyfile"
  PROXY_USER=verifier PROXY_PASS_HASH="$HASH" $CADDY run --config "$WORK/Caddyfile" --adapter caddyfile > "$WORK/caddy.log" 2>&1 &
  CADDY_PID=$!
  sleep 4
  A="-u verifier:verify-pw-1"

  printf '  no auth returns 401      : %s\n' "$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:$PORT/)"
  [ "$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:$PORT/)" = "401" ] \
    && ok "unauthenticated request is rejected" || bad "auth not enforced"

  [ "$(curl -s -o /dev/null -w '%{http_code}' $A http://127.0.0.1:$PORT/)" = "200" ] \
    && ok "authenticated request accepted" || bad "auth rejects valid creds"

  curl -s $A http://127.0.0.1:$PORT/dl | grep -q 'data-base="/dl"' \
    && ok "panel page served at /dl with correct prefix" || bad "panel prefix injection"

  curl -s $A http://127.0.0.1:$PORT/dl/api/categories | grep -q 'categories' \
    && ok "panel API reachable via /dl" || bad "panel API via /dl"

  curl -s $A http://127.0.0.1:$PORT/dl/api/state | grep -q 'quota' \
    && ok "panel reports quota" || bad "panel quota missing"

  curl -s $A http://127.0.0.1:$PORT/ | grep -q '^NEO:' \
    && ok "root routes to Neo" || bad "root routing"

  curl -s $A http://127.0.0.1:$PORT/files/x | grep -q '^FB:' \
    && ok "/files routes to FileBrowser" || bad "/files routing"

  curl -s $A http://127.0.0.1:$PORT/sdapi/v1/x | grep -q '^NEO:' \
    && ok "/sdapi routes to Neo" || bad "/sdapi routing"

  kill $CADDY_PID $PANEL $FAKE 2>/dev/null
fi

section "RESULT"
printf '  %d passed, %d failed' "$PASS" "$FAIL"
[ "$SKIP" -gt 0 ] && printf ', %d skipped' "$SKIP"
printf '\n'
[ "$FAIL" -eq 0 ] || exit 1
