#!/bin/bash
# ============================================================================
# deploy-test.sh -- push the SDL with env vars pulled from secrets.env
#
# Why not put credentials in the SDL file: `sd send-manifest` and the deploy
# output echo the SDL back, and anything in the file ends up in your shell
# scrollback and possibly in `provider-services lease-status`. Keeping them in
# secrets.env and injecting at deploy time keeps them out of both the committed
# YAML and the transcript.
#
# Use the throwaway trial credentials from secrets.env. This is a short lease on
# a shared GPU; treat the box as disposable and expect it to be reachable.
#
# USAGE
#   ./deploy-test.sh preflight     # checks only, no spend
#   ./deploy-test.sh create        # create deployment + print dseq
#   ./deploy-test.sh bids <dseq>   # list bids
#   ./deploy-test.sh accept <dseq> <provider>
#   ./deploy-test.sh status <dseq> # lease + endpoints + URLs
#   ./deploy-test.sh render       # just render the SDL, print where it is
#   ./deploy-test.sh list         # every active deployment (what is billing)
#   ./deploy-test.sh close <dseq> # stop billing, then VERIFY it stopped
#   ./deploy-test.sh panic        # close EVERY active deployment
# ============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SDL="${SDL:-$HERE/sdl/forge-3060-tunnel.yaml}"
SECRETS="${SECRETS:-$HERE/secrets.env}"
KEY="${AKASH_KEY_NAME:-trial}"
NODE="${AKASH_NODE:-https://rpc.akashnet.net:443}"
CHAIN="${AKASH_CHAIN_ID:-akashnet-2}"
DEPLOY="${DEPLOY:-2500000uakt}"     # 2.5 AKT escrow, refunded on close

die() { echo "[FATAL] $*" >&2; exit 1; }
say() { echo "==> $*"; }
warn() { echo "[WARN] $*" >&2; }

# --- secrets ---------------------------------------------------------------
[ -f "$SECRETS" ] || die "no $SECRETS (copy secrets.env.example)"
# shellcheck disable=SC1090
set -a; . "$SECRETS"; set +a

for v in NEO_USER NEO_PASS FB_USER FB_PASS PROXY_USER PROXY_PASS; do
    [ -n "${!v:-}" ] || die "$v is empty in $SECRETS"
done

# Same guard as the entrypoint. Failing here costs nothing; failing on the box
# costs a lease and a debugging session.
case "$NEO_USER:$NEO_PASS" in
    *:*:*|*,*) die "NEO credentials contain ':' or ',' -- Neo will crash at startup." ;;
esac

# --- SDL rendering --------------------------------------------------------
# Akash does NOT expand env vars in the SDL: Service.Env is a literal []string
# (manifest/v2beta2/service.pb.go). So the credentials have to be substituted
# into a rendered copy before the tx is built -- editing secrets.env alone would
# leave CHANGEME_at_deploy baked into the manifest.
RENDERED="$HERE/.sdl.rendered.yaml"

render_sdl() {
    [ -f "$SDL" ] || die "no SDL at $SDL"
    SDL="$SDL" python3 - "$RENDERED" <<'PY'
import os, re, sys
src = os.environ["SDL"]
out = sys.argv[1]
keys = ["NEO_USER","NEO_PASS","FB_USER","FB_PASS","PROXY_USER","PROXY_PASS"]
vals = {k: os.environ[k] for k in keys}
text = open(src).read()
# Only rewrite the specific env lines; a blind global replace would corrupt the
# YAML if a password happened to look like a key name.
for k, v in vals.items():
    text = re.sub(rf"^(\s*-\s*{k}=).*$", lambda m: m.group(1) + v, text, flags=re.M)
if "CHANGEME" in text:
    sys.exit("placeholders remain after render -- check SDL env key names")
open(out, "w").write(text)
os.chmod(out, 0o600)
print(f"[OK] rendered {out}")
PY
    [ -f "$RENDERED" ] || die "SDL render failed"
}

