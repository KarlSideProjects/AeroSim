# Hardware Parameter Schema

This document is the human-readable contract for #20 / G1.7. The machine
schema lives in `config/drone_schema.json`; presets live in `config/drones/`.

## Coordinate Frames

- World frame: Godot coordinates, Y-up.
- Body frame: FRD for physical parameters: +X forward, +Y right, +Z down.
- Motor positions are body-frame meters relative to center of gravity.

## Motor Order

Motor order follows the Betaflight quad-X convention:

1. Rear right
2. Front right
3. Rear left
4. Front left

Spin direction must be explicit per motor as `cw` or `ccw`.

## Required Categories

Every drone preset must define these top-level categories:

- `frame`: wheelbase, arm length, dry mass, three-axis frontal area.
- `motor`: stator size, KV, winding resistance, max current, first-order time constant, count.
- `propeller`: diameter, pitch, blade count, mass, bench table.
- `battery`: cell count, capacity, C rating, cell resistance, nominal voltage, discharge curve.
- `esc`: current limit, protocol, update rate.
- `aerodynamics`: static A3 switch and three-axis coefficients in `kg`; rotor
  speed is runtime state, never a preset field.
- `aircraft`: AUW, inertia diagonal, center-of-gravity offset, four motor positions.
- `geometry`: airframe identity, presentation-only shell dimensions, and
  geometry provenance. See [GSP drone geometry](gsp_drone_geometry.md).
- `sensors`: gyro rate, IMU noise density, bias drift, random walk, barometer noise.
- `fpv`: camera uptilt and FOV.

All numeric values carry explicit units in the schema or the field name.

## Propeller Table

The propeller bench table is sorted by `rpm` and each row contains:

- `rpm`
- `thrust_n`
- `torque_nm`
- `current_a`

Interpolation is linear inside the table range. Extrapolation is forbidden:
requests below the first `rpm` or above the last `rpm` must fail loudly and
fall back to the factory default where applicable.

## Derived Power Model

Runtime motor thrust is derived from the preset, not from hand-tuned constants.
The loader fits thrust and torque coefficients through the bench table using
least squares over `rpm^2`, then derives:

- hover throttle
- maximum total thrust
- thrust-to-weight ratio
- hover endurance from measured hover current
- first-order motor time constant
- battery loaded-voltage sag from discharge voltage and cell resistance

`apply_to_runtime()` fails loudly if the derived model cannot be produced or if
the native runtime rejects it. Angle Mode uses the derived hover throttle and
thrust cap, so changing the preset changes the native flight behavior without
hardcoding a 5-inch airframe in native code.

## A3 Drag

The A3 coefficient has units of `kg` for the frozen relation
`F = coefficient * rad/s * relative_air_velocity`. Presets currently keep A3
disabled with zero coefficients because no calibrated production coefficient
has been approved. Tests and experimental callers may enable the model through
the native static setter; live rotor speed then comes only from per-motor
thrust state at each physics substep.
