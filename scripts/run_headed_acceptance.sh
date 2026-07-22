#!/usr/bin/env bash
set -euo pipefail

godot_bin="${GODOT_BIN:-godot}"
out_dir="build/headed"
use_xvfb=0

while [ "$#" -gt 0 ]; do
    case "$1" in
        --xvfb)
            use_xvfb=1
            shift
            ;;
        --out-dir)
            out_dir="$2"
            shift 2
            ;;
        *)
            echo "unknown argument: $1" >&2
            exit 2
            ;;
    esac
done

if [[ "$godot_bin" == */* ]]; then
    if [ ! -x "$godot_bin" ]; then
        echo "Godot executable is missing or not executable: $godot_bin" >&2
        exit 1
    fi
elif ! command -v "$godot_bin" >/dev/null; then
    echo "Godot executable was not found on PATH: $godot_bin" >&2
    exit 1
fi

if [ "$use_xvfb" -eq 1 ]; then
    lavapipe_icd="${VK_ICD_FILENAMES:-/usr/share/vulkan/icd.d/lvp_icd.json}"
    test -r "$lavapipe_icd"
    command -v xvfb-run >/dev/null
    export VK_ICD_FILENAMES="$lavapipe_icd"
    launcher=(xvfb-run -a --server-args="-screen 0 1280x720x24")
else
    launcher=()
fi

mkdir -p "$out_dir"
mkdir -p .godot
printf '%s\n' 'res://extensions/aerosim_native/aerosim_native.gdextension' > .godot/extension_list.cfg
export AEROSIM_HEADED_COMMIT_SHA="$(git rev-parse HEAD)"
log_path="$out_dir/godot.log"
rm -f "$out_dir"/*.png "$out_dir/report.json" "$log_path"
timeout 60s "${launcher[@]}" "$godot_bin" --path . --resolution 1280x720 \
    --log-file "$log_path" \
    --script res://tests/headed/headed_acceptance.gd -- --out-dir "$out_dir"

for required_file in \
    "$log_path" \
    "$out_dir/report.json" \
    "$out_dir/00_cold_start.png" \
    "$out_dir/01_controller_confirmation.png" \
    "$out_dir/02_keyboard_fallback.png" \
    "$out_dir/03_takeoff.png" \
    "$out_dir/04_paused.png" \
    "$out_dir/05_reset.png" \
    "$out_dir/06_exit.png" \
    "$out_dir/07_channel_monitor_paused.png"; do
    if [ ! -s "$required_file" ]; then
        echo "required headed acceptance artifact is missing or empty: $required_file" >&2
        exit 1
    fi
done

python3 - "$out_dir/report.json" "$(git rev-parse HEAD)" <<'PY'
import json
import sys

path = sys.argv[1]
expected_commit_sha = sys.argv[2]
try:
    with open(path, encoding="utf-8") as report_file:
        report = json.load(report_file)
except (OSError, json.JSONDecodeError) as error:
    raise SystemExit(f"invalid headed acceptance report {path}: {error}")

if report.get("passed") is not True:
    raise SystemExit(f"headed acceptance did not report passed=true: {path}")
provenance = report.get("provenance")
if not isinstance(provenance, dict):
    raise SystemExit(f"headed acceptance report is missing provenance: {path}")
if provenance.get("commit_sha") != expected_commit_sha:
    raise SystemExit(f"headed acceptance report commit SHA is not bound to the checkout: {path}")
for field in ("godot_version", "os", "display_driver", "gpu_adapter"):
    if not provenance.get(field):
        raise SystemExit(f"headed acceptance report is missing provenance field {field}: {path}")
PY

if grep -Eq '^(ERROR:|SCRIPT ERROR:)' "$log_path"; then
    echo "Godot error found in headed acceptance log: $log_path" >&2
    exit 1
fi
