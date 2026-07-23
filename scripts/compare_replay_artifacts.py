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
    print("schema-v3 replay checkpoint passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
