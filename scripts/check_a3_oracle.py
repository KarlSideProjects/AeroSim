#!/usr/bin/env python3
"""Compare C++ A3 drag cases with the pinned gym-pybullet-drones oracle."""

import csv
import sys
import types
import urllib.request
from pathlib import Path


TOLERANCE = 1e-6
UPSTREAM_COMMIT = "9bc12bc583fa3b28807b2f90a8cadf09fb06e1ff"
BASE_AVIARY_URL = (
    "https://raw.githubusercontent.com/utiasDSL/gym-pybullet-drones/"
    f"{UPSTREAM_COMMIT}/gym_pybullet_drones/envs/BaseAviary.py"
)


def load_upstream_oracle():
    try:
        import numpy as np
    except Exception as exc:
        raise RuntimeError("missing numpy required by pinned BaseAviary._drag oracle") from exc

    pybullet = types.ModuleType("pybullet")
    pybullet.LINK_FRAME = 1
    pybullet.applyExternalForce = lambda *args, **kwargs: None

    def get_matrix_from_quaternion(q):
        x, y, z, w = q
        return (
            1.0 - 2.0 * (y * y + z * z),
            2.0 * (x * y - z * w),
            2.0 * (x * z + y * w),
            2.0 * (x * y + z * w),
            1.0 - 2.0 * (x * x + z * z),
            2.0 * (y * z - x * w),
            2.0 * (x * z - y * w),
            2.0 * (y * z + x * w),
            1.0 - 2.0 * (x * x + y * y),
        )

    pybullet.getMatrixFromQuaternion = get_matrix_from_quaternion

    gymnasium = types.ModuleType("gymnasium")
    gymnasium.Env = object

    enum_module = types.ModuleType("gym_pybullet_drones.utils.enums")
    enum_module.DroneModel = types.SimpleNamespace(CF2X="cf2x", RACE="race")
    enum_module.Physics = types.SimpleNamespace(PYB="pyb")
    enum_module.ImageType = types.SimpleNamespace(RGB="rgb", DEP="dep", SEG="seg")

    stubs = {
        "pkg_resources": types.ModuleType("pkg_resources"),
        "pybullet": pybullet,
        "pybullet_data": types.ModuleType("pybullet_data"),
        "gymnasium": gymnasium,
        "PIL": types.ModuleType("PIL"),
        "PIL.Image": types.ModuleType("PIL.Image"),
        "gym_pybullet_drones": types.ModuleType("gym_pybullet_drones"),
        "gym_pybullet_drones.utils": types.ModuleType("gym_pybullet_drones.utils"),
        "gym_pybullet_drones.utils.enums": enum_module,
    }

    previous = {name: sys.modules.get(name) for name in stubs}
    sys.modules.update(stubs)
    try:
        with urllib.request.urlopen(BASE_AVIARY_URL, timeout=30) as response:
            source = response.read().decode("utf-8")
        namespace = {"__name__": "aerosim_pinned_base_aviary"}
        exec(compile(source, BASE_AVIARY_URL, "exec"), namespace)
    except Exception as exc:
        raise RuntimeError(f"failed to load pinned BaseAviary.py from {BASE_AVIARY_URL}") from exc
    finally:
        for name, module in previous.items():
            if module is None:
                sys.modules.pop(name, None)
            else:
                sys.modules[name] = module

    BaseAviary = namespace.get("BaseAviary")
    if BaseAviary is None or not hasattr(BaseAviary, "_drag"):
        raise RuntimeError("pinned BaseAviary.py does not expose BaseAviary._drag")
    return np, pybullet, BaseAviary


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
        np, p, BaseAviary = load_upstream_oracle()
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
