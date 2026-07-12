#!/usr/bin/env bash
set -euo pipefail

root_dir="$(git rev-parse --show-toplevel)"
godot_bin="${GODOT_BIN:-/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64}"
tool_root="${AEROSIM_TOOL_ROOT:-$root_dir/.deps/launch-tools}"

if [ ! -x "$godot_bin" ]; then
    printf 'Godot 4.7 executable is required: %s\n' "$godot_bin" >&2
    exit 1
fi

cd "$root_dir"

# Keep build tools inside this worktree so parallel checkouts do not share state.
RUNNER_TEMP="${RUNNER_TEMP:-$root_dir/.deps}" \
AEROSIM_TOOL_ROOT="$tool_root" \
GODOT_BIN="$godot_bin" \
scripts/verify_issue_11.sh

mkdir -p .godot
printf '%s\n' 'res://extensions/aerosim_native/aerosim_native.gdextension' > .godot/extension_list.cfg

exec "$godot_bin" --path .
