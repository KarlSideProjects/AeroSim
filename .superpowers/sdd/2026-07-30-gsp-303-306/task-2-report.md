# Issue #304 report — PX4 wind-hold authority and MAVLink observability

## Scope and files changed

- `common/rpc/px4_sitl_bridge.gd`: parses only CRC-validated `ATTITUDE`,
  `LOCAL_POSITION_NED`, `ATTITUDE_TARGET`, `POSITION_TARGET_LOCAL_NED`,
  `WIND_COV`, and `HIL_ACTUATOR_CONTROLS`; stores last named samples with
  `px4_mavlink` source, age, and freshness. HIL commands are explicitly M1–M4
  normalized commands, and actuator access fails closed when PX4 authority is
  stale or inactive.
- `common/flight/flight_runtime.gd`: adds the separate `px4_mavlink` block to
  GSP telemetry without relabelling AeroSim kinematics or native motor state.
- `tests/gut/test_px4_sitl_bridge.gd`: validates all supported named payloads,
  CRC rejection, source/age, unavailable torque, M1–M4 command mapping, and
  stale actuator fail-closed behavior.

## Acceptance evidence

- `ATTITUDE`: CRC-valid roll/pitch/yaw and FRD body rates are retained with
  source and age; a corrupted follow-up frame cannot replace the sample.
- `LOCAL_POSITION_NED`, `ATTITUDE_TARGET`, `POSITION_TARGET_LOCAL_NED`, and
  `WIND_COV`: each has a focused valid-frame assertion for the parsed field
  exposed to GSP.
- `HIL_ACTUATOR_CONTROLS`: channel order is exposed only as M1–M4 normalized
  **commands**, never RPM, thrust, current, torque, allocator status, or
  saturation. The last sample remains inspectable after expiry while actuator
  application returns no output.
- Unavailable by design: PX4 body torque, 3-axis body thrust, allocator
  effectiveness/status, explicit saturation, physical N/Nm quantities, and
  any named MAVLink message not in the allowlist.
- Native control is not selected while a PX4 bridge exists; stale/inactive
  bridge output is empty, so it cannot fall back to a native command.

## Commands and results

1. `GODOT_BIN=/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 godot --headless --path . --script res://addons/gut/gut_cmdln.gd -- -gdir=res://tests/gut -gtest=res://tests/gut/test_px4_sitl_bridge.gd -gexit -gdisable_colors`
   - Passed: `test_px4_sitl_bridge.gd` 12/12; GUT overall 312 passing, 11 pre-existing recovery-mode pending. The CLI runs the suite despite `-gtest`.
   - The native extension was absent, so Godot reported its missing library before recovery-mode tests; bridge parsing tests still passed.
2. `GODOT_BIN=/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 scripts/test_px4_sitl_launcher.sh --check --fake-smoke`
   - Passed: pinned launcher contract and fake mission completed/disarmed.
3. `git diff --check`
   - Passed.

## Real PX4 qualification and gaps

No authentic real-PX4 wind-step position-hold test ran and no integration
assertion was fabricated. `build/px4/.git` is absent (there is no pinned PX4
checkout at `1dacb4cdef2d7145754fc788fa8dc482eed74b40`) and
`bin/libaerosim_native.linux.template_debug.x86_64.so` is absent. The pinned
Godot binary is available. A real run still requires those two prerequisites;
only then can emitted-message evidence and a deterministic wind-step hold
limit be qualified.

No #302, #305, or #306 implementation was changed. #303's authoritative wind
event was consumed only through the existing runtime wind path; no #303 code
was modified.

## Commit

`392128d feat: expose validated PX4 MAVLink telemetry (#304)`
