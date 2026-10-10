#!/usr/bin/env bash
# ForgeMiner stats for the HiveOS dashboard.
# Compatible with sourcing from the HiveOS agent.
# Screen hardcopy + block state are stored in /dev/shm (tmpfs, RAM only).
# On rig reboot /dev/shm is wiped => block counter resets to 0, as desired.

SCRIPT_DIR="$(dirname -- "${BASH_SOURCE[0]}")"
. "$SCRIPT_DIR/h-manifest.conf" 2>/dev/null

STATS_FILE="$SCRIPT_DIR/forge_stats.json"
[[ -n "${FORGE_STATS_FILE:-}" ]] && STATS_FILE="$FORGE_STATS_FILE"

# Состояние счётчика блоков в RAM. При перезагрузке рига файл исчезнет,
# счётчик начнётся с нуля — это ожидаемое поведение.
BLOCKS_STATE_FILE="/dev/shm/forge_blocks.state"

khs=0
stats="null"

# Find miner screen session, not the agent session.
SCREEN_SESSION=$(
    screen -ls 2>/dev/null |
        awk '$1 ~ /^[0-9]+\.miner$/ { print $1; exit }'
)

if [[ -f "$STATS_FILE" ]]; then
    now=$(date +%s)
    mtime=$(stat -c %Y "$STATS_FILE" 2>/dev/null) || mtime=0

    if (( now - mtime < 120 )); then
        raw=$(<"$STATS_FILE")

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

            # --- Читаем количество блоков из TUI майнера ---
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

            # --- Обработка счётчика блоков с учётом рестарта майнера ---
            # Состояние: "total_blocks last_tui_blocks" в /dev/shm.
            # total_blocks — общее число блоков за текущий сеанс рига.
            # last_tui_blocks — последнее значение, которое показывал TUI майнера.
            total_blocks=0
            last_tui_blocks=0
            if [[ -f "$BLOCKS_STATE_FILE" ]]; then
                read -r total_blocks last_tui_blocks < "$BLOCKS_STATE_FILE" 2>/dev/null || true
                [[ "$total_blocks" =~ ^[0-9]+$ ]] || total_blocks=0
                [[ "$last_tui_blocks" =~ ^[0-9]+$ ]] || last_tui_blocks=0
            fi

            new_blocks=0
            if (( blocks > last_tui_blocks )); then
                # Новый блок(и) в той же сессии майнера.
                new_blocks=$(( blocks - last_tui_blocks ))
            elif (( blocks < last_tui_blocks )); then
                # Майнер перезапустился, TUI сбросился в 0 (или меньше).
                # Все блоки, показанные в новой сессии, считаются новыми.
                new_blocks=$blocks
            fi

            if (( new_blocks > 0 )); then
                total_blocks=$(( total_blocks + new_blocks ))

                msg_id="forge_block_${total_blocks}_$(date +%s)"
                if (( new_blocks == 1 )); then
                    msg_text="ForgeMiner found a new block! Total blocks: ${total_blocks}"
                else
                    msg_text="ForgeMiner found ${new_blocks} new blocks! Total blocks: ${total_blocks}"
                fi
                echo "$msg_text" | /hive/bin/message info "Block found" payload -i="$msg_id" >/dev/null 2>&1 &
            fi

            # Обновляем состояние (в /dev/shm). При перезагрузке рига файл исчезнет.
            printf "%s %s\n" "$total_blocks" "$blocks" > "$BLOCKS_STATE_FILE"

            # --- Base version from JSON, falling back to custom version ---
            base_ver=$(
                jq -r '.ver // empty' <<< "$raw" 2>/dev/null
            )
            [[ -z "$base_ver" ]] && base_ver="${CUSTOM_VERSION:-}"

            # --- Build dashboard JSON ---
            # В ver показываем total_blocks (накопленное), а не blocks (текущее из TUI),
            # чтобы после рестарта майнера счётчик в веб-морде не падал до 0.
            stats=$(
                jq -c \
                    --argjson bus "[$BUS]" \
                    --arg blocks "$total_blocks" \
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
                             else "" end)
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
