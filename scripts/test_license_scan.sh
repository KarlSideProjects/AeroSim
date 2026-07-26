#!/usr/bin/env bash
set -euo pipefail

notice_file="build/THIRD_PARTY_NOTICES.txt"
python3 scripts/check_licenses.py --notice-out "$notice_file"
test -s "$notice_file"
grep -q "Godot Engine" "$notice_file"
grep -q "godot-cpp" "$notice_file"
grep -q "GUT" "$notice_file"
grep -q "aeb5d4f3f7f0a6c9b5e178876d6c99b791fda605" "$notice_file"
grep -q 'Copyright (c) 2018 Tom "Butch" Wesley' "$notice_file"
grep -q "gym-pybullet-drones" "$notice_file"
grep -q "Terrain3D" "$notice_file"
grep -q "v1.0.2-stable" "$notice_file"
grep -q "9bc12bc583fa3b28807b2f90a8cadf09fb06e1ff" "$notice_file"
grep -q "Copyright (c) 2020 Jacopo Panerati" "$notice_file"
grep -q "Permission is hereby granted" "$notice_file"
grep -q "Applies only to AeroSim source-code/formula ports" "$notice_file"
grep -q "License: MIT" "$notice_file"

python3 tests/test_gym_pybullet_drones_notice.py
python3 tests/test_terrain3d_dependency.py

out_file="$(mktemp)"
err_file="$(mktemp)"
trap 'rm -f "$out_file" "$err_file"' EXIT

if python3 scripts/check_licenses.py \
    --allow-missing-gym-pybullet-drones-attribution \
    --allow-missing-terrain3d-attribution \
    --allow-missing-ambientcg-attribution \
    --manifest tests/fixtures/gpl_dependency.json >"$out_file" 2>"$err_file"; then
    cat "$out_file"
    echo "GPL fixture unexpectedly passed" >&2
    exit 1
fi

grep -q "license denied: bad-flight-controller 0.0.0 (GPL-3.0)" "$err_file"
echo "GPL fixture failed as expected"
