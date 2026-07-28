#!/usr/bin/env bash
set -euo pipefail

godot_bin="${GODOT_BIN:-godot}"
out_dir="build/headed"
use_xvfb=0
use_lavapipe_diagnostic=0
display_driver_args=()

while [ "$#" -gt 0 ]; do
    case "$1" in
        --xvfb)
            use_xvfb=1
            shift
            ;;
        --lavapipe-diagnostic)
            use_lavapipe_diagnostic=1
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

source "$(dirname "${BASH_SOURCE[0]}")/validate_native_provenance.sh"
validate_native_provenance
gdextension_sha256="$AEROSIM_NATIVE_PROVENANCE_GDEXTENSION_SHA256"
native_source_sha256="$AEROSIM_NATIVE_PROVENANCE_NATIVE_SOURCE_SHA256"

select_hardware_vulkan_icd() {
    if ! command -v vulkaninfo >/dev/null 2>&1; then
        echo "headed acceptance environment constraint: vulkaninfo is required to select a hardware Vulkan ICD" >&2
        return 1
    fi

    local candidates=()
    if [ -n "${AEROSIM_HEADED_VULKAN_ICD:-}" ]; then
        candidates=("$AEROSIM_HEADED_VULKAN_ICD")
    else
        candidates=(/usr/share/vulkan/icd.d/*.json /etc/vulkan/icd.d/*.json)
    fi

    local candidate=""
    local summary=""
    for candidate in "${candidates[@]}"; do
        [ -r "$candidate" ] || continue
        case "$(basename "$candidate")" in
            *lvp*|*lavapipe*|*swiftshader*|*gfxstream*|*virtio*)
                continue
                ;;
        esac
        summary="$(VK_ICD_FILENAMES="$candidate" vulkaninfo --summary 2>&1 || true)"
        if grep -Eq 'deviceType[[:space:]]*=[[:space:]]*PHYSICAL_DEVICE_TYPE_(DISCRETE|INTEGRATED)_GPU' <<<"$summary"; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done

    echo "headed acceptance environment constraint: no usable hardware Vulkan ICD was found; set AEROSIM_HEADED_VULKAN_ICD to a readable hardware ICD or use --lavapipe-diagnostic only for the quarantined renderer reproducer" >&2
    return 1
}

if [ "$use_lavapipe_diagnostic" -eq 1 ] && [ "$use_xvfb" -ne 1 ]; then
    echo "--lavapipe-diagnostic requires --xvfb" >&2
    exit 2
fi

if [ "$use_xvfb" -eq 1 ]; then
    command -v xvfb-run >/dev/null
    if [ "$use_lavapipe_diagnostic" -eq 1 ]; then
        lavapipe_icd="${AEROSIM_HEADED_LAVAPIPE_ICD:-/usr/share/vulkan/icd.d/lvp_icd.json}"
        if [ ! -r "$lavapipe_icd" ]; then
            echo "lavapipe diagnostic ICD is unavailable: $lavapipe_icd" >&2
            exit 1
        fi
        export VK_ICD_FILENAMES="$lavapipe_icd"
        echo "headed acceptance lavapipe diagnostic: this run is quarantined from qualification" >&2
    else
        hardware_icd="$(select_hardware_vulkan_icd)" || exit 2
        export VK_ICD_FILENAMES="$hardware_icd"
        echo "headed acceptance hardware Vulkan ICD: $hardware_icd" >&2
    fi
    launcher=(xvfb-run -a -e "$out_dir/xvfb.log" --server-args="-screen 0 1920x1080x24")
    display_driver_args=(--display-driver x11)
else
    launcher=()
fi

mkdir -p "$out_dir"
mkdir -p .godot
printf '%s\n' \
    'res://extensions/aerosim_native/aerosim_native.gdextension' \
    'res://addons/terrain_3d/terrain.gdextension' > .godot/extension_list.cfg
export AEROSIM_HEADED_COMMIT_SHA="$(git rev-parse HEAD)"
log_path="$out_dir/godot.log"
rm -f "$out_dir"/*.png "$out_dir/report.json" "$log_path" "$out_dir/xvfb.log"
timeout 180s "${launcher[@]}" "$godot_bin" "${display_driver_args[@]}" --path . --resolution 1280x720 \
    --log-file "$log_path" \
    --script res://tests/headed/headed_acceptance.gd -- --out-dir "$out_dir"

python3 - "$out_dir/report.json" "$gdextension_sha256" "$native_source_sha256" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
try:
    report = json.loads(path.read_text(encoding="utf-8"))
    provenance = report.get("provenance")
    if not isinstance(provenance, dict):
        raise ValueError("provenance is missing")
except (OSError, json.JSONDecodeError, ValueError) as error:
    raise SystemExit(f"cannot bind headed acceptance report to native artifact: {path}: {error}")
provenance["gdextension_sha256"] = sys.argv[2]
provenance["native_source_sha256"] = sys.argv[3]
path.write_text(json.dumps(report, separators=(",", ":")), encoding="utf-8")
PY

for required_file in \
    "$log_path" \
    "$out_dir/report.json" \
    "$out_dir/00_cold_start.png" \
    "$out_dir/00_keyboard_fallback_preconfirm.png" \
    "$out_dir/01_controller_confirmation.png" \
    "$out_dir/01_terrain_range_preflight.png" \
    "$out_dir/01_third_person_preflight.png" \
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

python3 - "$out_dir/report.json" "$(git rev-parse HEAD)" "$gdextension_sha256" "$native_source_sha256" <<'PY'
import json
import sys

path = sys.argv[1]
expected_commit_sha = sys.argv[2]
expected_gdextension_sha256 = sys.argv[3]
expected_native_source_sha256 = sys.argv[4]
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
if provenance.get("gdextension_sha256") != expected_gdextension_sha256:
    raise SystemExit(f"headed acceptance report GDExtension SHA is not bound to the debug artifact: {path}")
if provenance.get("native_source_sha256") != expected_native_source_sha256:
    raise SystemExit(f"headed acceptance report native source SHA is not bound to the debug artifact: {path}")
for field in ("godot_version", "os", "display_driver", "gpu_adapter"):
    if not provenance.get(field):
        raise SystemExit(f"headed acceptance report is missing provenance field {field}: {path}")
locale_switches = report.get("locale_switches")
if not isinstance(locale_switches, list) or not locale_switches:
    raise SystemExit(f"headed acceptance report is missing locale switch evidence: {path}")
for switch in locale_switches:
    if not isinstance(switch, dict) or not isinstance(switch.get("elapsed_us"), int):
        raise SystemExit(f"headed acceptance locale switch evidence is malformed: {path}")
    if switch["elapsed_us"] < 0:
        raise SystemExit(f"headed acceptance locale switch evidence is malformed: {path}")
PY

unexpected_errors="$(grep -E '^(ERROR:|SCRIPT ERROR:)' "$log_path" | grep -Fxv 'ERROR: X11 Display is not available' || true)"
if [ -n "$unexpected_errors" ]; then
    echo "Godot error found in headed acceptance log: $log_path" >&2
    exit 1
fi
