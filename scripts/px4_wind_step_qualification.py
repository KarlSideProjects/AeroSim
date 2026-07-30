#!/usr/bin/env python3
"""Fail-closed evaluator for an authentic PX4 wind-step evidence record."""

from __future__ import annotations

import json
import math
from typing import Any

PX4_REVISION = "1dacb4cdef2d7145754fc788fa8dc482eed74b40"
KIND = "aerosim.px4_wind_step_qualification"


def evaluate(evidence: dict[str, Any] | None) -> dict[str, Any]:
    if evidence is None:
        return {"status": "unavailable", "reason": "authentic PX4 wind-step evidence was not produced"}
    errors: list[str] = []
    if evidence.get("kind") != KIND or evidence.get("px4_revision") != PX4_REVISION:
        errors.append("evidence is not from the pinned PX4 qualification")
    if evidence.get("transport") != "real" or evidence.get("authority") != "px4_exclusive":
        errors.append("real PX4 exclusive authority was not verified")
    wind = evidence.get("wind") if isinstance(evidence.get("wind"), dict) else {}
    if not isinstance(wind.get("applied_tick"), int) or wind.get("applied_tick") != wind.get("replay_event_tick") or not isinstance(wind.get("replay_identity"), str) or not wind["replay_identity"]:
        errors.append("wind tick/replay identity does not match")
    actuators = evidence.get("actuators") if isinstance(evidence.get("actuators"), dict) else {}
    age = actuators.get("age_seconds")
    if actuators.get("fresh") is not True or actuators.get("mapping_verified") is not True or not isinstance(age, (int, float)) or isinstance(age, bool) or not math.isfinite(age) or age < 0 or age > 0.5:
        errors.append("fresh mapped actuators were not verified")
    lean = evidence.get("lean") if isinstance(evidence.get("lean"), dict) else {}
    lean_angle = lean.get("max_abs_roll_or_pitch_rad")
    if lean.get("observed") is not True or not isinstance(lean_angle, (int, float)) or isinstance(lean_angle, bool) or not math.isfinite(lean_angle) or lean_angle <= 0:
        errors.append("wind-response lean was not observed")
    samples = evidence.get("position_error_m")
    limits = evidence.get("limits") if isinstance(evidence.get("limits"), dict) else {}
    rms_limit, max_limit = limits.get("rms_m"), limits.get("max_m")
    if not isinstance(samples, list) or not samples or not all(isinstance(sample, (int, float)) and not isinstance(sample, bool) and math.isfinite(sample) and sample >= 0 for sample in samples) or not isinstance(rms_limit, (int, float)) or not isinstance(max_limit, (int, float)) or isinstance(rms_limit, bool) or isinstance(max_limit, bool) or not math.isfinite(rms_limit) or not math.isfinite(max_limit) or rms_limit <= 0 or max_limit <= 0:
        errors.append("frozen RMS/max position-error evidence is incomplete")
    else:
        rms = math.sqrt(sum(sample * sample for sample in samples) / len(samples))
        if rms > rms_limit or max(samples) > max_limit:
            errors.append("position error exceeded frozen RMS/max limits")
    return {"status": "failed" if errors else "qualified", "errors": errors}


def main() -> int:
    import argparse

    parser = argparse.ArgumentParser()
    parser.add_argument("--evidence")
    parser.add_argument("--output")
    args = parser.parse_args()
    evidence = None
    if args.evidence:
        with open(args.evidence, encoding="utf-8") as handle:
            evidence = json.load(handle)
    result = evaluate(evidence)
    if args.output:
        with open(args.output, "w", encoding="utf-8") as handle:
            json.dump(result, handle, indent=2)
            handle.write("\n")
    print(json.dumps(result, sort_keys=True))
    return 0 if result["status"] == "qualified" else 2


if __name__ == "__main__":
    raise SystemExit(main())
