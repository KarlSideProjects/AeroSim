#!/usr/bin/env bash
set -euo pipefail

godot_bin="${GODOT_BIN:-godot}"
mkdir -p .godot
printf '%s\n' 'res://addons/terrain_3d/terrain.gdextension' > .godot/extension_list.cfg
"$godot_bin" --headless --path . --editor --quit
"$godot_bin" --headless --path . --script res://tests/headless/terrain3d_dependency_smoke.gd
"$godot_bin" --headless --path . --script res://tests/headless/terrain3d_range_smoke.gd
