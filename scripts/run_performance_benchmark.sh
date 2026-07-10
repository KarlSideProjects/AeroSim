#!/usr/bin/env bash
set -euo pipefail

godot_bin="${GODOT_BIN:-godot}"
output_path="build/performance_report.json"
warmup_seconds=10
seconds=60
effects=off
required_adapter="${AEROSIM_REQUIRED_GPU_ADAPTER:-NVIDIA}"
baseline_report=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        --output)
            output_path="$2"
            shift 2
            ;;
        --warmup-seconds)
            warmup_seconds="$2"
            shift 2
            ;;
        --seconds)
            seconds="$2"
            shift 2
            ;;
        --effects)
            effects="$2"
            shift 2
            ;;
        --require-adapter)
            required_adapter="$2"
            shift 2
            ;;
        --baseline-report)
            baseline_report="$2"
            shift 2
            ;;
        *)
            echo "unknown argument: $1" >&2
            exit 2
            ;;
    esac
done

if [ -z "${DISPLAY:-}" ] && [ -z "${WAYLAND_DISPLAY:-}" ]; then
    echo "headed benchmark requires a real DISPLAY or WAYLAND_DISPLAY" >&2
    exit 2
fi
if ! command -v "$godot_bin" >/dev/null 2>&1; then
    echo "Godot 4.7 executable is required: $godot_bin" >&2
    exit 2
fi

mkdir -p "$(dirname "$output_path")" .godot
raw_path="${output_path%.json}.raw.json"
rm -f "$raw_path" "$output_path"
printf '%s\n' 'res://extensions/aerosim_native/aerosim_native.gdextension' > .godot/extension_list.cfg

timeout 180s "$godot_bin" --path . --resolution 1280x720 --remote-debug local:// \
    --script res://tests/performance/physics_benchmark.gd -- \
    --output "$raw_path" \
    --warmup-seconds "$warmup_seconds" \
    --seconds "$seconds" \
    --effects "$effects" \
    --require-adapter "$required_adapter"

test -s "$raw_path"
report_args=(--input "$raw_path" --output "$output_path")
if [ -n "$baseline_report" ]; then
    report_args+=(--baseline-report "$baseline_report")
fi
python3 scripts/performance_report.py "${report_args[@]}"
rm -f "$raw_path"
