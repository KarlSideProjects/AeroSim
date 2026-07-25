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

mkdir -p .godot
printf '%s\n' 'res://addons/terrain_3d/terrain.gdextension' > .godot/extension_list.cfg

for renderer in forward_plus mobile; do
    echo "loading Industrial Yard with $renderer renderer"
    "$godot_bin" --headless --path . --rendering-method "$renderer" \
        --script res://tests/headless/industrial_yard_renderer_smoke.gd
    echo "loading Terrain Range with $renderer renderer"
    "$godot_bin" --headless --path . --rendering-method "$renderer" \
        --script res://tests/headless/terrain3d_range_smoke.gd
done

echo "running deterministic camera surface smoke"
"$godot_bin" --headless --path . \
    --script res://tests/headless/camera_surface_smoke.gd

echo "shared map renderer checks passed"
