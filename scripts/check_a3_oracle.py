#!/usr/bin/env python3
"""Compare C++ A3 drag cases with the pinned gym-pybullet-drones oracle."""

import csv
import sys
from pathlib import Path

from pinned_oracle import load_pinned_oracle


TOLERANCE = 1e-6


def python_original_drag(row, np, p, BaseAviary):
    coeff = (float(row["coeff_x"]), float(row["coeff_y"]), float(row["coeff_z"]))
    rpm = [float(row[f"rpm_{index}"]) for index in range(4)]
    q = tuple(float(row[key]) for key in ("qx", "qy", "qz", "qw"))
    velocity = tuple(float(row[key]) for key in ("vx", "vy", "vz"))

    aviary = object.__new__(BaseAviary)
    aviary.DRAG_COEFF = np.array(coeff)
    aviary.quat = np.array([q])
    aviary.vel = np.array([velocity])
    aviary.DRONE_IDS = [0]
    aviary.CLIENT = 0

    captured = {}
    original_apply = p.applyExternalForce

    def capture_apply_external_force(*_args, forceObj, **_kwargs):
        captured["force"] = tuple(float(value) for value in forceObj)

    p.applyExternalForce = capture_apply_external_force
    try:
        BaseAviary._drag(aviary, np.array(rpm), 0)
    finally:
        p.applyExternalForce = original_apply

    if "force" not in captured:
        raise RuntimeError("gym-pybullet-drones BaseAviary._drag did not emit a force")
    return captured["force"]


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: check_a3_oracle.py build/a3_oracle_cases.csv", file=sys.stderr)
        return 2

    path = Path(sys.argv[1])
    if not path.is_file():
        print(f"A3 oracle cases not found: {path}", file=sys.stderr)
        return 1

    try:
        np, p, BaseAviary = load_pinned_oracle()
    except RuntimeError as exc:
        print(str(exc), file=sys.stderr)
        return 1

    with path.open(newline="", encoding="utf-8") as handle:
        rows = list(csv.DictReader(handle))
    if not rows:
        print("A3 oracle cases file is empty", file=sys.stderr)
        return 1

    for row in rows:
        expected = python_original_drag(row, np, p, BaseAviary)
        actual = tuple(float(row[key]) for key in ("force_x", "force_y", "force_z"))
        for axis, (a_value, e_value) in enumerate(zip(actual, expected)):
            if abs(a_value - e_value) > TOLERANCE:
                print(
                    f"A3 oracle mismatch case={row.get('case', '?')} axis={axis} "
                    f"actual={a_value:.17g} expected={e_value:.17g}",
                    file=sys.stderr,
                )
                return 1
    print(f"A3 oracle compared {len(rows)} cases within {TOLERANCE:g}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
