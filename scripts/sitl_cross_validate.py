#!/usr/bin/env python3
import argparse
import csv
import json
import math
import os
import subprocess
import sys
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
NATIVE_SOURCES = [
    "src/native/aerosim_aerodynamics.cpp",
    "src/native/aerosim_simulation.cpp",
    "src/native/aerosim_flight_control.cpp",
]
INPUT_HEADER = [
    "time_s",
    "throttle",
    "roll_degrees",
    "pitch_degrees",
    "yaw_rate_degrees_per_second",
]
OUTPUT_AXES = ["roll_degrees", "pitch_degrees", "yaw_degrees"]


def fail(message: str) -> int:
    print(f"not verified: {message}", file=sys.stderr)
    return 1


def validation_input() -> str:
    rows = []
    physics_hz = 240
    for frame in range(physics_hz * 6):
        time_s = (frame + 1) / physics_hz
        if time_s < 1.0:
            roll = 0.0
            pitch = 0.0
            yaw_rate = 0.0
        elif time_s < 2.5:
            roll = 25.0
            pitch = -10.0
            yaw_rate = 35.0
        elif time_s < 4.0:
            roll = -20.0
            pitch = 15.0
            yaw_rate = -55.0
        elif time_s < 5.0:
            roll = 12.0
            pitch = 0.0
            yaw_rate = 20.0
        else:
            roll = 0.0
            pitch = 0.0
            yaw_rate = 0.0
        rows.append([time_s, 0.5, roll, pitch, yaw_rate])

    output = [",".join(INPUT_HEADER)]
    output.extend(
        ",".join(f"{value:.9f}" for value in row)
        for row in rows
    )
    return "\n".join(output) + "\n"


def build_reference_runner(build_dir: Path) -> Path:
    build_dir.mkdir(parents=True, exist_ok=True)
    runner = build_dir / "aerosim_sitl_reference"
    compiler = os.environ.get("CXX", "g++")
    command = [
        compiler,
        "-std=c++17",
        "-Wall",
        "-Wextra",
        "-Werror",
        "-ffp-contract=off",
        "-Isrc/native",
        "tools/sitl/aerosim_sitl_reference.cpp",
        *NATIVE_SOURCES,
        "-o",
        str(runner),
    ]
    subprocess.run(command, cwd=REPO_ROOT, check=True)
    return runner


def run_csv_process(command: list[str], input_csv: str, label: str) -> list[dict[str, float]]:
    result = subprocess.run(
        command,
        cwd=REPO_ROOT,
        input=input_csv,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if result.returncode != 0:
        raise RuntimeError(f"{label} exited {result.returncode}: {result.stderr.strip()}")
    try:
        rows = []
        for row in csv.DictReader(result.stdout.splitlines()):
            rows.append({axis: float(row[axis]) for axis in ["time_s", *OUTPUT_AXES]})
        if not rows:
            raise ValueError("no rows")
        return rows
    except (KeyError, TypeError, ValueError) as exc:
        raise RuntimeError(f"{label} returned malformed CSV: {exc}") from exc


def pearson(left: list[float], right: list[float]) -> float:
    if len(left) != len(right) or len(left) < 2:
        raise ValueError("series length mismatch")
    left_mean = sum(left) / len(left)
    right_mean = sum(right) / len(right)
    numerator = sum((a - left_mean) * (b - right_mean) for a, b in zip(left, right))
    left_var = sum((a - left_mean) ** 2 for a in left)
    right_var = sum((b - right_mean) ** 2 for b in right)
    if left_var <= 0.0 or right_var <= 0.0:
        raise ValueError("zero-variance attitude series")
    return numerator / math.sqrt(left_var * right_var)


def compare(reference: list[dict[str, float]], adapter: list[dict[str, float]]) -> dict[str, float]:
    if len(reference) != len(adapter):
        raise ValueError(f"sample count mismatch: reference={len(reference)} adapter={len(adapter)}")
    return {
        axis: pearson([row[axis] for row in reference], [row[axis] for row in adapter])
        for axis in OUTPUT_AXES
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--adapter", default=os.environ.get("AEROSIM_BETAFLIGHT_SITL_ADAPTER"))
    parser.add_argument("--report", default="build/sitl_cross_validation.json")
    parser.add_argument("--build-dir", default="build/sitl")
    parser.add_argument("--threshold", type=float, default=0.85)
    args = parser.parse_args()

    if not args.adapter:
        return fail(
            "missing Betaflight SITL adapter; set AEROSIM_BETAFLIGHT_SITL_ADAPTER "
            "or pass --adapter to run the external-process validation"
        )
    adapter = Path(args.adapter)
    if not adapter.exists() or not os.access(adapter, os.X_OK):
        return fail(f"Betaflight SITL adapter is not executable: {adapter}")

    input_csv = validation_input()
    try:
        reference_runner = build_reference_runner(Path(args.build_dir))
        reference_rows = run_csv_process([str(reference_runner)], input_csv, "AeroSim reference runner")
        adapter_rows = run_csv_process([str(adapter)], input_csv, "Betaflight SITL adapter")
        correlations = compare(reference_rows, adapter_rows)
    except (OSError, RuntimeError, subprocess.CalledProcessError, ValueError) as exc:
        return fail(str(exc))

    minimum = min(correlations.values())
    report = {
        "gate": "G2.9",
        "verdict": "passed" if minimum >= args.threshold else "failed",
        "threshold": args.threshold,
        "minimum_correlation": minimum,
        "correlations": correlations,
        "samples": len(reference_rows),
        "adapter": str(adapter),
        "tier1_release_artifact": False,
        "gpl_isolation": {
            "adapter_boundary": "external_process_stdio",
            "bundled_betaflight_binary_or_source": False,
            "linked_into_aerosim": False,
        },
    }
    report_path = Path(args.report)
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"SITL cross validation report: {report_path}")

    if minimum < args.threshold:
        return fail(f"G2.9 correlation {minimum:.6f} is below threshold {args.threshold:.6f}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
