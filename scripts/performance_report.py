#!/usr/bin/env python3
"""Build a machine-readable G0.1 timing report from raw frame samples."""

import argparse
import json
import math
import platform
import subprocess
from typing import Any
from pathlib import Path


G0_1_P99_LIMIT_MS = 3.0
G3_7_P99_LIMIT_MS = 3.0
G3_7_MAX_INCREASE_PERCENT = 20.0
G3_7_EFFECTS = ["A3_drag", "A4_ground_effect", "A5_downwash", "A6_propwash"]
G0_1_BASELINE_CPU = "AMD Ryzen 9 7945HX with Radeon Graphics"
G0_1_BASELINE_GPU = "NVIDIA GeForce RTX 4060 Ti"
G0_1_BASELINE_OS_RELEASE = "Ubuntu 26.04 LTS"
G0_1_BASELINE_NVIDIA_DRIVER = "580.159.03"
PINNED_GODOT_VERSION = "4.7.stable.official.5b4e0cb0f"
PINNED_GODOT_BINARY_SHA256 = "f85bbc6b15e22416c7d797cd60b63286dd67b9cb13498847056c18520ae55a75"
PINNED_GODOT_CPP_REVISION = "ba0edfed90512ec64aba51d4295a3e7e30112f86"


def _percentile(samples: list[float], fraction: float) -> float:
    ordered = sorted(samples)
    return ordered[math.ceil(len(ordered) * fraction) - 1]


def _validated_samples(raw: dict[str, Any], key: str) -> list[float]:
    samples = raw.get(key)
    if not isinstance(samples, list) or not samples:
        raise ValueError(f"{key} must be a non-empty list")
    if not all(isinstance(sample, (int, float)) and math.isfinite(sample) and sample >= 0.0 for sample in samples):
        raise ValueError(f"{key} must contain finite non-negative values")
    return [float(sample) for sample in samples]


def _validate_gate_eligibility(raw: dict[str, Any], environment: dict[str, Any]) -> None:
    cpu_model = str(environment.get("cpu_model", ""))
    video_adapter = str(raw.get("video_adapter", ""))
    cpu_matches = cpu_model == G0_1_BASELINE_CPU or cpu_model.startswith(f"{G0_1_BASELINE_CPU} ")
    os_matches = environment.get("os_release") == G0_1_BASELINE_OS_RELEASE
    driver_matches = environment.get("nvidia_driver_version") == G0_1_BASELINE_NVIDIA_DRIVER
    provenance_is_pinned = (
        raw.get("godot_version") == PINNED_GODOT_VERSION
        and raw.get("godot_sha256") == PINNED_GODOT_BINARY_SHA256
        and raw.get("godot_cpp_revision") == PINNED_GODOT_CPP_REVISION
        and all(
            isinstance(raw.get(key), str)
            and len(raw[key]) == 64
            and all(character in "0123456789abcdef" for character in raw[key])
            for key in ("gdextension_sha256", "native_source_sha256")
        )
    )
    if not cpu_matches or video_adapter != G0_1_BASELINE_GPU or not os_matches or not driver_matches or not provenance_is_pinned:
        raise ValueError(
            "G0.1 gate requires the frozen Ryzen 9 7945HX and RTX 4060 Ti on Ubuntu 26.04 LTS and NVIDIA driver 580.159.03 with pinned Godot/godot-cpp provenance"
        )


def build_report(raw: dict[str, Any], environment: dict[str, Any]) -> dict[str, Any]:
    benchmark_mode = raw.get("benchmark_mode")
    if benchmark_mode not in {"gate", "reference", "smoke"}:
        raise ValueError("benchmark_mode must be gate, reference, or smoke")
    measurements = _validated_samples(raw, "samples_ms")
    if benchmark_mode == "gate":
        _validate_gate_eligibility(raw, environment)
    render_summaries: dict[str, float] = {}
    for key, prefix in (
        ("render_cpu_samples_ms", "render_cpu"),
        ("render_gpu_samples_ms", "render_gpu"),
    ):
        if key not in raw:
            continue
        render_samples = _validated_samples(raw, key)
        if len(render_samples) != len(measurements):
            raise ValueError(f"{key} must match samples_ms length")
        render_summaries[f"{prefix}_p95_ms"] = _percentile(render_samples, 0.95)
        render_summaries[f"{prefix}_p99_ms"] = _percentile(render_samples, 0.99)

    p99_ms = _percentile(measurements, 0.99)
    p99_within_limit = p99_ms <= G0_1_P99_LIMIT_MS
    gate_eligible = benchmark_mode == "gate"
    report = {
        "schema_version": 1,
        "gate": {
            "gate": "G0.1",
            "reference": "G0.1-reference",
            "smoke": "smoke",
        }[benchmark_mode],
        "gate_eligible": gate_eligible,
        "reference_only": benchmark_mode == "reference",
        "scenario": raw.get("scenario", "unspecified"),
        "sample_count": len(measurements),
        "p95_ms": _percentile(measurements, 0.95),
        "p99_ms": p99_ms,
        "p99_limit_ms": G0_1_P99_LIMIT_MS,
        "p99_within_limit": p99_within_limit,
        "raw_samples_ms": measurements,
        "measurement": {key: value for key, value in raw.items() if key != "samples_ms"},
        "environment": environment,
    }
    if gate_eligible:
        report["gate_verdict"] = "pass" if p99_within_limit else "fail"
    report.update(render_summaries)
    return report


