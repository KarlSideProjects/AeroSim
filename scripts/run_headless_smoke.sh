#!/usr/bin/env bash
set -euo pipefail

godot_bin="${GODOT_BIN:-godot}"
output_path="build/headless_smoke.json"
csv_output_path="build/headless_trajectory.csv"
log_path="build/headless/godot.log"
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

if [[ "$godot_bin" == */* ]]; then
    if [ ! -x "$godot_bin" ]; then
        echo "Godot executable is missing or not executable: $godot_bin" >&2
        exit 1
    fi
elif ! command -v "$godot_bin" >/dev/null; then
    echo "Godot executable was not found on PATH: $godot_bin" >&2
    exit 1
fi

source "$(dirname "${BASH_SOURCE[0]}")/validate_native_provenance.sh"
validate_native_provenance

rpc_port="${AEROSIM_HEADLESS_RPC_PORT:-}"
if [ -z "$rpc_port" ]; then
    rpc_port="$(python3 - <<'PY'
import socket

with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as socket_handle:
    socket_handle.bind(("127.0.0.1", 0))
    print(socket_handle.getsockname()[1])
PY
    )"
fi

mkdir -p "$(dirname "$output_path")"
mkdir -p "$(dirname "$csv_output_path")"
mkdir -p "$(dirname "$log_path")"
rm -f "$output_path" "$csv_output_path" "$log_path"
rm -rf .godot
mkdir -p .godot build .deps
touch build/.gdignore .deps/.gdignore
printf '%s\n' \
    'res://extensions/aerosim_native/aerosim_native.gdextension' \
    'res://addons/terrain_3d/terrain.gdextension' > .godot/extension_list.cfg
"$godot_bin" --headless --path . --import

printf '%s\n' 'res://extensions/aerosim_native/aerosim_native.gdextension' > .godot/extension_list.cfg

"$godot_bin" --headless --fixed-fps 240 --path . --log-file "$log_path" \
    --script res://common/smoke/headless_smoke.gd -- \
    --output "$output_path" --csv-output "$csv_output_path" --skip-runtime-map \
    --airsim-rpc-port "$rpc_port" "${args[@]}" &
godot_pid="$!"
deadline=$((SECONDS + ${AEROSIM_HEADLESS_TIMEOUT_SECONDS:-1800}))
terminated_after_completion=false
reaped=false
godot_status=0

artifacts_report_completion() {
    [ -s "$output_path" ] && [ -s "$csv_output_path" ] && python3 - "$output_path" <<'PY'
import json
import sys

try:
    with open(sys.argv[1], encoding="utf-8") as report_file:
        report = json.load(report_file)
except (OSError, json.JSONDecodeError):
    raise SystemExit(1)

raise SystemExit(0 if report.get("completed") is True else 1)
PY
}

while kill -0 "$godot_pid" 2>/dev/null; do
    if artifacts_report_completion; then
        # ponytail: Godot 4.7 can keep the headless process alive after the smoke artifacts are complete.
        sleep 2
        if kill -0 "$godot_pid" 2>/dev/null; then
            if kill "$godot_pid" 2>/dev/null; then
                terminated_after_completion=true
            fi
        fi
        if wait "$godot_pid"; then
            godot_status=0
        else
            godot_status=$?
        fi
        reaped=true
        break
    fi
    if [ "$SECONDS" -ge "$deadline" ]; then
        kill "$godot_pid" 2>/dev/null || true
        wait "$godot_pid" 2>/dev/null || true
        echo "headless smoke timed out before writing valid artifacts" >&2
        exit 124
    fi
    sleep 1
done

if [ "$reaped" = false ]; then
    if wait "$godot_pid"; then
        godot_status=0
    else
        godot_status=$?
    fi
fi

if [ "$godot_status" -ne 0 ]; then
    if [ "$terminated_after_completion" != true ] || [ "$godot_status" -ne 143 ]; then
        echo "Godot headless smoke failed with status $godot_status" >&2
        exit "$godot_status"
    fi
fi

for required_file in "$log_path" "$output_path" "$csv_output_path"; do
    if [ ! -s "$required_file" ]; then
        echo "required headless smoke artifact is missing or empty: $required_file" >&2
        exit 1
    fi
done

if ! artifacts_report_completion; then
    echo "headless smoke did not report completed=true: $output_path" >&2
    exit 1
fi

printf '%s\n' \
    'res://extensions/aerosim_native/aerosim_native.gdextension' \
    'res://addons/terrain_3d/terrain.gdextension' > .godot/extension_list.cfg
"$godot_bin" --headless --fixed-fps 240 --path . --script res://tests/headless/terrain3d_runtime_smoke.gd -- \
    --airsim-rpc-port "$rpc_port"
