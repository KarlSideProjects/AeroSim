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
mkdir -p .godot
printf '%s\n' 'res://extensions/aerosim_native/aerosim_native.gdextension' > .godot/extension_list.cfg
"$godot_bin" --headless --path . --script res://common/smoke/headless_smoke.gd -- --output "$output_path" --csv-output "$csv_output_path" "${args[@]}"
