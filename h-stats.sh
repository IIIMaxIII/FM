#!/usr/bin/env bash
# ForgeMiner stats for the HiveOS dashboard.

. `dirname $BASH_SOURCE`/h-manifest.conf 2>/dev/null

STATS_FILE="`dirname $BASH_SOURCE`/forge_stats.json"
[[ -n "${FORGE_STATS_FILE:-}" ]] && STATS_FILE="$FORGE_STATS_FILE"

khs=0
stats="null"

# --- Определяем screen-сессию майнера ---
# Ищем сессию с суффиксом ".miner", игнорируя $STY (который указывает на agent).
SCREEN_SESSION=$(screen -ls 2>/dev/null | grep -oE '[0-9]+\.miner' | head -1)

if [[ -f "$STATS_FILE" ]]; then
  now=`date +%s`
  mtime=`stat -c %Y "$STATS_FILE" 2>/dev/null || echo 0`
  if (( now - mtime < 120 )); then
    raw=`cat "$STATS_FILE" 2>/dev/null`
    k=`jq -r '.khs // empty' <<< "$raw" 2>/dev/null`
    if [[ -n "$k" ]] && awk -v v="$k" 'BEGIN{exit !(v>=0)}'; then
      # PCI bus numbers
      BUS=`jq -r 'if (.bus|type)=="array" and (.bus|length)>0 then (.bus|map(tostring)|join(",")) else empty end' <<< "$raw" 2>/dev/null`
      if [[ -z "$BUS" ]]; then
        for b in `nvidia-smi --query-gpu=pci.bus --format=csv,noheader 2>/dev/null`; do d=$((b)); BUS="${BUS:+$BUS,}$d"; done
      fi
      [[ -z "$BUS" ]] && BUS="0"

      # Сумма rej_g + stale_g
      rej_sum=$(jq -c '[.rej_g[], .stale_g[]] | add // 0' <<< "$raw" 2>/dev/null)
      [[ -z "$rej_sum" || "$rej_sum" == "null" ]] && rej_sum=0

      # --- Парсинг блоков из TUI через screen hardcopy в RAM ---
      blocks=0
      if [[ -n "$SCREEN_SESSION" ]]; then
        DUMP_FILE="/dev/shm/forge_tui_dump.$$"
        if screen -S "$SCREEN_SESSION" -X hardcopy "$DUMP_FILE" 2>/dev/null; then
          for _ in 1 2 3 4 5 6 7 8 9 10; do
            [[ -s "$DUMP_FILE" ]] && break
            sleep 0.1
          done
          if [[ -s "$DUMP_FILE" ]]; then
            blocks=$(grep -a -oE 'Blocks found[[:space:]]+[0-9]+' "$DUMP_FILE" 2>/dev/null \
                     | tail -1 \
                     | grep -oE '[0-9]+$')
            [[ -z "$blocks" || "$blocks" == "null" ]] && blocks=0
          fi
        fi
        rm -f "$DUMP_FILE"
      fi

      # --- Версия с припиской о блоках ---
      base_ver=$(jq -r '.ver // empty' <<< "$raw" 2>/dev/null)
      [[ -z "$base_ver" ]] && base_ver="${CUSTOM_VERSION:-}"

      stats=`jq -c --argjson bus "[$BUS]" --argjson rej "$rej_sum" --arg ver "${base_ver} | Blocks: ${blocks}" \
        '{khs: .khs, temp: .temp, fan: .fan, uptime: .uptime, algo: .algo,
          hs: .hs, ar: [(.ar[0] // 0), $rej], bus_numbers: $bus,
          ver: $ver, hs_units: "khs"}' <<< "$raw" 2>/dev/null`

      if [[ -n "$stats" && "$stats" != "null" ]]; then
        khs="$k"
      else
        stats="null"
      fi
    fi
  fi
fi
