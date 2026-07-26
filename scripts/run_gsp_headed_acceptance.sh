#!/usr/bin/env bash
set -euo pipefail

godot_bin="${GODOT_BIN:-godot}"
out_dir="build/gsp-headed"

while [ "$#" -gt 0 ]; do
    case "$1" in
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

if [ -z "${WAYLAND_DISPLAY:-}" ]; then
    echo "GSP headed acceptance requires a native Wayland session" >&2
    exit 2
fi

mkdir -p "$out_dir"
rm -f "$out_dir/report.json"
rm -f "$out_dir/stage.json" "$out_dir/external-unavailable.json" "$out_dir/external-evidence.json"
python3 scripts/gsp_wayland_driver.py --out-dir "$out_dir" >"$out_dir/driver.log" 2>&1 &
driver_pid=$!
set +e
timeout 45s "$godot_bin" --display-driver wayland --path . \
    --script res://tests/headed/gsp_headed_acceptance.gd -- \
    --out-dir "$out_dir" >"$out_dir/godot.log" 2>&1
godot_status=$?
set -e
if kill -0 "$driver_pid" 2>/dev/null; then
    kill "$driver_pid" 2>/dev/null || true
fi
wait "$driver_pid" 2>/dev/null || true

if [ "$godot_status" -eq 2 ]; then
    python3 - "$out_dir/report.json" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
report = json.loads(path.read_text(encoding="utf-8"))
if report.get("status") != "environment_not_qualified" or report.get("exit_code") != 2:
    raise SystemExit(f"exit 2 without an explicit environment_not_qualified report: {path}")
print(f"GSP headed acceptance: NOT_QUALIFIED ({path})")
PY
    exit 2
fi
if [ "$godot_status" -ne 0 ]; then
    cat "$out_dir/godot.log" >&2
    exit "$godot_status"
fi

python3 - "$out_dir/report.json" <<'PY'
import json
import sys
from pathlib import Path

report_path = Path(sys.argv[1])
report = json.loads(report_path.read_text(encoding="utf-8"))
if report.get("status") != "qualified" or report.get("passed") is not True:
    raise SystemExit(f"GSP headed acceptance did not pass: {report_path}")
if report.get("display_driver") != "Wayland":
    raise SystemExit("GSP headed acceptance requires native Wayland, not XWayland")
if report.get("window_mode") != 0 or report.get("borderless") is not True:
    raise SystemExit("GSP headed acceptance did not retain borderless windowed mode")
if report.get("focus_steps") != ["capture", "release", "panel_focus", "game_focus", "recapture"]:
    raise SystemExit("GSP headed focus sequence is incomplete")
if not report.get("panel_url", "").startswith("file:///"):
    raise SystemExit("GSP headed report does not contain a file URL")
external = Path(sys.argv[1]).with_name("external-evidence.json")
external_report = json.loads(external.read_text(encoding="utf-8"))
if external_report.get("external_focus_actions_completed") is not True:
    raise SystemExit("external Wayland focus actions did not complete")
PY

echo "GSP headed acceptance: PASS ($out_dir/report.json)"
