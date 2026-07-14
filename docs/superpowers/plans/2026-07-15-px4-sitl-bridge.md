# PX4 SITL Bridge Implementation Plan
> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` or `superpowers:executing-plans` when delegating or executing this plan.

**Goal:** Add a deterministic, AirSim-compatible PX4Multirotor SITL path that uses the existing session clock, native motor physics, and NED/FRD contract, with explicit diagnostics and no SimpleFlight fallback.

**Architecture:** `Px4SitlBridge` owns PX4 transport state and MAVLink messages. `FlightRuntime` owns simulation time, sensor snapshots, command routing, and authority pause/resume. A fake transport provides deterministic GUT/headless coverage; PacketPeer TCP/UDP provides the Ubuntu PX4 path. Native code exposes the existing per-motor integrator through one narrow binding.

**Tech Stack:** Godot 4.7 GDScript, C++17 GDExtension, MAVLink v1 framing for the required heartbeat/sensor/actuator/command messages, shell launcher, GUT/headless tests, native standalone tests.

## Global Constraints

- Work only in `/home/karl/Workspace/Toys/AeroSim-wt/issue-145-px4-sitl`.
- Preserve NED positions/velocities, FRD body axes, SI units, deterministic simulation time, and the existing hardware configuration path.
- Keep the PX4 bridge independent of wall-clock simulation time; transport polling may use wall time only for connection diagnostics and timeout detection.
- Reject unsupported serial/HITL configuration explicitly and never silently substitute SimpleFlight.
- Keep all tests deterministic and make missing real-PX4 prerequisites fail with actionable diagnostics.
- Record AirSim reference paths, symbols, issue findings, license disposition, and derived tests in `docs/research/airsim_reference_audit_145.md`.

## Task 1: Freeze the contract with failing tests

**Files:** `tests/gut/test_px4_sitl_bridge.gd`, `tests/gut/test_airsim_settings.gd`, `tests/headless/px4_sitl_smoke.gd` or the existing headless test entry point.

1. Add tests for PX4 settings defaults and validation: PX4Multirotor accepts TCP/UDP and lockstep settings, `UseSerial=true` is rejected, invalid ports are rejected, and required control endpoints are reported.
2. Add deterministic fake-transport tests for `starting → connected → armed → stale → failed`, heartbeat/actuator freshness, authority pause on stale/failed, NED/FRD setpoints, and the complete arm/takeoff/waypoint/hover/land/disarm sequence.
3. Add a headless smoke assertion that a configured PX4 fake mission reports the final disarmed state and never changes the vehicle type to SimpleFlight.
4. Run the narrow GUT/headless command and confirm the new tests fail because the bridge and settings surface do not yet exist.

## Task 2: Add PX4 settings and deterministic bridge

**Files:** `common/flight/airsim_settings.gd`, `common/flight/flight_runtime.gd` only where integration is required, `common/rpc/px4_sitl_bridge.gd`, `config/airsim_compatibility_manifest.json`.

1. Extend the settings subset with the PX4 transport keys used by the pinned AirSim behavior: `UseSerial`, `UseTcp`, `TcpPort`, `ControlIp`, `ControlPortLocal`, `ControlPortRemote`, `LockStep`, `LocalHostIp`, `UdpIp`, and `UdpPort`.
2. Implement one small `Px4SitlBridge` with typed configuration, explicit state/diagnostics, injectable fake transport, and real `PacketPeerStream`/`PacketPeerUDP` transport adapters.
3. Implement only the MAVLink messages needed for this issue: heartbeat, HIL sensor/GPS input, actuator output reception, command-long arm/disarm, and the mission setpoint/land commands. Validate frames and CRC before consuming them.
4. Timestamp all simulated sensor messages from `AirSimSession.simulation_time_seconds`; use the existing `AirSimCoordinateContract` for NED/FRD conversion.
5. Apply heartbeat and actuator freshness timeouts; transition to `stale`/`failed`, publish an actionable diagnostic, and invoke the authority callback so `FlightRuntime` pauses PX4 authority.
6. Keep the fake transport deterministic and expose enough diagnostics for tests and the operations dashboard without adding a new abstraction layer.

## Task 3: Wire runtime commands and native actuator physics

**Files:** `common/flight/flight_runtime.gd`, `src/native/aerosim_native.hpp`, `src/native/aerosim_native.cpp`, `src/native/aerosim_simulation.hpp`, `src/native/aerosim_collision.hpp`, `src/native/aerosim_collision.cpp`, `tests/native/test_px4_actuator.cpp`.

1. Configure the bridge only when `VehicleType` is `PX4Multirotor`; surface startup failure and do not invoke SimpleFlight controls for that vehicle.
2. Route arm/disarm/takeoff/waypoint/hover/land through the bridge while retaining the AirSim RPC command surface and shared command validation.
3. Add one native `step_px4_actuator_mode` binding that clamps four normalized motor outputs, calls `step_per_motor_physics_frame`, and returns the same deterministic body-state row used by runtime integration.
4. Preserve shared collision authority/world handling for actuator frames; add the smallest per-motor collision handoff needed by the existing collision switch, with no duplicate physics implementation.
5. Add a native behavior test for deterministic thrust, input clamping, and invalid actuator input handling.
6. Add PX4 state/diagnostic fields to the existing runtime/HUD status surface so disconnected, stale, and failed states are actionable.

## Task 4: Add launcher, audit, and fast qualification checks

**Files:** `scripts/run_px4_sitl_mission.sh`, `scripts/test_px4_sitl_launcher.sh`, `docs/research/airsim_reference_audit_145.md`, `.github/workflows/*` only if an existing Linux workflow has a safe PX4 hook.

1. Pin one PX4 source revision, clone/fetch only under `build/px4`, verify the checked-out revision, launch `make px4_sitl none_iris`, and fail explicitly when the binary, source, or required network endpoints are unavailable.
2. Keep the launcher’s fast mode dependency-free: verify the pin, settings, clean environment, and command line without starting PX4.
3. Add a real-run mode that emits machine-readable diagnostics and returns nonzero on connection, heartbeat, actuator, mission, or final-disarm failure.
4. Document the exact AirSim reference symbols and paths, upstream issue searches and dispositions, MIT/no-copying license result, and tests derived from the audit.
5. Add only an existing-workflow PX4 gate if it can run from a configured cache/environment; do not make ordinary CI silently download or fake PX4.

## Task 5: Verify, review, publish, and close

1. Run focused tests, `scripts/test_native.sh`, settings/constant/license tests, GUT, headless smoke, and launcher validation.
2. Run the available real PX4 mission qualification; if the external PX4 prerequisite is absent, retain the explicit failing diagnostic and do not claim that acceptance criterion as passed.
3. Run an independent adversarial review with fresh context and fix all Critical/High findings.
4. Commit focused changes, push the branch, open a PR linked to #145, wait for hosted checks, rebase if needed, squash-merge only after green checks, and verify the merged result.
5. Close #145 with the required triage-prefixed evidence comment, update labels, and claim the next unlocked issue only after confirming its dependencies and scope.

## Verification Commands

```text
scripts/test_px4_sitl_launcher.sh
scripts/test_native.sh
scripts/check_hardcoded_airframe_constants.sh
scripts/test_license_scan.sh
GODOT_BIN=... scripts/run_gut_tests.sh --recovery-mode
GODOT_BIN=... scripts/run_headless_smoke.sh --output build/headless_smoke.json --frames 5
```

Self-review: all tasks name concrete files and commands; no placeholder wording or unowned integration step remains. The real-PX4 prerequisite is intentionally explicit so missing infrastructure cannot be mistaken for a passing simulation.