def compare_reports(baseline: dict[str, Any], candidate: dict[str, Any]) -> dict[str, Any]:
    if baseline.get("environment") != candidate.get("environment"):
        raise ValueError("baseline and candidate environments must match")
    if baseline.get("scenario") != "effects_off" or candidate.get("scenario") != "effects_on":
        raise ValueError("comparison requires an effects_off baseline and effects_on candidate")
    for label, report in (("baseline", baseline), ("candidate", candidate)):
        sample_count = report.get("sample_count")
        if not isinstance(sample_count, int) or sample_count <= 0:
            raise ValueError(f"incompatible benchmark reports: {label} sample_count is required")
    if baseline["sample_count"] != candidate["sample_count"]:
        raise ValueError("incompatible benchmark reports: sample_count differs")
    for label, report in (("baseline", baseline), ("candidate", candidate)):
        p99 = report.get("p99_ms")
        if not isinstance(p99, (int, float)) or not math.isfinite(p99) or p99 < 0.0:
            raise ValueError(f"incompatible benchmark reports: {label} p99_ms is required")
    baseline_p99 = float(baseline["p99_ms"])
    candidate_p99 = float(candidate["p99_ms"])
    if baseline_p99 <= 0.0:
        raise ValueError("incompatible benchmark reports: baseline p99_ms must be greater than zero")
    baseline_measurement = baseline.get("measurement")
    candidate_measurement = candidate.get("measurement")
    if not isinstance(baseline_measurement, dict) or not isinstance(candidate_measurement, dict):
        raise ValueError("incompatible benchmark reports: measurement metadata is required")
    for label, report, p99, measurement in (
        ("baseline", baseline, baseline_p99, baseline_measurement),
        ("candidate", candidate, candidate_p99, candidate_measurement),
    ):
        if (
            measurement.get("benchmark_mode") != "gate"
            or report.get("gate") != "G0.1"
            or report.get("reference_only") is not False
            or report.get("gate_eligible") is not True
        ):
            raise ValueError("G3.7 requires passing G0.1 production reports")
        if report.get("p99_within_limit") is not True:
            raise ValueError(f"incompatible benchmark reports: {label} p99 limit evidence is invalid")
        recomputed_verdict = "pass" if p99 <= G0_1_P99_LIMIT_MS else "fail"
        if report.get("gate_verdict") != "pass" and recomputed_verdict != "pass":
            raise ValueError(f"incompatible benchmark reports: {label} G0.1 verdict is invalid")
        if recomputed_verdict != "pass":
            raise ValueError(f"incompatible benchmark reports: {label} p99 exceeds the G0.1 limit")
    invariant_keys = (
        "benchmark_mode",
        "warmup_seconds",
        "measured_seconds",
        "physics_engine",
        "physics_ticks_per_second",
        "substep_hz",
        "vsync_mode",
        "video_adapter",
        "rendering_method",
        "godot_version",
        "godot_sha256",
        "godot_cpp_revision",
        "gdextension_sha256",
        "native_source_sha256",
    )
    for key in invariant_keys:
        if key not in baseline_measurement or key not in candidate_measurement:
            raise ValueError(f"incompatible benchmark reports: {key} is required")
        if baseline_measurement[key] != candidate_measurement[key]:
            raise ValueError(f"incompatible benchmark reports: {key} differs")
    if baseline_measurement.get("active_effects") != []:
        raise ValueError("incompatible benchmark reports: effects_off baseline must have no active effects")
    if candidate_measurement.get("active_effects") != G3_7_EFFECTS:
        raise ValueError("incompatible benchmark reports: effects_on candidate must activate A3-A6")
    effect_evidence = candidate_measurement.get("effect_evidence")
    if (
        not isinstance(effect_evidence, dict)
        or any(
            not isinstance(effect_evidence.get(effect), dict)
            or effect_evidence[effect].get("observed") is not True
            for effect in G3_7_EFFECTS
        )
    ):
        raise ValueError("incompatible benchmark reports: effect evidence must prove A3-A6 activation")
    comparison: dict[str, float | None] = {}
    for metric in ("p95_ms", "p99_ms", "render_cpu_p95_ms", "render_cpu_p99_ms", "render_gpu_p95_ms", "render_gpu_p99_ms"):
        if metric not in baseline or metric not in candidate:
            continue
        baseline_value = float(baseline[metric])
        delta = float(candidate[metric]) - baseline_value
        prefix = metric.removesuffix("_ms")
        comparison[f"{prefix}_delta_ms"] = delta
        comparison[f"{prefix}_delta_percent"] = None if baseline_value == 0.0 else delta * 100.0 / baseline_value
    p99_delta = candidate_p99 - baseline_p99
    p99_delta_percent = p99_delta * 100.0 / baseline_p99
    comparison["g3_7_p99_within_limit"] = candidate_p99 <= G3_7_P99_LIMIT_MS
    comparison["g3_7_increase_within_limit"] = p99_delta_percent <= G3_7_MAX_INCREASE_PERCENT
    comparison["g3_7_verdict"] = (
        "pass"
        if comparison["g3_7_p99_within_limit"] and comparison["g3_7_increase_within_limit"]
        else "fail"
    )
    return comparison


