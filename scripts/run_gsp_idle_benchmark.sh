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
comparison="$output_dir/comparison.json"

run_case() {
    local mode="$1"
    local output="$2"
    timeout 240s "$godot_bin" --headless --fixed-fps 240 --remote-debug local:// --path . \
        --script res://tests/performance/physics_benchmark.gd -- \
        --benchmark-mode reference --gsp-mode "$mode" --effects off \
        --warmup-seconds 10 --seconds 60 --commit-sha "$commit_sha" \
        --output "$output"
}

run_case disabled "$output_dir/disabled-a.raw.json"
run_case authenticated-idle "$output_dir/authenticated-idle-a.raw.json"
run_case authenticated-idle "$output_dir/authenticated-idle-b.raw.json"
run_case disabled "$output_dir/disabled-b.raw.json"
run_case disabled "$output_dir/disabled-c.raw.json"
run_case authenticated-idle "$output_dir/authenticated-idle-c.raw.json"
run_case authenticated-idle "$output_dir/authenticated-idle-d.raw.json"
run_case disabled "$output_dir/disabled-d.raw.json"

python3 - "$output_dir" "$comparison" <<'PY'
import json
import math
import statistics
import sys
from pathlib import Path

output_dir, comparison_path = map(Path, sys.argv[1:])
run_order = [
    ("disabled-a", "disabled"),
    ("authenticated-idle-a", "authenticated-idle"),
    ("authenticated-idle-b", "authenticated-idle"),
    ("disabled-b", "disabled"),
    ("disabled-c", "disabled"),
    ("authenticated-idle-c", "authenticated-idle"),
    ("authenticated-idle-d", "authenticated-idle"),
    ("disabled-d", "disabled"),
]
payloads = {}
for label, expected_mode in run_order:
    payload = json.loads((output_dir / f"{label}.raw.json").read_text())
    payloads[label] = payload
    samples = payload.get("samples_ms", [])
    if payload.get("sample_count") != 14400 or len(samples) != 14400:
        raise SystemExit(f"{label} did not produce the complete 60-second 14400-sample run")
    if payload.get("gsp_mode") != expected_mode or payload.get("sampling_source") != "PhysicsFrameProfiler._tick":
        raise SystemExit(f"{label} lacks the production PhysicsFrameProfiler provenance")
    if payload.get("physics_ticks_per_second") != 240:
        raise SystemExit(f"{label} has incompatible physics tick rate")
    if not all(isinstance(item, (int, float)) and math.isfinite(item) and item > 0 for item in samples):
        raise SystemExit(f"{label} contains invalid raw physics samples")

def percentile(values, fraction):
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, math.ceil(len(ordered) * fraction) - 1)]

def mode_samples(mode):
    return [payloads[label]["samples_ms"] for label, expected_mode in run_order if expected_mode == mode]

disabled_samples = mode_samples("disabled")
idle_samples = mode_samples("authenticated-idle")
metrics = {}
for name, fn in (("mean_ms", statistics.fmean), ("p50_ms", lambda values: percentile(values, 0.50)), ("p95_ms", lambda values: percentile(values, 0.95)), ("p99_ms", lambda values: percentile(values, 0.99))):
    disabled_values = [fn(samples) for samples in disabled_samples]
    idle_values = [fn(samples) for samples in idle_samples]
    disabled_value = statistics.fmean(disabled_values)
    idle_value = statistics.fmean(idle_values)
    delta_percent = abs(idle_value - disabled_value) / max(abs(disabled_value), 1e-12) * 100.0
    metrics[name] = {"disabled_runs": disabled_values, "authenticated_idle_runs": idle_values, "disabled": disabled_value, "authenticated_idle": idle_value, "absolute_delta_percent": delta_percent}

passed = all(metric["absolute_delta_percent"] < 1.0 for metric in metrics.values())
comparison = {
    "status": "pass" if passed else "fail",
    "run_order": [label for label, mode in run_order],
    "pairing": "two predeclared ABBA repetitions; aggregate every run metric by mode",
    "warmup_seconds": 10,
    "measured_seconds": 60,
    "sample_count": 14400,
    "run_count": len(run_order),
    "metric": "production PhysicsFrameProfiler physics_time_ms",
    "provenance": {
        "commits": sorted({payloads[label].get("commit_sha") for label, mode in run_order}),
        "sampling_source": "PhysicsFrameProfiler._tick",
        "workload_source": "EffectWorkload on the production SmokeScene",
    },
    "metrics": metrics,
    "raw_artifacts": {label: str(output_dir / f"{label}.raw.json") for label, mode in run_order},
}
comparison_path.write_text(json.dumps(comparison, indent=2) + "\n")
print(json.dumps(comparison, sort_keys=True))
if not passed:
    raise SystemExit(1)
PY
