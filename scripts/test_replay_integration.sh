#!/usr/bin/env bash
set -euo pipefail

godot_bin="${GODOT_BIN:-godot}"
project_path="${AEROSIM_PROJECT_PATH:-.}"
if [[ "$godot_bin" == */* ]]; then
    [ -x "$godot_bin" ] || { echo "Godot executable is missing: $godot_bin" >&2; exit 1; }
elif ! command -v "$godot_bin" >/dev/null; then
    echo "Godot executable was not found on PATH: $godot_bin" >&2
    exit 1
fi

if [ "${AEROSIM_EXPORTED:-false}" = true ]; then
    "$godot_bin" --headless --script res://tests/headless/replay_integration.gd
else
    mkdir -p "$project_path/.godot" "$project_path/build" "$project_path/.deps"
    touch "$project_path/build/.gdignore" "$project_path/.deps/.gdignore"
    printf '%s\n' 'res://extensions/aerosim_native/aerosim_native.gdextension' > "$project_path/.godot/extension_list.cfg"
    "$godot_bin" --headless --path "$project_path" --script res://tests/headless/replay_integration.gd
fi
