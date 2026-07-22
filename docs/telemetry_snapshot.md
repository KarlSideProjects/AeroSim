# TelemetrySnapshot schema

`TelemetrySnapshot` is the native physics-to-UI contract for the debug drone
status diagram. The native flight controller publishes it through a 30 Hz
double buffer; UI code reads only `AeroSimNative.telemetry_snapshot()` and must
not poll substep state.

Schema version: `2`

World frame: NED. Body frame: FRD (`+X` forward, `+Y` right, `+Z` down). Units: SI.

Motor order: Betaflight quad-X 1-4:

1. `rear_right`
2. `front_right`
3. `rear_left`
4. `front_left`

Frozen fields:

- `timestamp_us`: simulation time in microseconds.
- `schema_version`: snapshot schema version.
- `snapshot_hz`: native publish rate, currently 30 Hz.
- `vehicle_id`, `world_frame`, `body_frame`, `units`.
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
- `air_density_kg_m3` and `airspeed_body_frd_mps_mean`.
- `body_drag_force_body_frd_n_mean` and `body_drag_torque_body_frd_nm_mean`.
- `a3_drag_force_body_frd_n_mean` and `a6_angular_accel_body_frd_rad_s2`.
- `body_drag_operating_state`, `body_drag_evidence_state`, `body_drag_reason_code`, `a3_operating_state`, `a6_operating_state`.
- `config_hash`.
- `battery`: `{ voltage_v, sag_v, remaining_mah }`.
- `pid[3]`: pitch/yaw/roll `{ output, saturated }`.
- `control_authority`, `armed_available`, and `pid_available` identify authority-specific truth.
- `armed`; `null` when external PX4 owns arming and native truth is unavailable.
- `mode`.

The native flight controller publishes applied aerodynamic means from the substeps;
the Debug API panel is a presenter only. Disabled effects retain exact zero vectors
and an explicit `disabled` operating state. Body-drag operating states are limited to
`unavailable`, `disabled`, `active`, and `out_of_domain`; unavailable values are `null`,
not fabricated zeros. Missing or incorrectly typed fields are shown as schema-invalid.
PX4 actuator snapshots retain applied native motor/body-drag values while exposing
unavailable arming and PID fields as `null` instead of borrowing local-controller state.
