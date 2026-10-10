#!/usr/bin/env bash
# ForgeMiner stats for the HiveOS dashboard.
# Compatible with sourcing from the HiveOS agent.
# Screen hardcopy is stored in /dev/shm (tmpfs).

SCRIPT_DIR="$(dirname -- "${BASH_SOURCE[0]}")"
. "$SCRIPT_DIR/h-manifest.conf" 2>/dev/null

STATS_FILE="$SCRIPT_DIR/forge_stats.json"
[[ -n "${FORGE_STATS_FILE:-}" ]] && STATS_FILE="$FORGE_STATS_FILE"

khs=0
stats="null"

# Find miner screen session, not the agent session.
SCREEN_SESSION=$(
    screen -ls 2>/dev/null |
        awk '$1 ~ /^[0-9]+[.]miner$/ { print $1; exit }'
)

if [[ -f "$STATS_FILE" ]]; then
    now=$(date +%s)
    mtime=$(stat -c %Y "$STATS_FILE" 2>/dev/null) || mtime=0

    if (( now - mtime < 120 )); then
        # Read JSON without spawning cat.
        raw=$(<"$STATS_FILE")

        # Extract khs and PCI bus list in one jq invocation.
        meta=$(
            jq -r '[
                (.khs // ""),
                (if (.bus | type) == "array" and (.bus | length) > 0
                 then (.bus | map(tostring) | join(","))
                 else ""
                 end)
            ] | @tsv' <<< "$raw" 2>/dev/null
        )

        IFS=$'\t' read -r k BUS <<< "$meta"

        if [[ -n "$k" ]] && awk -v v="$k" 'BEGIN { exit !(v >= 0) }'; then

            # Query GPU PCI buses only when JSON has none.
            if [[ -z "$BUS" ]]; then
                while IFS= read -r b; do
                    [[ -z "$b" ]] && continue
                    d=$((b))
                    BUS="${BUS:+$BUS,}$d"
                done < <(
                    nvidia-smi --query-gpu=pci.bus \
                        --format=csv,noheader 2>/dev/null
                )
            fi

            [[ -z "$BUS" ]] && BUS=0

            # Read blocks from the miner's screen into RAM.
            blocks=0

            if [[ -n "$SCREEN_SESSION" ]]; then
                DUMP_FILE="/dev/shm/forge_tui_dump.$$"

                if screen -S "$SCREEN_SESSION" \
                    -X hardcopy "$DUMP_FILE" 2>/dev/null; then

                    for _ in 1 2 3 4 5 6 7 8 9 10; do
                        [[ -s "$DUMP_FILE" ]] && break
                        sleep 0.1
                    done

                    if [[ -s "$DUMP_FILE" ]]; then
                        blocks=$(
                            LC_ALL=C awk '
                                /Blocks found[[:space:]]+[0-9]+/ {
                                    line = $0
                                    sub(/^.*Blocks found[[:space:]]+/, "", line)
                                    if (match(line, /^[0-9]+/))
                                        result = substr(line, RSTART, RLENGTH)
                                }
                                END {
                                    if (result != "")
                                        print result
                                }
                            ' "$DUMP_FILE" 2>/dev/null
                        )
                        [[ -z "$blocks" ]] && blocks=0
                    fi
                fi

                rm -f "$DUMP_FILE"
            fi

            # Base version from JSON, falling back to custom version.
            base_ver=$(
                jq -r '.ver // empty' <<< "$raw" 2>/dev/null
            )
            [[ -z "$base_ver" ]] && base_ver="${CUSTOM_VERSION:-}"

            # Build dashboard JSON.
            # Append block count only when blocks > 0.
            stats=$(
                jq -c \
                    --argjson bus "[$BUS]" \
                    --arg blocks "$blocks" \
                    --arg ver "$base_ver" \
                    '
                    {
                        khs: .khs,
                        temp: .temp,
                        fan: .fan,
                        uptime: .uptime,
                        algo: .algo,
                        hs: .hs,
                        ar: [
                            (.ar[0] // 0),
                            (([.rej_g[]?, .stale_g[]?] | add) // 0)
                        ],
                        bus_numbers: $bus,
                        ver: (
                            $ver +
                            (if (($blocks | tonumber?) // 0) > 0
                             then " | Blocks: " + $blocks
                             else ""
                             end)
                        ),
                        hs_units: "khs"
                    }
                    ' <<< "$raw" 2>/dev/null
            )

            if [[ -n "$stats" && "$stats" != "null" ]]; then
                khs="$k"
            else
                stats="null"
            fi
        fi
    fi
fi
