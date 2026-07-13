# Python Oracle Framework

This is the CI-A pattern for aerodynamic formula ports. Python is a development
and test oracle only: it is not a runtime dependency and never becomes a second
collision authority.

## Pinned Source Contract And Offline Cache

`oracles/gym_pybullet_drones_contract.json` is the single version-controlled
contract record for the Python oracle source. It fixes the canonical repository
URL `https://github.com/learnsyslab/gym-pybullet-drones`, commit
`9bc12bc583fa3b28807b2f90a8cadf09fb06e1ff`, exact source path
`gym_pybullet_drones/envs/BaseAviary.py`, and its SHA-256
`2f27256e8431886ca61a16e4a12300411be4c46599ca1e753386423fec0dbee8`.

The corresponding bytes are version-controlled at
`oracles/gym_pybullet_drones_cache/<commit>/<path>`. Both oracle scripts call
`scripts/pinned_oracle.py`, which reads that one contract, locates the cache,
verifies SHA-256 before loading, then executes the verified source. The default
CI path never downloads this source and has no network fallback, so a cached CI
run remains valid without network access. A missing contract/cache or an invalid
or mismatched hash fails loudly and identifies the failing artifact.

#116 owns MIT attribution and NOTICE work. This cache contract identifies the
upstream source for oracle verification only; it neither completes nor replaces
#116's attribution boundary.

## A3 Drag

`tests/native/test_aerodynamics.cpp` writes C++ A3 drag cases when
`AEROSIM_A3_ORACLE_CASES` is set. `scripts/check_a3_oracle.py` reads those
cases and recomputes the same points by loading the hash-verified cached
`gym-pybullet-drones` `BaseAviary.py` source and calling `BaseAviary._drag`:

```text
drag_factors = -DRAG_COEFF * sum(2*pi*rpm/60)
drag = dot(base_rot.T, drag_factors * world_velocity)
```

CI fails if any C++ force component differs from the Python oracle by more than
`1e-6`.

## A4 Ground Effect / A5 Downwash

`tests/native/test_aerodynamics.cpp` writes A4/A5 cases when
`AEROSIM_A4_A5_ORACLE_CASES` is set. `scripts/check_a4_a5_oracle.py` loads the
same hash-verified cached `BaseAviary.py` and calls `BaseAviary._groundEffect` and
`BaseAviary._downwash`; CI fails if any force differs by more than `1e-6`.

## Adding The Next Effect

For #30, reuse the same shape:

1. Add the smallest public native function for the effect.
2. Add one native test that writes oracle CSV rows behind an env var.
3. Add one `scripts/check_<effect>_oracle.py` that calls the pinned upstream
   Python implementation and fails on the frozen tolerance.
4. Wire the script into CI immediately after `scripts/test_native.sh`.

Keep case files under `build/`; CI workspaces may be cleaned between jobs.
