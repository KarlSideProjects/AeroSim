#!/usr/bin/env bash
set -euo pipefail

godot_bin="${GODOT_BIN:-godot}"
log_file="$(mktemp build/external-motor-rejection.XXXXXX.log)"
trap 'rm -f "$log_file"' EXIT

mkdir -p .godot build
printf '%s\n' 'res://extensions/aerosim_native/aerosim_native.gdextension' > .godot/extension_list.cfg

set +e
"$godot_bin" --headless --path . --script res://tests/headless/external_motor_rejection.gd >"$log_file" 2>&1
status=$?
set -e

if [ "$status" -ne 0 ]; then
    cat "$log_file" >&2
    exit "$status"
fi
rg -F 'step_external_motor_outputs requires exactly four normalized outputs' "$log_file" >/dev/null
