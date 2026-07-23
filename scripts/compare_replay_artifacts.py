#!/usr/bin/env python3
import json
import math
import pathlib
import re
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
    checkpoints = reference.get("checkpoints")
    actual_checkpoints = actual.get("checkpoints")
    if not isinstance(checkpoints, list) or len(checkpoints) != 1 or checkpoints != actual_checkpoints:
        print("schema-v3 replay checkpoint diverged", file=sys.stderr)
        return 1
    checkpoint = checkpoints[0]
    if len(checkpoint.get("controllers", [])) != 2 or len(checkpoint.get("clocks", [])) != 2 or \
            len(checkpoint.get("first_response_substeps", [])) != 2:
        print("schema-v3 replay checkpoint is incomplete", file=sys.stderr)
        return 1
    response = checkpoint["first_response_substeps"][0]
    if response.get("substeps", 0) <= 0 or not any(response.get("state", {}).get("propwash", [])):
        print("schema-v3 replay first response lacks a real propwash substep", file=sys.stderr)
        return 1
    reference_bits = reference.get("ieee754_bits")
    actual_bits = actual.get("ieee754_bits")
    if not isinstance(reference_bits, dict) or not isinstance(actual_bits, dict) or reference_bits != actual_bits:
        print("IEEE-754 replay bit manifest diverged", file=sys.stderr)
        return 1
    required_bits = ["upper.propwash.x", "controller[0].target_angle.x", "controller[0].integral[0]",
                     "controller[0].derivative.x", "clock[0].accumulator", "first_response[0].time",
                     "first_response[0].propwash.x", "signed_zero_probe"]
    if any(not isinstance(reference_bits.get(field), str) or not re.fullmatch(r"[0-9a-f]{16}", reference_bits[field])
           for field in required_bits) or reference_bits["signed_zero_probe"] != "8000000000000000":
        print("IEEE-754 replay bit manifest is incomplete", file=sys.stderr)
        return 1
    print("schema-v3 replay checkpoint passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
