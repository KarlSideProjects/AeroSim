#!/usr/bin/env bash
set -euo pipefail

godot_bin="${GODOT_BIN:-godot}"
godot_cpp_dir="${GODOT_CPP_DIR:-.deps/godot-cpp}"
output_path="build/reset_respawn.json"
required_adapter="${AEROSIM_REQUIRED_GPU_ADAPTER:-NVIDIA}"

while [ "$#" -gt 0 ]; do
    case "$1" in
        --output) output_path="$2"; shift 2 ;;
        --require-adapter) required_adapter="$2"; shift 2 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

if [ -z "${DISPLAY:-}" ] && [ -z "${WAYLAND_DISPLAY:-}" ]; then
    echo "headed benchmark requires a real DISPLAY or WAYLAND_DISPLAY" >&2
    exit 2
fi
if ! command -v "$godot_bin" >/dev/null 2>&1 || [ ! -d "$godot_cpp_dir/.git" ] || [ ! -f "$godot_cpp_dir/SConstruct" ]; then
    echo "Godot 4.7 and godot-cpp are required" >&2
    exit 2
fi
source "$(dirname "${BASH_SOURCE[0]}")/validate_native_provenance.sh"
validate_native_provenance
commit_sha="$AEROSIM_NATIVE_PROVENANCE_COMMIT_SHA"
gdextension_sha256="$AEROSIM_NATIVE_PROVENANCE_GDEXTENSION_SHA256"
native_source_sha256="$AEROSIM_NATIVE_PROVENANCE_NATIVE_SOURCE_SHA256"
godot_version="$($godot_bin --version | head -n 1)"
godot_sha256="$(sha256sum "$godot_bin" | cut -d ' ' -f 1)"
godot_cpp_revision="ba0edfed90512ec64aba51d4295a3e7e30112f86"

mkdir -p "$(dirname "$output_path")" .godot
raw_path="${output_path%.json}.raw.json"
rm -f "$raw_path" "$output_path"
printf '%s\n' 'res://extensions/aerosim_native/aerosim_native.gdextension' > .godot/extension_list.cfg

timeout 180s "$godot_bin" --path . --resolution 1280x720 \
    --script res://tests/performance/reset_respawn_benchmark.gd -- \
    --output "$raw_path" \
    --commit-sha "$commit_sha" \
    --godot-version "$godot_version" \
    --godot-sha256 "$godot_sha256" \
    --godot-cpp-revision "$godot_cpp_revision" \
    --gdextension-sha256 "$gdextension_sha256" \
    --native-source-sha256 "$native_source_sha256" \
    --require-adapter "$required_adapter"

python3 - "$raw_path" "$output_path" <<'PY'
import json
import math
import sys
from pathlib import Path

raw_path, output_path = map(Path, sys.argv[1:])
report = json.loads(raw_path.read_text(encoding="utf-8"))
paths = report["samples_ms"]
assert report["gate"] == "G4B.2/G4B.UI3"
assert len(paths["plain_x_reset"]) == 200
assert len(paths["pause_overlay_reset"]) == 200
assert all(math.isfinite(value) and value >= 0.0 for samples in paths.values() for value in samples)
assert all(report["p99_ms"][name] <= 1500.0 for name in paths)
assert report["endpoint_contract"] == {
    "armed_preserved": True,
    "pause_off": True,
    "nonzero_throttle_accepted_by_native_telemetry": True,
    "max_wait_physics_frames": 600,
}
output_path.write_text(json.dumps(report, separators=(",", ":")) + "\n", encoding="utf-8")
PY
rm -f "$raw_path"
