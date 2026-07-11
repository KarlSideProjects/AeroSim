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


def first_checkpoint_failure(reference, actual):
    if "checkpoints" not in reference or "checkpoints" not in actual:
        raise ValueError("replay artifacts must contain physics-frame checkpoints")
    reference_checkpoints = reference["checkpoints"]
    actual_checkpoints = actual["checkpoints"]
    if len(reference_checkpoints) != len(actual_checkpoints):
        raise ValueError(
            f"checkpoint count differs: reference={len(reference_checkpoints)} actual={len(actual_checkpoints)}"
        )
    for reference_checkpoint, actual_checkpoint in zip(reference_checkpoints, actual_checkpoints):
        frame = reference_checkpoint["frame"]
        if actual_checkpoint["frame"] != frame:
            raise ValueError(
                f"checkpoint frame differs: reference={frame} actual={actual_checkpoint['frame']}"
            )
        angle = quat_angle_degrees(
            reference_checkpoint["orientation_xyzw"], actual_checkpoint["orientation_xyzw"]
        )
        position = position_delta_m(reference_checkpoint["position_m"], actual_checkpoint["position_m"])
        if angle > 0.5 or position > 0.05:
            angular_velocity = position_delta_m(
                reference_checkpoint["angular_velocity_rad_s"], actual_checkpoint["angular_velocity_rad_s"]
            )
            motor_thrust = position_delta_m(
                reference_checkpoint["motor_thrust_newtons"], actual_checkpoint["motor_thrust_newtons"]
            )
            return frame, angle, position, angular_velocity, motor_thrust
    return None


def main():
    if len(sys.argv) != 3:
        print("usage: compare_replay_artifacts.py reference.json actual.json", file=sys.stderr)
        return 2

    reference = load(pathlib.Path(sys.argv[1]))
    actual = load(pathlib.Path(sys.argv[2]))
    try:
        checkpoint_failure = first_checkpoint_failure(reference, actual)
    except (KeyError, ValueError) as error:
        print(f"G0.6a checkpoint artifact invalid: {error}", file=sys.stderr)
        return 1
    if checkpoint_failure is not None:
        frame, angle, position, angular_velocity, motor_thrust = checkpoint_failure
        print(
            "G0.6a checkpoint tolerance failed: "
            f"frame={frame} orientation={angle:.9f} deg position={position:.9f} m "
            f"angular_velocity_delta={angular_velocity:.9f} rad/s "
            f"motor_thrust_delta={motor_thrust:.9f} N",
            file=sys.stderr,
        )
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
