#!/usr/bin/env bash
set -euo pipefail

godot_bin="${GODOT_BIN:-godot}"
godot_cpp_dir="${GODOT_CPP_DIR:-.deps/godot-cpp}"
output_path="build/performance_report.json"
warmup_seconds=10
seconds=60
effects=off
benchmark_mode=gate
required_adapter="${AEROSIM_REQUIRED_GPU_ADAPTER:-NVIDIA}"
baseline_report=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        --output)
            output_path="$2"
            shift 2
            ;;
        --warmup-seconds)
            warmup_seconds="$2"
            shift 2
            ;;
        --seconds)
            seconds="$2"
            shift 2
            ;;
        --effects)
            effects="$2"
            shift 2
            ;;
        --mode)
            benchmark_mode="$2"
            shift 2
            ;;
        --require-adapter)
            required_adapter="$2"
            shift 2
            ;;
        --baseline-report)
            baseline_report="$2"
            shift 2
            ;;
        *)
            echo "unknown argument: $1" >&2
            exit 2
            ;;
    esac
done

python3 - "$benchmark_mode" "$warmup_seconds" "$seconds" <<'PY' || exit 2
import math
import sys

mode = sys.argv[1]
try:
    warmup_seconds = float(sys.argv[2])
    measured_seconds = float(sys.argv[3])
except ValueError:
    raise SystemExit("warmup and measurement durations must be numeric")
if mode not in {"gate", "reference", "smoke"}:
    raise SystemExit("mode must be gate, reference, or smoke")
if not math.isfinite(warmup_seconds) or not math.isfinite(measured_seconds):
    raise SystemExit("warmup and measurement durations must be finite")
if warmup_seconds < 0.0 or measured_seconds <= 0.0:
    raise SystemExit("warmup must be non-negative and measurement must be positive")
if mode != "smoke" and (warmup_seconds != 10.0 or measured_seconds != 60.0):
    raise SystemExit(f"{mode} mode requires exactly 10s warmup and 60s measurement")
PY

if [ "$benchmark_mode" = "gate" ]; then
    cpu_model="$(awk -F ': ' '/^model name/{print $2; exit}' /proc/cpuinfo 2>/dev/null || true)"
    case "$cpu_model" in
        "AMD Ryzen 9 7945HX with Radeon Graphics") ;;
        *)
            echo "gate mode requires the frozen AMD Ryzen 9 7945HX with Radeon Graphics CPU: ${cpu_model:-unknown}" >&2
            exit 2
            ;;
    esac
    required_adapter="NVIDIA GeForce RTX 4060 Ti"
fi

if [ -z "${DISPLAY:-}" ] && [ -z "${WAYLAND_DISPLAY:-}" ]; then
    echo "headed benchmark requires a real DISPLAY or WAYLAND_DISPLAY" >&2
    exit 2
fi
if ! command -v "$godot_bin" >/dev/null 2>&1; then
    echo "Godot 4.7 executable is required: $godot_bin" >&2
    exit 2
fi
if [ ! -d "$godot_cpp_dir/.git" ] || [ ! -f "$godot_cpp_dir/SConstruct" ]; then
    echo "godot-cpp checkout is required: $godot_cpp_dir" >&2
    exit 2
fi
scons_bin="${SCONS_BIN:-}"
if [ -z "$scons_bin" ]; then
    if command -v scons >/dev/null 2>&1; then
        scons_bin="$(command -v scons)"
    elif [ -x build/scons-venv/bin/scons ]; then
        scons_bin="build/scons-venv/bin/scons"
    elif [ -x .deps/venv/bin/scons ]; then
        scons_bin=".deps/venv/bin/scons"
    else
        echo "SCons is required to rebuild the measured GDExtension" >&2
        exit 2
    fi
fi

GODOT_CPP_DIR="$godot_cpp_dir" "$scons_bin" target=template_debug platform=linux
gdextension_path="bin/libaerosim_native.linux.template_debug.x86_64.so"
if [ ! -s "$gdextension_path" ]; then
    echo "rebuilt GDExtension is missing: $gdextension_path" >&2
    exit 2
fi

godot_version="$("$godot_bin" --version | head -n 1)"
godot_sha256="$(sha256sum "$godot_bin" | cut -d ' ' -f 1)"
godot_cpp_revision="$(git -C "$godot_cpp_dir" rev-parse HEAD)"
gdextension_sha256="$(sha256sum "$gdextension_path" | cut -d ' ' -f 1)"
native_source_sha256="$({ find src/native -type f -print0; printf 'SConstruct\0'; } \
    | sort -z \
    | xargs -0 sha256sum \
    | sha256sum \
    | cut -d ' ' -f 1)"

mkdir -p "$(dirname "$output_path")" .godot
raw_path="${output_path%.json}.raw.json"
chart_path="${output_path%.json}.svg"
rm -f "$raw_path" "$output_path" "$chart_path"
printf '%s\n' 'res://extensions/aerosim_native/aerosim_native.gdextension' > .godot/extension_list.cfg

timeout 180s "$godot_bin" --path . --resolution 1280x720 --remote-debug local:// \
    --script res://tests/performance/physics_benchmark.gd -- \
    --output "$raw_path" \
    --warmup-seconds "$warmup_seconds" \
    --seconds "$seconds" \
    --effects "$effects" \
    --benchmark-mode "$benchmark_mode" \
    --godot-version "$godot_version" \
    --godot-sha256 "$godot_sha256" \
    --godot-cpp-revision "$godot_cpp_revision" \
    --gdextension-sha256 "$gdextension_sha256" \
    --native-source-sha256 "$native_source_sha256" \
    --require-adapter "$required_adapter"

test -s "$raw_path"
report_args=(--input "$raw_path" --output "$output_path" --chart-output "$chart_path")
if [ -n "$baseline_report" ]; then
    report_args+=(--baseline-report "$baseline_report")
fi
python3 scripts/performance_report.py "${report_args[@]}"
rm -f "$raw_path"
