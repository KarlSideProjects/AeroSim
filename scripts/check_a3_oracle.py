#!/usr/bin/env python3
"""Compare C++ A3 drag cases with the gym-pybullet-drones drag oracle."""

import csv
import math
import sys
from pathlib import Path


TOLERANCE = 1e-6


def multiply(a, b):
    ax, ay, az, aw = a
    bx, by, bz, bw = b
    return (
        aw * bx + ax * bw + ay * bz - az * by,
        aw * by - ax * bz + ay * bw + az * bx,
        aw * bz + ax * by - ay * bx + az * bw,
        aw * bw - ax * bx - ay * by - az * bz,
    )


def rotate_inverse(q, v):
    qx, qy, qz, qw = q
    return multiply(multiply((-qx, -qy, -qz, qw), (*v, 0.0)), q)[:3]


def python_original_drag(row):
    # Formula copied from gym-pybullet-drones BaseAviary._drag:
    # drag_factors = -DRAG_COEFF * sum(2*pi*rpm/60)
    # drag = dot(base_rot.T, drag_factors * world_velocity)
    coeff = (float(row["coeff_x"]), float(row["coeff_y"]), float(row["coeff_z"]))
    rpm = [float(row[f"rpm_{index}"]) for index in range(4)]
    q = tuple(float(row[key]) for key in ("qx", "qy", "qz", "qw"))
    velocity = tuple(float(row[key]) for key in ("vx", "vy", "vz"))
    body_velocity = rotate_inverse(q, velocity)
    rotor_speed_sum = sum(2.0 * math.pi * value / 60.0 for value in rpm)
    return tuple(-axis_coeff * rotor_speed_sum * axis_velocity for axis_coeff, axis_velocity in zip(coeff, body_velocity))


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: check_a3_oracle.py build/a3_oracle_cases.csv", file=sys.stderr)
        return 2

    path = Path(sys.argv[1])
    if not path.is_file():
        print(f"A3 oracle cases not found: {path}", file=sys.stderr)
        return 1

    with path.open(newline="", encoding="utf-8") as handle:
        rows = list(csv.DictReader(handle))
    if not rows:
        print("A3 oracle cases file is empty", file=sys.stderr)
        return 1

    for row in rows:
        expected = python_original_drag(row)
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
