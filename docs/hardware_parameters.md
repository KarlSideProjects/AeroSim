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
- `aircraft`: AUW, inertia diagonal, center-of-gravity offset, four motor positions.
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
