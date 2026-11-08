#!/usr/bin/env bash
# watch-trial.sh — report when THE trial GPU frees up. Read-only; it never rents.
#
# Why not watch-gpus.sh: that polls /v1/gpu-prices, an aggregate across the whole
# network. That number is irrelevant to a trial account. Console only lets a
# trial lease from providers carrying the `console/trials` attribute, and right
# now exactly ONE provider has it:
#
#   provider.hurricane.akash.pub  (akash15tl6v6gd0nte0syyxnv57zmmspgju4c3xfmdhk)
#
# It advertises one GPU model, a T4 16Gi, and while that card is rented its stats
# read {"active":1,"available":0,"total":1}. So the network can show 123 free
# GPUs and a trial deploy still fails with "No node has these GPUs free right
# now" -- that error is about this one occupied card, not about the SDL.
#
# This script performs exactly two HTTP GETs and writes nothing anywhere. It has
# no wallet key and cannot create or accept a lease; renting requires a signed
# transaction from your own Console account, i.e. you clicking Deploy.
#
# Usage:
#   ./watch-trial.sh              # one snapshot
#   ./watch-trial.sh -w           # poll until a GPU frees; beep when it does
#   ./watch-trial.sh -w -i 30     # poll every 30s
#   ./watch-trial.sh -n           # also desktop-notify on availability
#   ./watch-trial.sh -j           # dump raw provider JSON
#
# Exit codes: 0 = a GPU is free, 1 = all rented, 2 = query failed.

set -uo pipefail

API_BASE="${AKASH_API_BASE:-https://console-api.akash.network/v1}"
PROVIDERS="${AKASH_TRIAL_PROVIDERS:-}"   # comma-separated override
INTERVAL=60
LOOP=0
RAW=0
NOTIFY=0

while getopts "wnji:h" opt; do
  case $opt in
    w) LOOP=1 ;;
    i) INTERVAL="$OPTARG" ;;
    j) RAW=1 ;;
    n) NOTIFY=1 ;;
    h) sed -n '2,30p' "$0"; exit 0 ;;
    *) exit 2 ;;
  esac
done

for c in curl python3; do
  command -v "$c" >/dev/null || { echo "need $c" >&2; exit 2; }
done

TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

discover() {
  if [[ -n "$PROVIDERS" ]]; then printf '%s\n' "$PROVIDERS"; return 0; fi
  local raw
  if ! raw="$(curl -fsS --max-time 20 "$API_BASE/trial-providers")"; then
    echo "trial-providers: request failed" >&2
    return 1
  fi
  # Do not let a changed/HTML/error body dump a python traceback at the user:
  # this runs in a polling loop and the whole point is a clean, readable state.
  printf '%s' "$raw" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit("trial-providers: unparseable response")
if not isinstance(d, list):
    sys.exit("trial-providers: expected a list of provider addresses")
print(",".join(str(x) for x in d))
'
}

# NOTE on the python invocations below: the JSON goes in as a FILE argument, not
# stdin. `python3 - <<'PY'` uses stdin for the script itself, so piping the JSON
# in as well silently discards it (json.load then dies on an empty stream).
render() {
  python3 - "$1" "$2" <<'PY'
import json, sys
path, prov = sys.argv[1], sys.argv[2]
try:
    d = json.load(open(path))
except Exception as exc:
    print(f"  {prov}  unparseable ({exc})")
    raise SystemExit(0)
s   = d.get("stats") or {}
g   = s.get("gpu") or {}
cpu = s.get("cpu") or {}
mem = s.get("memory") or {}
models = ", ".join(
    f"{m.get('model')} {m.get('ram')}" for m in (d.get("gpuModels") or [])
) or "none"
free = int(g.get("available") or 0)
print(f"  {d.get('name') or prov}")
print(f"    gpus advertised : {models}")
print(f"    gpu free/total  : {free}/{g.get('total', 0)}   (active {g.get('active', 0)})")
print(f"    cpu free        : {int(cpu.get('available') or 0) / 1000:.1f} cores")
print(f"    mem free        : {int(mem.get('available') or 0) / 1024**3:.1f} GiB")
print(f"    online/audited  : {d.get('isOnline')}/{d.get('isAudited')}")
print(f"    STATE           : {'AVAILABLE' if free > 0 else 'ALL RENTED'}")
PY
}

# Returns 0 if any trial provider has a free GPU, 1 if none do, 2 on query error.
probe() {
  local provs p free total_free=0 errors=0
  provs="$(discover)" || { echo "trial-providers unreachable -- cannot determine state" >&2; return 2; }
  if [[ -z "$provs" ]]; then
    echo "NO trial providers registered -- a trial deploy cannot succeed at all" >&2
    return 2
  fi

  for p in ${provs//,/ }; do
    if ! curl -fsS --max-time 25 "$API_BASE/providers/$p" -o "$TMP"; then
      echo "  $p  query failed" >&2
      errors=$((errors + 1))
      continue
    fi
    if [[ $RAW -eq 1 ]]; then
      cat "$TMP"; echo; continue
    fi
    render "$TMP" "$p"
    # Read the count with an explicit two-step lookup. The one-liner
    # `(d.get("stats") or {}).get("gpu") or {}.get("available",0)` is a trap:
    # `a or b.get(...)` parses as `a or (b.get(...))`, so it returned the gpu
    # DICT instead of the number and int() blew up -- silently swallowed by the
    # `|| echo 0`, which made an available GPU report as rented.
    free="$(python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
gpu = (d.get("stats") or {}).get("gpu") or {}
print(int(gpu.get("available") or 0))
' "$TMP" 2>/dev/null)"
    [[ "$free" =~ ^[0-9]+$ ]] || {
      echo "  $p  could not read gpu availability (got '$free')" >&2
      errors=$((errors + 1))
      continue
    }
    total_free=$((total_free + free))
  done

  [[ $total_free -gt 0 ]] && return 0
  [[ $errors -gt 0 ]] && return 2
  return 1
}

if [[ $LOOP -eq 0 ]]; then
  echo "=== $(date -u +%FT%TZ) ==="
  probe; rc=$?
  echo
  case $rc in
    0) echo ">> GPU AVAILABLE -- a trial deploy should get a bid now" ;;
    1) echo ">> all trial GPUs are rented; nothing to do but wait" ;;
    2) echo ">> could not determine state -- see errors above" ;;
  esac
  exit $rc
fi

prev=""
while true; do
  echo "=== $(date -u +%FT%TZ) (every ${INTERVAL}s, ctrl-c to stop) ==="
  probe; rc=$?
  echo
  case $rc in
    0)
      echo ">> GPU AVAILABLE -- deploy now, it will not stay free"
      # Only alert on the transition into free. Beeping every interval while a
      # card sits free would be noise, and you would start ignoring it.
      if [[ "$prev" != "free" ]]; then
        printf '\a'
        if [[ $NOTIFY -eq 1 ]] && command -v notify-send >/dev/null; then
          notify-send -u critical "Akash trial GPU is FREE" "Deploy the SDL now"
        fi
      fi
      prev=free
      ;;
    1)
      [[ "$prev" = "free" ]] && echo "   (was free; taken again)"
      echo "   (all rented)"
      prev=busy
      ;;
    *)
      # Do not claim "all rented" here: a failed query is not the same as a
      # rented card, and reporting it as one would have you waiting forever.
      echo "   (query failed -- state unknown, see errors above)"
      prev=error
      ;;
  esac
  sleep "$INTERVAL"
done