def write_chart(report: dict[str, Any], path: Path) -> None:
    plot_x = 150.0
    plot_width = 440.0
    maximum = max(float(report["p99_limit_ms"]), float(report["p95_ms"]), float(report["p99_ms"]))
    scale = plot_width / maximum
    bars = []
    for label, key, y, color in (("P95", "p95_ms", 80, "#4c78a8"), ("P99", "p99_ms", 140, "#f58518")):
        value = float(report[key])
        bars.append(f'<text x="20" y="{y + 22}" font-size="18">{label} {value:.3f} ms</text>')
        bars.append(f'<rect x="{plot_x}" y="{y}" width="{value * scale:.2f}" height="32" fill="{color}"/>')
    limit_x = plot_x + float(report["p99_limit_ms"]) * scale
    svg = "\n".join([
        '<svg xmlns="http://www.w3.org/2000/svg" width="640" height="220" viewBox="0 0 640 220">',
        '<rect width="640" height="220" fill="white"/>',
        '<text x="20" y="35" font-size="24">G0.1 physics frame time</text>',
        *bars,
        f'<line x1="{limit_x:.2f}" y1="65" x2="{limit_x:.2f}" y2="185" stroke="#d62728" stroke-width="3"/>',
        f'<text x="{limit_x - 70:.2f}" y="205" font-size="16" fill="#d62728">limit {report["p99_limit_ms"]:.1f} ms</text>',
        '</svg>',
        '',
    ])
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(svg, encoding="utf-8")


def _git_revision() -> str:
    return subprocess.check_output(
        ["git", "rev-parse", "HEAD"],
        cwd=Path(__file__).resolve().parents[1],
        text=True,
    ).strip()


def _cpu_model() -> str:
    cpuinfo = Path("/proc/cpuinfo")
    if cpuinfo.is_file():
        for line in cpuinfo.read_text(encoding="utf-8").splitlines():
            if line.startswith("model name"):
                return line.partition(":")[2].strip()
    return platform.processor() or "unknown"


def _os_release() -> str:
    os_release = Path("/etc/os-release")
    if os_release.is_file():
        for line in os_release.read_text(encoding="utf-8").splitlines():
            if line.startswith("PRETTY_NAME="):
                return line.partition("=")[2].strip().strip('"')
    return "unknown"


def _nvidia_driver_version() -> str:
    try:
        return subprocess.check_output(
            ["nvidia-smi", "--query-gpu=driver_version", "--format=csv,noheader"],
            text=True,
        ).splitlines()[0].strip()
    except (OSError, IndexError, subprocess.SubprocessError):
        return "unknown"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--git-revision")
    parser.add_argument("--baseline-report", type=Path)
    parser.add_argument("--chart-output", type=Path)
    args = parser.parse_args()

    try:
        raw = json.loads(args.input.read_text(encoding="utf-8"))
        if not isinstance(raw, dict):
            raise ValueError("input must be a JSON object")
        report = build_report(
            raw,
            {
                "git_revision": args.git_revision or _git_revision(),
                "cpu_model": _cpu_model(),
                "os": platform.platform(),
                "os_release": _os_release(),
                "nvidia_driver_version": _nvidia_driver_version(),
            },
        )
        if args.baseline_report:
            baseline = json.loads(args.baseline_report.read_text(encoding="utf-8"))
            if not isinstance(baseline, dict):
                raise ValueError("baseline report must be a JSON object")
            report["comparison_to_baseline"] = compare_reports(baseline, report)
    except (OSError, json.JSONDecodeError, ValueError, subprocess.SubprocessError) as error:
        parser.error(str(error))

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, separators=(",", ":")) + "\n", encoding="utf-8")
    if args.chart_output:
        write_chart(report, args.chart_output)
    comparison_failed = report.get("comparison_to_baseline", {}).get("g3_7_verdict") == "fail"
    return 1 if report.get("gate_verdict") == "fail" or comparison_failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
