#!/usr/bin/env bash
set -euo pipefail

godot_cpp_commit="ba0edfed90512ec64aba51d4295a3e7e30112f86"
: "${RUNNER_TEMP:?RUNNER_TEMP must be set for job-local Godot and build tool paths}"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tool_root="${AEROSIM_TOOL_ROOT:-$RUNNER_TEMP/aerosim-tools-${GITHUB_RUN_ID:-local-$$}-${GITHUB_RUN_ATTEMPT:-1}-${GITHUB_JOB:-verify-issue-11}}"
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-$tool_root/xdg-cache}"
export XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$tool_root/xdg-config}"
export XDG_DATA_HOME="${XDG_DATA_HOME:-$tool_root/xdg-data}"
godot_cpp_dir="${GODOT_CPP_DIR:-$repo_root/third_party/godot-cpp}"

scripts/test_native.sh
scripts/test_license_scan.sh

if ! command -v scons >/dev/null 2>&1; then
    python3 -m venv "$tool_root/scons-venv"
    "$tool_root/scons-venv/bin/python" -m pip install -q --upgrade pip scons
    scons_cmd="$tool_root/scons-venv/bin/scons"
else
    scons_cmd="scons"
fi

if [ -f "$godot_cpp_dir/AEROSIM_PINNED_COMMIT" ]; then
    bundled_commit="$(tr -d '[:space:]' < "$godot_cpp_dir/AEROSIM_PINNED_COMMIT")"
    if [ "$bundled_commit" != "$godot_cpp_commit" ]; then
        echo "bundled godot-cpp commit mismatch: expected $godot_cpp_commit, got $bundled_commit" >&2
        exit 1
    fi
elif [ -d "$godot_cpp_dir/.git" ]; then
    git -C "$godot_cpp_dir" fetch --depth 1 origin "$godot_cpp_commit"
    git -C "$godot_cpp_dir" checkout "$godot_cpp_commit"
else
    git clone https://github.com/godotengine/godot-cpp.git "$godot_cpp_dir"
    git -C "$godot_cpp_dir" fetch --depth 1 origin "$godot_cpp_commit"
    git -C "$godot_cpp_dir" checkout "$godot_cpp_commit"
fi

GODOT_CPP_DIR="$godot_cpp_dir" "$scons_cmd" target=template_debug platform=linux
native_provenance="${AEROSIM_NATIVE_PROVENANCE:-build/native_debug_artifact.json}"
extension="bin/libaerosim_native.linux.template_debug.x86_64.so"
test -s "$extension"
native_source_sha256="$({ find src/native -type f -print0; printf 'SConstruct\0'; } | sort -z | xargs -0 sha256sum | sha256sum | cut -d ' ' -f 1)"
python3 - "$native_provenance" "$extension" "$(git rev-parse HEAD)" "$native_source_sha256" <<'PY'
import hashlib
import json
import sys
from pathlib import Path

artifact = Path(sys.argv[1])
extension = Path(sys.argv[2])
artifact.parent.mkdir(parents=True, exist_ok=True)
artifact.write_text(json.dumps({
    "commit_sha": sys.argv[3],
    "gdextension_path": str(extension),
    "gdextension_sha256": hashlib.sha256(extension.read_bytes()).hexdigest(),
    "native_source_sha256": sys.argv[4],
}, separators=(",", ":")) + "\n", encoding="utf-8")
PY
export AEROSIM_NATIVE_PROVENANCE="$native_provenance"
scripts/test_terrain3d_dependency.sh
scripts/run_gut_tests.sh
scripts/test_native_atomic_boundary.sh
"${GODOT_BIN:-godot}" --headless --path . --script res://tests/headless/gsp_tuning_integration.gd
"${GODOT_BIN:-godot}" --headless --path . --script res://tests/headless/gsp_tuning_stress.gd
scripts/run_headed_acceptance.sh --xvfb
scripts/test_replay_integration.sh
scripts/run_headless_smoke.sh --output build/headless_smoke.json --frames 5
python3 - <<'PY'
import json

with open("build/headless_smoke.json", encoding="utf-8") as handle:
    data = json.load(handle)

assert data["native_probe"] == 47
assert data["simulated_frames"] == 5
print(data)
PY
