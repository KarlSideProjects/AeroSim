# AirSim reference audit for #145

AirSim reference: `v1.8.1` at `96235148a332fe7cb3d3525a0720e26faaca99e0` in the read-only sibling checkout.

## Paths and symbols

- `AirLib/include/common/AirSimSettings.hpp`: `MavLinkConnectionInfo`, `MavLinkVehicleSetting`, and `createMavLinkVehicleSetting`; transport defaults and `UseSerial`, `UdpIp`, `UdpPort`, `UseTcp`, `TcpPort`, `LockStep`, `ControlIp`, `ControlPortLocal`, `ControlPortRemote`, `LocalHostIp`, `SitlIp`, and `SitlPort` parsing.
- `AirLib/include/vehicles/multirotor/firmwares/mavlink/MavLinkMultirotorApi.hpp`: `MavLinkMultirotorApi`, `initialize`, `startOffboardMode`, `normalizeRotorControls`, control-channel retry, and heartbeat/control message handling.
- `AirLib/include/vehicles/multirotor/firmwares/mavlink/Px4MultiRotorParams.hpp`: PX4 multirotor API construction and vehicle parameter boundary.
- `docs/px4_setup.md`: `VehicleType=PX4Multirotor`, `SteppableClock`, lockstep, TCP/UDP ports, sensor requirements, and PX4 parameter guidance.
- `PythonClient/airsim/client.py`: PX4 multirotor command surface and state payload names.

The AeroSim implementation keeps `AirSimSession.simulation_time_seconds` as the sensor clock, reuses `AirSimCoordinateContract` for NED/FRD/SI conversion, and routes actuator values through `step_per_motor_physics_frame` and `CollisionAuthoritySwitch`. It does not copy AirSim source or create a second physics world.

## Issue searches and disposition

Searches were run against all Microsoft AirSim issues with `gh issue list --repo microsoft/AirSim --state all --search` and relevant issue bodies/comments were reviewed:

| Query | Relevant issue | Disposition |
|---|---|---|
| `PX4Multirotor` | [#4986](https://github.com/microsoft/AirSim/issues/4986), [#3984](https://github.com/microsoft/AirSim/issues/3984), [#4722](https://github.com/microsoft/AirSim/issues/4722) | Keep one explicit PX4 vehicle identity in this slice; reject unsupported multi-vehicle transport rather than conflating ports. |
| `ControlPort PX4` | [#2964](https://github.com/microsoft/AirSim/issues/2964), [#3415](https://github.com/microsoft/AirSim/issues/3415), [#2986](https://github.com/microsoft/AirSim/pull/2986) | Bind and report TCP/UDP failures explicitly; retain a control retry/heartbeat diagnostic instead of silently switching controllers. |
| `LockStep PX4` | [#4524](https://github.com/microsoft/AirSim/issues/4524), [#3415](https://github.com/microsoft/AirSim/issues/3415), [#4190](https://github.com/microsoft/AirSim/issues/4190) | Preserve lockstep as a checked setting and fail stale when PX4 stops heartbeating; all HIL timestamps use session time. |
| `takeoff PX4` | [#3143](https://github.com/microsoft/AirSim/issues/3143), [#4036](https://github.com/microsoft/AirSim/issues/4036), [#3820](https://github.com/microsoft/AirSim/issues/3820) | Keep arm/mission preconditions and actionable command failure; no SimpleFlight fallback on PX4 command rejection. |
| `SteppableClock PX4` | [#4190](https://github.com/microsoft/AirSim/issues/4190), [#4756](https://github.com/microsoft/AirSim/issues/3984) | Drive sensor publication from the deterministic session clock and expose heartbeat/actuator freshness diagnostics. |
| `OriginGeopoint PX4` | [#4960](https://github.com/microsoft/AirSim/issues/4960), [#5018](https://github.com/microsoft/AirSim/issues/5018) | Preserve the existing origin/NED contract and surface GPS/preflight connection failures instead of claiming estimator readiness. |

The upstream reports are compatibility and operational evidence, not copied implementation. ArduCopter-specific [#4144](https://github.com/microsoft/AirSim/issues/4144) remains out of scope because this issue is PX4Multirotor SITL only.

## License and attribution

No AirSim source code was copied or adapted. AirSim is MIT-licensed; this repository uses the pinned checkout only as a behavioral and naming reference. No runtime or build dependency on the checkout is introduced.

## AeroSim tests derived from the audit

- `tests/gut/test_airsim_settings.gd` verifies PX4 transport keys, unsupported serial/HITL, and port validation.
- `tests/gut/test_px4_sitl_bridge.gd` verifies deterministic heartbeat state transitions, stale/failure authority release, NED/FRD setpoints, and arm/takeoff/waypoint/hover/land/disarm.
- `tests/native/test_px4_actuator.cpp` verifies deterministic per-motor thrust and no mutation after invalid actuator output.
- `tests/headless/px4_sitl_smoke.gd` verifies the fake mission finishes disarmed.
- `scripts/test_px4_sitl_launcher.sh --check` verifies the pinned PX4 revision and clean launcher contract; `--run` requires a real mission command and fails explicitly when unavailable.
