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


def build_report(raw: dict[str, Any], environment: dict[str, Any]) -> dict[str, Any]:
    measurements = _validated_samples(raw, "samples_ms")
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
    report = {
        "schema_version": 1,
        "gate": "G0.1",
        "scenario": raw.get("scenario", "unspecified"),
        "sample_count": len(measurements),
        "p95_ms": _percentile(measurements, 0.95),
        "p99_ms": p99_ms,
        "p99_limit_ms": G0_1_P99_LIMIT_MS,
        "p99_within_gate": p99_ms <= G0_1_P99_LIMIT_MS,
        "raw_samples_ms": measurements,
        "measurement": {key: value for key, value in raw.items() if key != "samples_ms"},
        "environment": environment,
    }
    report.update(render_summaries)
    return report


def compare_reports(baseline: dict[str, Any], candidate: dict[str, Any]) -> dict[str, float | None]:
    if baseline.get("environment") != candidate.get("environment"):
        raise ValueError("baseline and candidate environments must match")
    comparison: dict[str, float | None] = {}
    for metric in ("p95_ms", "p99_ms", "render_cpu_p95_ms", "render_cpu_p99_ms", "render_gpu_p95_ms", "render_gpu_p99_ms"):
        if metric not in baseline or metric not in candidate:
            continue
        baseline_value = float(baseline[metric])
        delta = float(candidate[metric]) - baseline_value
        prefix = metric.removesuffix("_ms")
        comparison[f"{prefix}_delta_ms"] = delta
        comparison[f"{prefix}_delta_percent"] = None if baseline_value == 0.0 else delta * 100.0 / baseline_value
    return comparison


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


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--git-revision")
    parser.add_argument("--baseline-report", type=Path)
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
    args.output.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
