"""Load the hash-verified, versioned gym-pybullet-drones oracle cache."""

import hashlib
import json
import re
import sys
import types
from pathlib import Path, PurePosixPath


ROOT = Path(__file__).resolve().parents[1]
CONTRACT_PATH = ROOT / "oracles" / "gym_pybullet_drones_contract.json"
CACHE_ROOT = ROOT / "oracles" / "gym_pybullet_drones_cache"
REQUIRED_FIELDS = ("repository_url", "commit", "path", "sha256")
CANONICAL_REPOSITORY_URL = "https://github.com/learnsyslab/gym-pybullet-drones"


def load_pinned_oracle(contract_path=CONTRACT_PATH, cache_root=CACHE_ROOT):
    """Return numpy, a PyBullet stub, and BaseAviary from the verified cache."""
    try:
        import numpy as np
    except Exception as exc:
        raise RuntimeError("missing numpy required by pinned BaseAviary oracle") from exc

    contract_path = Path(contract_path)
    cache_root = Path(cache_root)
    try:
        contract = json.loads(contract_path.read_text(encoding="utf-8"))
    except FileNotFoundError as exc:
        raise RuntimeError(f"pinned oracle contract missing: {contract_path}") from exc
    except (OSError, json.JSONDecodeError) as exc:
        raise RuntimeError(f"pinned oracle contract is unreadable: {contract_path}") from exc

    if not isinstance(contract, dict) or any(not isinstance(contract.get(field), str) for field in REQUIRED_FIELDS):
        raise RuntimeError(f"pinned oracle contract is invalid: {contract_path}")
    if contract["repository_url"] != CANONICAL_REPOSITORY_URL:
        raise RuntimeError(f"pinned oracle contract has non-canonical repository URL: {contract_path}")
    if not re.fullmatch(r"[0-9a-f]{40}", contract["commit"]):
        raise RuntimeError(f"pinned oracle contract has invalid commit: {contract_path}")
    if not re.fullmatch(r"[0-9a-f]{64}", contract["sha256"]):
        raise RuntimeError(f"pinned oracle contract has invalid SHA-256: {contract_path}")

    source_path = PurePosixPath(contract["path"])
    if source_path.is_absolute() or ".." in source_path.parts:
        raise RuntimeError(f"pinned oracle contract has invalid source path: {contract_path}")
    cache_path = cache_root / contract["commit"] / source_path
    try:
        source_bytes = cache_path.read_bytes()
    except FileNotFoundError as exc:
        raise RuntimeError(f"pinned oracle cache missing: {cache_path}") from exc
    except OSError as exc:
        raise RuntimeError(f"pinned oracle cache is unreadable: {cache_path}") from exc

    actual_hash = hashlib.sha256(source_bytes).hexdigest()
    if actual_hash != contract["sha256"]:
        raise RuntimeError(
            "pinned oracle cache SHA-256 mismatch: "
            f"expected {contract['sha256']}, got {actual_hash} for {cache_path}"
        )
    try:
        source = source_bytes.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise RuntimeError(f"pinned oracle cache is not UTF-8: {cache_path}") from exc

    pybullet = types.ModuleType("pybullet")
    pybullet.LINK_FRAME = 1
    pybullet.applyExternalForce = lambda *args, **kwargs: None

    def get_matrix_from_quaternion(quaternion):
        x, y, z, w = quaternion
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
        namespace = {"__name__": "aerosim_pinned_base_aviary"}
        exec(compile(source, str(cache_path), "exec"), namespace)
    except Exception as exc:
        raise RuntimeError(f"failed to load pinned BaseAviary.py from cache: {cache_path}") from exc
    finally:
        for name, module in previous.items():
            if module is None:
                sys.modules.pop(name, None)
            else:
                sys.modules[name] = module

    base_aviary = namespace.get("BaseAviary")
    required_methods = ("_drag", "_groundEffect", "_downwash")
    if base_aviary is None or any(not hasattr(base_aviary, method) for method in required_methods):
        raise RuntimeError("pinned BaseAviary.py cache does not expose A3/A4/A5 oracle methods")
    return np, pybullet, base_aviary
