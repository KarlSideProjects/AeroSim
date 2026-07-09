#!/usr/bin/env bash
set -euo pipefail

godot_cpp_commit="ba0edfed90512ec64aba51d4295a3e7e30112f86"
: "${RUNNER_TEMP:?RUNNER_TEMP must be set for job-local Godot and build tool paths}"
tool_root="${AEROSIM_TOOL_ROOT:-$RUNNER_TEMP/aerosim-tools-${GITHUB_RUN_ID:-local-$$}-${GITHUB_RUN_ATTEMPT:-1}-${GITHUB_JOB:-verify-issue-11}}"
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-$tool_root/xdg-cache}"
export XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$tool_root/xdg-config}"
export XDG_DATA_HOME="${XDG_DATA_HOME:-$tool_root/xdg-data}"
godot_cpp_dir="${GODOT_CPP_DIR:-$tool_root/godot-cpp}"

scripts/test_native.sh
scripts/test_license_scan.sh

if ! command -v scons >/dev/null 2>&1; then
    python3 -m venv "$tool_root/scons-venv"
    "$tool_root/scons-venv/bin/python" -m pip install -q --upgrade pip scons
    scons_cmd="$tool_root/scons-venv/bin/scons"
else
    scons_cmd="scons"
fi

if [ ! -d "$godot_cpp_dir/.git" ]; then
    git clone https://github.com/godotengine/godot-cpp.git "$godot_cpp_dir"
fi
git -C "$godot_cpp_dir" fetch --depth 1 origin "$godot_cpp_commit"
git -C "$godot_cpp_dir" checkout "$godot_cpp_commit"

GODOT_CPP_DIR="$godot_cpp_dir" "$scons_cmd" target=template_debug platform=linux
scripts/run_headless_smoke.sh --output build/headless_smoke.json --frames 5
python3 - <<'PY'
import json

with open("build/headless_smoke.json", encoding="utf-8") as handle:
    data = json.load(handle)

assert data["native_probe"] == 47
assert data["simulated_frames"] == 5
print(data)
PY
