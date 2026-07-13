#!/usr/bin/env python3
"""Compare C++ A4/A5 cases with the pinned gym-pybullet-drones oracle."""

import csv
import sys
from pathlib import Path

from pinned_oracle import load_pinned_oracle


TOLERANCE = 1e-6


def python_original_ground_effect(row, np, p, BaseAviary):
    height = float(row["height"])
    rpm = np.array([float(row[f"rpm_{index}"]) for index in range(4)])

    aviary = object.__new__(BaseAviary)
    aviary.KF = float(row["kf"])
    aviary.GND_EFF_COEFF = float(row["gnd_eff_coeff"])
    aviary.PROP_RADIUS = float(row["prop_radius"])
    aviary.GND_EFF_H_CLIP = float(row["height_clip"])
    aviary.rpy = np.array([[0.0, 0.0, 0.0]])
    aviary.DRONE_IDS = [0]
    aviary.CLIENT = 0

    def get_link_states(*_args, **_kwargs):
        return [((0.0, 0.0, height),) for _ in range(5)]

    forces = []
    original_get_link_states = getattr(p, "getLinkStates", None)
    original_apply = p.applyExternalForce
    p.getLinkStates = get_link_states

    def capture_apply_external_force(*_args, forceObj, **_kwargs):
        forces.append(tuple(float(value) for value in forceObj))

    p.applyExternalForce = capture_apply_external_force
    try:
        BaseAviary._groundEffect(aviary, rpm, 0)
    finally:
        p.applyExternalForce = original_apply
        if original_get_link_states is None:
            delattr(p, "getLinkStates")
        else:
            p.getLinkStates = original_get_link_states

    if len(forces) != 4:
        raise RuntimeError("gym-pybullet-drones BaseAviary._groundEffect did not emit four prop forces")
    return sum(force[2] for force in forces)


def python_original_downwash(row, np, p, BaseAviary):
    upper = (
        float(row["upper_x"]),
        float(row["upper_z"]),
        float(row["upper_y"]),
    )
    lower = (
        float(row["lower_x"]),
        float(row["lower_z"]),
        float(row["lower_y"]),
    )

    aviary = object.__new__(BaseAviary)
    aviary.NUM_DRONES = 2
    aviary.PROP_RADIUS = float(row["prop_radius"])
    aviary.DW_COEFF_1 = float(row["dw_coeff_1"])
    aviary.DW_COEFF_2 = float(row["dw_coeff_2"])
    aviary.DW_COEFF_3 = float(row["dw_coeff_3"])
    aviary.pos = np.array([upper, lower])
    aviary.DRONE_IDS = [0, 1]
    aviary.CLIENT = 0

    captured = {}
    original_apply = p.applyExternalForce

    def capture_apply_external_force(*_args, forceObj, **_kwargs):
        captured["force"] = tuple(float(value) for value in forceObj)

    p.applyExternalForce = capture_apply_external_force
    try:
        BaseAviary._downwash(aviary, 1)
    finally:
        p.applyExternalForce = original_apply

    if "force" not in captured:
        raise RuntimeError("gym-pybullet-drones BaseAviary._downwash did not emit a force")
    return captured["force"][2]


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: check_a4_a5_oracle.py build/a4_a5_oracle_cases.csv", file=sys.stderr)
        return 2

    path = Path(sys.argv[1])
    if not path.is_file():
        print(f"A4/A5 oracle cases not found: {path}", file=sys.stderr)
        return 1

    try:
        np, p, BaseAviary = load_pinned_oracle()
    except RuntimeError as exc:
        print(str(exc), file=sys.stderr)
        return 1

    with path.open(newline="", encoding="utf-8") as handle:
        rows = list(csv.DictReader(handle))
    if not rows:
        print("A4/A5 oracle cases file is empty", file=sys.stderr)
        return 1

    seen = {"a4": 0, "a5": 0}
    for row in rows:
        effect = row["effect"]
        if effect == "a4":
            expected = python_original_ground_effect(row, np, p, BaseAviary)
        elif effect == "a5":
            expected = python_original_downwash(row, np, p, BaseAviary)
        else:
            print(f"unknown A4/A5 oracle effect: {effect}", file=sys.stderr)
            return 1

        actual = float(row["force_y"])
        if abs(actual - expected) > TOLERANCE:
            print(
                f"{effect.upper()} oracle mismatch case={row.get('case', '?')} "
                f"actual={actual:.17g} expected={expected:.17g}",
                file=sys.stderr,
            )
            return 1
        seen[effect] += 1

    if seen["a4"] == 0 or seen["a5"] == 0:
        print(f"A4/A5 oracle missing cases: {seen}", file=sys.stderr)
        return 1
    print(f"A4/A5 oracle compared {len(rows)} cases within {TOLERANCE:g}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