# --- preflight -------------------------------------------------------------
preflight() {
    say "checking CLI"
    command -v provider-services >/dev/null \
        || die "provider-services not on PATH (install akash provider-services)"

    say "checking wallet key '$KEY'"
    provider-services keys show "$KEY" -a >/dev/null 2>&1 \
        || die "key '$KEY' not found. Create: provider-services keys add $KEY"

    local addr bal
    addr=$(provider-services keys show "$KEY" -a)
    # Must select the uakt denom explicitly. A plain `head -1` over the balances
    # array can pick up an IBC denom instead and compare its amount against the
    # uakt threshold, which either passes wrongly or blocks a funded wallet.
    bal=$(provider-services query bank balances "$addr" \
            --node "$NODE" --chain-id "$CHAIN" -o json 2>/dev/null \
            | python3 -c '
import json,sys
try:
    d=json.load(sys.stdin)
except Exception:
    print(0); raise SystemExit
for b in d.get("balances",[]):
    if b.get("denom")=="uakt":
        print(int(b.get("amount",0))); break
else:
    print(0)
')
    say "address: $addr"
    say "balance: ${bal:-0}uakt"
    # A lease needs escrow up front; an empty wallet fails at create, not accept.
    [ "${bal:-0}" -gt 5000000 ] || die "balance too low (need >5 AKT for escrow+fees)"

    say "checking SDL parses"
    provider-services tx deployment create "$SDL" --help >/dev/null 2>&1 || true
    # Offline structural check: the CLI validates on send, but catching a bad
    # image reference here is cheaper than a rejected tx.
    grep -qE '^\s*image:\s*\S+:\S+' "$SDL" \
        || die "SDL image is untagged; Akash rejects untagged/:latest"
    grep -q 'global: true' "$SDL" \
        || die "SDL has no global endpoint; Akash rejects with 'zero global services'"
    say "SDL looks structurally valid"

    say "rendering credentials into a private SDL copy"
    render_sdl
    say "rendered: $RENDERED (mode 600; expires with the lease)"

    say "credentials present (values not shown):"
    echo "    NEO_USER=$NEO_USER  (len ${#NEO_PASS})"
    echo "    FB_USER=$FB_USER    (len ${#FB_PASS})"
    echo "    PROXY_USER=$PROXY_USER (len ${#PROXY_PASS})"
}

# --- actions ---------------------------------------------------------------
create() {
    render_sdl
    say "creating deployment (escrow $DEPLOY)"
    # --gas auto + --gas-adjustment: a hardcoded gas limit fails on busy blocks.
    out=$(provider-services tx deployment create "$RENDERED" \
        --from "$KEY" \
        --node "$NODE" --chain-id "$CHAIN" \
        --gas auto --gas-adjustment 1.4 --gas-prices 0.025uakt \
        --deposit "$DEPLOY" \
        -y -o json 2>&1) || { echo "$out" >&2; die "create failed"; }
    dseq=$(echo "$out" | grep -o '"dseq":"[0-9]*"' | head -1 | grep -o '[0-9]*')
    [ -n "$dseq" ] || { echo "$out" >&2; die "could not parse dseq"; }
    say "dseq=$dseq"
    echo "$dseq" > "$HERE/.last_dseq"
    say "next: $0 bids $dseq"
}

bids() {
    local dseq="${1:?usage: bids <dseq>}"
    say "querying bids for dseq=$dseq (up to 60s)"
    for i in $(seq 1 12); do
        provider-services query market bid list \
            --owner "$(provider-services keys show "$KEY" -a)" \
            --dseq "$dseq" --state open \
            --node "$NODE" -o json 2>/dev/null > "$HERE/.bids.json"
        n=$(grep -o '"bid_id"' "$HERE/.bids.json" 2>/dev/null | wc -l)
        [ "$n" -gt 0 ] && { say "$n bid(s)"; break; }
        echo "    ...none yet ($((i*5))s)"
        sleep 5
    done
    [ "${n:-0}" -gt 0 ] || die "no bids. Try a cheaper price or different GPU model."
    python3 - "$HERE/.bids.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
for b in d.get("bids",[]):
    bid=b.get("bid",b)
    price=bid.get("price",{}).get("amount","?")
    prov=bid.get("bid_id",{}).get("provider","?")
    print(f"  {prov}  {price} uakt/block")
PY
}

accept() {
    local dseq="${1:?dseq}" prov="${2:?provider}"
    say "accepting bid from $prov"
    provider-services tx market lease create \
        --dseq "$dseq" --provider "$prov" \
        --from "$KEY" --node "$NODE" --chain-id "$CHAIN" \
        --gas auto --gas-adjustment 1.4 --gas-prices 0.025uakt -y \
        || die "lease create failed"
    say "sending manifest"
    provider-services send-manifest "$RENDERED" \
        --dseq "$dseq" --provider "$prov" \
        --from "$KEY" --node "$NODE" --chain-id "$CHAIN" -y \
        || die "send-manifest failed (provider may still be pulling the image)"
    echo "$prov" > "$HERE/.last_provider"
    say "next: $0 status $dseq"
}

status() {
    local dseq="${1:?dseq}" prov="${2:-$(cat "$HERE/.last_provider" 2>/dev/null)}"
    [ -n "$prov" ] || die "no provider; pass it as arg 2"
    provider-services lease-status \
        --dseq "$dseq" --provider "$prov" \
        --from "$KEY" --node "$NODE" -o json \
        | python3 -c '
import json,sys
d=json.load(sys.stdin)
print("services:")
for name,svc in (d.get("services") or {}).items():
    print(f"  {name}: {svc.get(\"state\",\"?\")}")
    for u in svc.get("uris",[]) or []:
        print(f"    https://{u}")
'
    echo
    echo "  Neo/FileBrowser arrive via cloudflared; read the container log:"
    echo "    provider-services lease-logs --dseq $dseq --provider $prov \\"
    echo "      --from $KEY --service ui --tail 100"
    echo "  Look for 'READY' and the two trycloudflare URLs."
}

close() {
    local dseq="${1:?dseq}"
    say "closing dseq=$dseq (stops billing, refunds unspent escrow)"
    provider-services tx deployment close --dseq "$dseq" \
        --from "$KEY" --node "$NODE" --chain-id "$CHAIN" \
        --gas auto --gas-adjustment 1.4 --gas-prices 0.025uakt -y \
        || die "close TRANSACTION failed for dseq=$dseq -- STILL BILLING, retry"

    # A broadcast tx is not a closed deployment. The tx can be included and
    # still leave the deployment open (wrong dseq, gas too low so it never
    # lands, node lagging). This is the money path, so confirm on-chain that
    # the state actually changed instead of trusting the exit code.
    say "verifying dseq=$dseq is closed on-chain"
    local addr state
    addr=$(provider-services keys show "$KEY" -a)
    for i in $(seq 1 10); do
        state=$(provider-services query deployment get \
                    --owner "$addr" --dseq "$dseq" \
                    --node "$NODE" --chain-id "$CHAIN" -o json 2>/dev/null \
                | python3 -c '
import json,sys
try:
    d=json.load(sys.stdin)
except Exception:
    print("unknown"); raise SystemExit
print((d.get("deployment") or d).get("state", "unknown"))
' 2>/dev/null)
        [ "$state" = "closed" ] && { say "dseq=$dseq confirmed CLOSED -- billing stopped"; return 0; }
        sleep 2
    done
    warn "dseq=$dseq still reports state='$state' after ~20s."
    warn "Billing may still be running. Re-run: ./deploy-test.sh close $dseq"
    warn "Check manually:  provider-services query deployment get --owner $addr --dseq $dseq"
    return 1
}

# Every deployment of this key that is still open/active. This exists because
# the single most likely emergency is not knowing the dseq: a create that
# printed a number you lost, or a second shell, or a lease someone else opened
# on the same key. `panic` needs to find work without being told where to look.
list() {
    local addr
    addr=$(provider-services keys show "$KEY" -a)
    say "active deployments for $addr"
    provider-services query deployment list \
        --owner "$addr" --node "$NODE" --chain-id "$CHAIN" \
        -o json 2>/dev/null \
        | python3 -c '
import json,sys
try:
    d=json.load(sys.stdin)
except Exception:
    print("  (could not parse query output)"); raise SystemExit(1)
rows=d.get("deployments") or []
live=[]
for r in rows:
    dep=r.get("deployment",r)
    state=dep.get("state","?")
    dseq=(dep.get("deployment_id") or dep.get("id") or {}).get("dseq","?")
    if state in ("active","open"):
        live.append(str(dseq))
    print(f"  dseq={dseq:>10}  state={state}")
if not live:
    print("  (nothing is billing)")
else:
    print()
    print("billing now:", " ".join(live))
' || die "deployment query failed"
}

# The actual kill switch: stop every active deployment for this key.
# Sequential on purpose -- deployments are independent, and firing N signed
# txs at once from one account races the sequence number and they all fail.
panic_close() {
    local addr dseqs dseq rc=0
    addr=$(provider-services keys show "$KEY" -a)
    dseqs=$(provider-services query deployment list \
                --owner "$addr" --node "$NODE" --chain-id "$CHAIN" \
                -o json 2>/dev/null \
            | python3 -c '
import json,sys
try:
    d=json.load(sys.stdin)
except Exception:
    raise SystemExit(1)
for r in d.get("deployments") or []:
    dep=r.get("deployment",r)
    if dep.get("state") in ("active","open"):
        print((dep.get("deployment_id") or dep.get("id") or {}).get("dseq",""))
' 2>/dev/null) || die "could not list deployments; close is NOT confirmed"

    dseqs=$(echo "$dseqs" | grep -v '^$' || true)
    if [ -z "$dseqs" ]; then
        say "no active deployments -- nothing is billing"
        return 0
    fi
    say "closing: $(echo $dseqs | tr '\n' ' ')"
    for dseq in $dseqs; do
        close "$dseq" || rc=1
    done
    return $rc
}

case "${1:-preflight}" in
    preflight)   preflight ;;
    render)      render_sdl ;;
    create)      create ;;
    bids)        bids "${2:-}" ;;
    accept)      accept "${2:-}" "${3:-}" ;;
    status)      status "${2:-}" "${3:-}" ;;
    list)        list ;;
    close)       close "${2:-}" ;;
    panic)       panic_close ;;
    *) die "unknown action: $1" ;;
esac
