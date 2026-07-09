# Python Oracle Framework

This is the CI-A pattern for aerodynamic formula ports.

## A3 Drag

`tests/native/test_aerodynamics.cpp` writes C++ A3 drag cases when
`AEROSIM_A3_ORACLE_CASES` is set. `scripts/check_a3_oracle.py` reads those
cases and recomputes the same points with the gym-pybullet-drones
`BaseAviary._drag` formula:

```text
drag_factors = -DRAG_COEFF * sum(2*pi*rpm/60)
drag = dot(base_rot.T, drag_factors * world_velocity)
```

CI fails if any C++ force component differs from the Python oracle by more than
`1e-6`.

## Adding The Next Effect

For #30, reuse the same shape:

1. Add the smallest public native function for the effect.
2. Add one native test that writes oracle CSV rows behind an env var.
3. Add one `scripts/check_<effect>_oracle.py` that computes the original Python
   formula and fails on the frozen tolerance.
4. Wire the script into CI immediately after `scripts/test_native.sh`.

Keep case files under `build/`; CI workspaces may be cleaned between jobs.
