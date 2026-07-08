#!/usr/bin/env bash
set -euo pipefail

godot_bin="${GODOT_BIN:-godot}"
output_path="build/headless_smoke.json"
csv_output_path="build/headless_trajectory.csv"
args=()

while [ "$#" -gt 0 ]; do
    case "$1" in
        --output)
            output_path="$2"
            shift 2
            ;;
        --csv-output)
            csv_output_path="$2"
            shift 2
            ;;
        --frames|--seconds)
            args+=("$1" "$2")
            shift 2
            ;;
        *)
            output_path="$1"
            shift
            ;;
    esac
done

mkdir -p "$(dirname "$output_path")"
mkdir -p "$(dirname "$csv_output_path")"
rm -rf .godot
mkdir -p .godot build .deps
touch build/.gdignore .deps/.gdignore
printf '%s\n' 'res://extensions/aerosim_native/aerosim_native.gdextension' > .godot/extension_list.cfg

"$godot_bin" --headless --path . --script res://common/smoke/headless_smoke.gd -- --output "$output_path" --csv-output "$csv_output_path" "${args[@]}" &
godot_pid="$!"
deadline=$((SECONDS + ${AEROSIM_HEADLESS_TIMEOUT_SECONDS:-1800}))

while kill -0 "$godot_pid" 2>/dev/null; do
    if [ -s "$output_path" ] && [ -s "$csv_output_path" ] && python3 -m json.tool "$output_path" >/dev/null 2>&1; then
        # ponytail: Godot 4.7 can keep the headless process alive after the smoke artifacts are complete.
        sleep 2
        if kill -0 "$godot_pid" 2>/dev/null; then
            kill "$godot_pid" 2>/dev/null || true
            wait "$godot_pid" 2>/dev/null || true
        fi
        exit 0
    fi
    if [ "$SECONDS" -ge "$deadline" ]; then
        kill "$godot_pid" 2>/dev/null || true
        wait "$godot_pid" 2>/dev/null || true
        echo "headless smoke timed out before writing valid artifacts" >&2
        exit 124
    fi
    sleep 1
done

wait "$godot_pid"
