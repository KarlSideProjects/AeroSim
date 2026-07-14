#!/usr/bin/env bash
set -euo pipefail

godot_bin="${GODOT_BIN:-godot}"
if [[ "$godot_bin" == */* ]]; then
    if [[ ! -x "$godot_bin" ]]; then
        echo "Godot executable is missing or not executable: $godot_bin" >&2
        exit 1
    fi
elif ! command -v "$godot_bin" >/dev/null; then
    echo "Godot executable was not found on PATH: $godot_bin" >&2
    exit 1
fi

for renderer in forward_plus mobile; do
    echo "loading Industrial Yard with $renderer renderer"
    "$godot_bin" --headless --path . --rendering-method "$renderer" \
        --script res://tests/headless/industrial_yard_renderer_smoke.gd
done

echo "Industrial Yard renderer checks passed"
