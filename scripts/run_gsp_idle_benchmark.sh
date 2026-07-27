#!/usr/bin/env bash
set -euo pipefail

godot_bin="${GODOT_BIN:-godot}"
output_dir="${AEROSIM_GSP_IDLE_OUTPUT_DIR:-build/gsp-idle-benchmark}"
warmup_seconds=10
seconds=60

if [ "$warmup_seconds" -ne 10 ] || [ "$seconds" -ne 60 ]; then
    echo "paired GSP benchmark requires exactly 10s warmup and 60s measurement" >&2
    exit 2
fi
if [ ! -x "$godot_bin" ]; then
    echo "Godot executable is required: $godot_bin" >&2
    exit 2
fi
commit_sha="$(git rev-parse HEAD)"
mkdir -p "$output_dir"
disabled="$output_dir/disabled.raw.json"
idle="$output_dir/authenticated-idle.raw.json"
comparison="$output_dir/comparison.json"

run_case() {
    local mode="$1"
    local output="$2"
    timeout 180s "$godot_bin" --headless --fixed-fps 240 --path . \
        --script res://tests/performance/gsp_idle_physics_benchmark.gd -- \
        --mode "$mode" --warmup-seconds 10 --seconds 60 --commit-sha "$commit_sha" --output "$output"
}

run_case disabled "$disabled"
run_case authenticated-idle "$idle"

python3 - "$disabled" "$idle" "$comparison" <<'PY'
import json
import math
import statistics
import sys
from pathlib import Path

disabled_path, idle_path, comparison_path = map(Path, sys.argv[1:])
disabled = json.loads(disabled_path.read_text())
idle = json.loads(idle_path.read_text())
for label, payload in (("disabled", disabled), ("authenticated-idle", idle)):
    if payload.get("sample_count") != 14400 or len(payload.get("samples_usec", [])) != 14400:
        raise SystemExit(f"{label} did not produce the complete 60-second 14400-sample run")
    if payload.get("physics_ticks_per_second") != 240:
        raise SystemExit(f"{label} has incompatible physics tick rate")
    if not all(isinstance(item, (int, float)) and math.isfinite(item) and item >= 0 for item in payload["samples_usec"]):
        raise SystemExit(f"{label} contains invalid raw samples")

def percentile(values, fraction):
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, math.ceil(len(ordered) * fraction) - 1)]

disabled_samples = disabled["samples_usec"]
idle_samples = idle["samples_usec"]
metrics = {}
for name, fn in (("mean_usec", statistics.fmean), ("p95_usec", lambda values: percentile(values, 0.95)), ("p99_usec", lambda values: percentile(values, 0.99))):
    disabled_value = fn(disabled_samples)
    idle_value = fn(idle_samples)
    delta_percent = abs(idle_value - disabled_value) / max(abs(disabled_value), 1e-9) * 100.0
    metrics[name] = {"disabled": disabled_value, "authenticated_idle": idle_value, "absolute_delta_percent": delta_percent}

passed = all(metric["absolute_delta_percent"] < 1.0 for metric in metrics.values())
comparison = {
    "status": "pass" if passed else "fail",
    "run_order": ["disabled", "authenticated-idle"],
    "warmup_seconds": 10,
    "measured_seconds": 60,
    "sample_count": 14400,
    "metric": "AeroSimNative.step_angle_mode wall time inside real Godot physics frames",
    "metrics": metrics,
    "raw_artifacts": {"disabled": str(disabled_path), "authenticated_idle": str(idle_path)},
}
comparison_path.write_text(json.dumps(comparison, indent=2) + "\n")
print(json.dumps(comparison, sort_keys=True))
if not passed:
    raise SystemExit(1)
PY
