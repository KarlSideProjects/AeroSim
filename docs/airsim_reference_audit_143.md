# AirSim reference audit for issue #143

AirSim reference: `v1.8.1` at `96235148a332fe7cb3d3525a0720e26faaca99e0` in the read-only sibling checkout `../AirSim-reference`.

## Paths and symbols inspected

- `AirLib/src/api/RpcLibServerBase.cpp`: the RPC bindings pass `vehicle_name` to `enableApiControl`, `armDisarm`, `simGetImages`, state, collision, camera, IMU, GPS, barometer, magnetometer, and lidar handlers. AeroSim keeps that identity on every backend path and rejects an empty or unknown name when two vehicles are configured.
- `PythonClient/airsim/client.py`: the client methods expose `vehicle_name` as a per-call argument, including command, state, image, and sensor calls. This is the compatibility shape used by the isolation tests.
- `AirLib/include/common/AirSimSettings.hpp`: vehicle settings are keyed by configured vehicle name. AeroSim limits the existing Lab Mode slice to two named vehicles and validates names before constructing per-vehicle contexts.
- `AirLib/include/api/RpcLibAdaptorsBase.hpp`: image and sensor adaptor payloads are transport data only; no AirSim scene or rendering code was copied.

## Issue searches and disposition

Queries run with `gh issue list --repo microsoft/AirSim --state all --search` included `vehicle_name`, `multi vehicle`, `downwash`, and `propwash`.

| Upstream issue | State | Relevance and AeroSim decision |
|---|---|---|
| [#2965](https://github.com/microsoft/AirSim/issues/2965) | open | Unknown vehicle API behavior remains a reported gap. AeroSim makes unknown names an explicit error. |
| [#1220](https://github.com/microsoft/AirSim/issues/1220) | closed | Empty `vehicle_name` behavior was discussed upstream. AeroSim retains the single-vehicle compatibility fallback only when no named fleet is configured; a two-vehicle session requires a non-empty name. |
| [#2974](https://github.com/microsoft/AirSim/issues/2974) | closed | Independent multi-drone schedules support keeping command state per vehicle. AeroSim adds behavior-focused no-cross-talk coverage. |
| [#2791](https://github.com/microsoft/AirSim/issues/2791) | closed | Multi-vehicle state synchronization is relevant to a shared simulation clock. AeroSim advances both named sensor streams from the same session time while sampling each vehicle state separately. |
| [#2971](https://github.com/microsoft/AirSim/issues/2971) | closed | Multi-drone API call ordering reinforces explicit name routing. |
| [#1772](https://github.com/microsoft/AirSim/issues/1772) | closed | Multi-vehicle camera/segmentation behavior is relevant; AeroSim resolves camera source and body by vehicle name. |
| [#4816](https://github.com/microsoft/AirSim/issues/4816) | open | Unity multi-drone image limitations are not adopted; AeroSim's camera surface is a Godot implementation with per-vehicle source cameras. |
| [#3033](https://github.com/microsoft/AirSim/issues/3033) | open | View switching remains an upstream concern; AeroSim keeps dashboard and chase-camera identity explicit. |
| [#2134](https://github.com/microsoft/AirSim/issues/2134) | closed | Vehicle/world collision concerns are addressed in AeroSim by keeping both bodies in one Godot physics world. |

The `downwash` and `propwash` searches returned no applicable AirSim issue or reusable AirSim core implementation. The A5 relative-state model used here is existing AeroSim behavior from the prior downwash work, evaluated in the native per-substep dual-aircraft path; no AirSim source was adapted for it.

## License disposition

AirSim v1.8.1 is MIT-licensed. This change copies no AirSim source, assets, or binaries, so no new adapted-code notice is required. The reference is used only for observable RPC naming, argument routing, and settings semantics.

## Tests derived from the audit

- `tests/gut/test_airsim_rpc_server.gd`: two named vehicles retain independent API-control and command routing; empty and unknown names fail explicitly.
- `tests/gut/test_airsim_settings.gd`: duplicate, empty, missing, and unknown vehicle-name validation.
- `tests/gut/test_airsim_sensor_suite.gd`: per-vehicle sensor streams sample their own state at a shared session time.
- `tests/gut/test_flight_runtime_named_controls.gd`: secondary velocity and yaw control reads secondary measured state.
- `tests/native/test_replay.cpp`: replay recordings carry vehicle identity.
- `common/smoke/headless_smoke.gd`: public A5 source-position path checks effects-off zero and effects-on crossing trajectory loss.
- Existing native dual-aerodynamics tests cover A5 effects-off zero, crossing-trajectory loss, and per-substep sensitivity.

## Explicit partials

The operations dashboard now selects between the available named telemetry snapshots. Runtime vehicle state, sensor samples, and every camera image response header expose an `aerosim_identity.vehicle_name` metadata hook; replay sequences retain escaped vehicle identity metadata. These are dataset-facing metadata only, not a full dataset writer/export pipeline, which remains follow-up scope. No synthetic dashboard or dataset data was added.
