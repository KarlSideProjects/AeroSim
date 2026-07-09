#!/usr/bin/env bash
set -euo pipefail

scan_paths=(
    src/native
    common/flight
)

blocked_patterns=(
    'throttle[[:space:]]*\*[[:space:]]*2\.0'
    '0\.72'
    '0\.225'
    '0\.215'
    '16\.2'
    '18\.0'
    'hover_throttle.*0\.5'
    'config\.hover_throttle.*:'
)

for pattern in "${blocked_patterns[@]}"; do
    if rg -n --glob '!hardware_config.gd' --glob '!*.import' "$pattern" "${scan_paths[@]}"; then
        echo "Hardcoded airframe constant detected: $pattern" >&2
        exit 1
    fi
done

if rg -n -U --glob '!hardware_config.gd' --glob '!*.import' \
    'config\.max_total_thrust_newtons[^\n]*\?\n[^\n]*config\.max_total_thrust_newtons[^\n]*:\n[^\n]*config\.mass_kg[^\n]*config\.gravity_mps2[^\n]*/[^\n]*config\.hover_throttle' \
    src/native; then
    echo "Hardcoded airframe constant detected: max thrust fallback from mass/gravity/hover_throttle" >&2
    exit 1
fi
