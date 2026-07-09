# Python Oracle Framework

This is the CI-A pattern for aerodynamic formula ports.

## A3 Drag

`tests/native/test_aerodynamics.cpp` writes C++ A3 drag cases when
`AEROSIM_A3_ORACLE_CASES` is set. `scripts/check_a3_oracle.py` reads those
cases and recomputes the same points by loading the pinned
`gym-pybullet-drones` `BaseAviary.py` source and calling `BaseAviary._drag`
from commit
`9bc12bc583fa3b28807b2f90a8cadf09fb06e1ff`:

```text
drag_factors = -DRAG_COEFF * sum(2*pi*rpm/60)
drag = dot(base_rot.T, drag_factors * world_velocity)
```

CI fails if any C++ force component differs from the Python oracle by more than
`1e-6`.

## A4 Ground Effect / A5 Downwash

`tests/native/test_aerodynamics.cpp` writes A4/A5 cases when
`AEROSIM_A4_A5_ORACLE_CASES` is set. `scripts/check_a4_a5_oracle.py` loads the
same pinned `BaseAviary.py` and calls `BaseAviary._groundEffect` and
`BaseAviary._downwash`; CI fails if any force differs by more than `1e-6`.

## Adding The Next Effect

For #30, reuse the same shape:

1. Add the smallest public native function for the effect.
2. Add one native test that writes oracle CSV rows behind an env var.
3. Add one `scripts/check_<effect>_oracle.py` that calls the pinned upstream
   Python implementation and fails on the frozen tolerance.
4. Wire the script into CI immediately after `scripts/test_native.sh`.

Keep case files under `build/`; CI workspaces may be cleaned between jobs.
