# TelemetrySnapshot schema

`TelemetrySnapshot` is the native physics-to-UI contract for the debug drone
status diagram. The native flight controller publishes it through a 30 Hz
double buffer; UI code reads only `AeroSimNative.telemetry_snapshot()` and must
not poll substep state.

Schema version: `1`

Coordinate frame: body FRD (`+X` forward, `+Y` right, `+Z` down)

Motor order: Betaflight quad-X 1-4:

1. `rear_right`
2. `front_right`
3. `rear_left`
4. `front_left`

Frozen fields:

- `timestamp_us`: simulation time in microseconds.
- `schema_version`: snapshot schema version.
- `snapshot_hz`: native publish rate, currently 30 Hz.
- `publish_count`: number of native snapshot swaps.
- `coordinate_frame`: `FRD`.
- `motor_order`: Betaflight order above.
- `motors[4]`: `{ thrust_newtons, speed_rad_s, current_a, saturated }`.
- `wind_world_mps`, `wind_body_mps`: wind vectors.
- `turbulence_intensity`.
- `ground_effect_gain`.
- `downwash_force_n`.
- `propwash_disturbance_rad_s2`.
- `drag_body_n`.
- `battery`: `{ voltage_v, sag_v, remaining_mah }`.
- `pid[3]`: pitch/yaw/roll `{ output, saturated }`.
- `armed`.
- `mode`.

For the phase-one debug UI, motor thrust, rad/s speed, current, voltage sag, armed/mode,
wind vector, and PID saturation are displayed. Effects that do not yet have a
runtime model publish zero instead of decorative or inferred values.
