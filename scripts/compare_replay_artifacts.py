#!/usr/bin/env python3
import json
import math
import pathlib
import sys


def load(path):
    with open(path, encoding="utf-8") as handle:
        return json.load(handle)


def quat_angle_degrees(a, b):
    dot = abs(sum(x * y for x, y in zip(a, b)))
    norm_a = math.sqrt(sum(x * x for x in a))
    norm_b = math.sqrt(sum(x * x for x in b))
    if not math.isfinite(norm_a) or not math.isfinite(norm_b) or norm_a == 0 or norm_b == 0:
        return 180.0
    dot = max(0.0, min(1.0, dot / (norm_a * norm_b)))
    return math.degrees(2.0 * math.acos(dot))


def position_delta_m(a, b):
    return math.sqrt(sum((x - y) ** 2 for x, y in zip(a, b)))


def main():
    if len(sys.argv) != 3:
        print("usage: compare_replay_artifacts.py reference.json actual.json", file=sys.stderr)
        return 2

    reference = load(pathlib.Path(sys.argv[1]))
    actual = load(pathlib.Path(sys.argv[2]))
    if reference.get("schema_version") != 3 or actual.get("schema_version") != 3:
        print("replay artifact schema_version must be 3", file=sys.stderr)
        return 1
    if reference.get("substeps") != actual.get("substeps") or reference.get("time_seconds") != actual.get("time_seconds"):
        print("replay clock diverged", file=sys.stderr)
        return 1
    reference_motors = reference.get("motor_thrust_newtons")
    actual_motors = actual.get("motor_thrust_newtons")
    if not isinstance(reference_motors, list) or not isinstance(actual_motors, list) or reference_motors != actual_motors:
        print("replay motor state diverged", file=sys.stderr)
        return 1
    angle = quat_angle_degrees(reference["orientation_xyzw"], actual["orientation_xyzw"])
    position = position_delta_m(reference["position_m"], actual["position_m"])
    if angle > 0.5 or position > 0.05:
        print(f"G0.6a tolerance failed: orientation={angle:.9f} deg position={position:.9f} m", file=sys.stderr)
        return 1
    print(f"G0.6a tolerance passed: orientation={angle:.9f} deg position={position:.9f} m")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
