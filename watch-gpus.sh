#!/usr/bin/env bash
# watch-gpus.sh — live availability for the cards you're actually shopping for.
#
# Why this exists: the Console GPU dropdown shows aggregate availability, which
# is NOT what decides whether you get a bid. Three separate numbers matter:
#   availability.available          total free cards, all providers
#   providerAvailability.available  how many PROVIDERS have one free
#   (per-node headroom             not exposed here — CPU/RAM can still block bids)
# A card showing "2 available / 1 provider" can vanish between you reading this
# and your deployment reaching the chain. Poll, don't assume.
#
# Usage:
#   ./watch-gpus.sh                    # one snapshot, default watchlist
#   ./watch-gpus.sh -w                 # poll every 60s, alert on change
#   ./watch-gpus.sh -m rtx3060,a10g    # custom watchlist
#   ./watch-gpus.sh -j                 # raw JSON
#   AKASH_FIXTURE=snap.json ./watch-gpus.sh    # replay saved JSON offline

set -euo pipefail
API="${AKASH_API:-https://console-api.akash.network/v1/gpu-prices}"
FIXTURE="${AKASH_FIXTURE:-}"
WATCH="rtx3060,t4,rtx5000,a10g,rtx4000ada,rtx3090,rtx4090,p40,v100"
INTERVAL=60
LOOP=0
RAW=0

while getopts "wm:ji:h" opt; do
  case $opt in
    w) LOOP=1 ;;
    m) WATCH="$OPTARG" ;;
    j) RAW=1 ;;
    i) INTERVAL="$OPTARG" ;;
    h) sed -n '2,20p' "$0"; exit 0 ;;
    *) exit 1 ;;
  esac
done

command -v jq >/dev/null || { echo "need jq" >&2; exit 1; }

# Normalize the watchlist once, as a JSON array, so jq does the set matching.
WANT_JSON="$(printf '%s\n' ${WATCH//,/ } | jq -R . | jq -sc .)"

snapshot() {
  local json
  if [[ -n "$FIXTURE" ]]; then
    json="$(cat "$FIXTURE")"
  else
    json="$(curl -fsS --max-time 20 "$API")" || { echo "API unreachable" >&2; return 1; }
  fi

  if [[ $RAW -eq 1 ]]; then printf '%s\n' "$json"; return 0; fi

  jq -r --argjson want "$WANT_JSON" '
    .models
    | map(select(.model as $m | $want | index($m)))
    | map({
        model,
        vram: .ram,
        free: .availability.available,
        total: .availability.total,
        provs: .providerAvailability.available,
        usd_min: (if .price == null then null else .price.min end),
        usd_max: (if .price == null then null else .price.max end)
      })
    | sort_by(-.free, .usd_min // 99)
    | (["MODEL","VRAM","FREE","TOTAL","PROV","$/hr_min","$/hr_max"] | @tsv),
      (.[] | [.model, .vram, .free, .total, .provs,
              (.usd_min // "-"), (.usd_max // "-")] | @tsv)
  ' <<<"$json" | column -t

  # What $1 actually buys, at the cheapest card that is in stock right now.
  jq -r --argjson want "$WANT_JSON" '
    .models
    | map(select(.model as $m | $want | index($m))
          | select(.availability.available > 0)
          | select(.price != null))
    | sort_by(.price.min)
    | if length == 0 then "  >> nothing in stock right now"
      else "  >> cheapest in stock: \(.[0].model) @ $\(.[0].price.min)/hr"
           + " -> \((1 / .[0].price.min) | floor) GPU-hours per dollar"
      end
  ' <<<"$json"
}

if [[ $LOOP -eq 1 ]]; then
  prev=""
  while true; do
    clear
    echo "=== $(date -u +%FT%TZ) — every ${INTERVAL}s (ctrl-c to stop) ==="
    if cur="$(snapshot)"; then
      echo "$cur"
      if [[ -n "$prev" && "$cur" != "$prev" ]]; then
        printf '\a'
        command -v notify-send >/dev/null && \
          notify-send "Akash GPU availability changed" "$(echo "$cur" | head -4)" || true
        echo "  ** availability changed **"
      fi
      prev="$cur"
    fi
    sleep "$INTERVAL"
  done
else
  snapshot
fi
