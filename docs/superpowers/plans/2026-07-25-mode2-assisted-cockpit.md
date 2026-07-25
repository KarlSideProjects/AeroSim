# Mode 2 Assisted Cockpit Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver canonical Xbox Mode 2 controls, Assisted Hold, telemetry-driven rotor visualization, and the persistent three-column Player Mode cockpit from issue #201.

**Architecture:** `GamepadProfile` remains the sole source of normalized controller semantics. `FlightRuntime` translates those semantics into native flight-control commands and owns the responsive cockpit; native control keeps noisy sensor-derived hold state and collision-safe authority handoff. The existing telemetry snapshot remains the sole source for the rotor graphic.

**Tech Stack:** Godot 4.7 GDScript, C++17 GDExtension, GUT, native standalone tests, headed acceptance, GitHub Actions.

## Global Constraints

- Mode 2 is fixed: Left X Yaw, Left Y climb/throttle, Right X Roll, Right Y Pitch; raw deadzone is `0.08`.
- Assisted tilt is `30°`, yaw rate is `120°/s`; pure Angle and ACRO retain their defined behavior.
- Hold logic uses noisy internal observations, never direct position freezing.
- HUD visuals consume normalized input or native telemetry only.
- Player Mode defaults to 1920×900; 1280×720, 1280×800, 1920×900 and 1920×1080 remain readable with the central third unobscured.
- No new dependencies; localization covers zh-TW and English.

---

### Task 1: Canonical Mode 2 profile (#202)

**Files:**
- Modify: `common/flight/input_profiles.gd`, `common/flight/flight_runtime.gd`
- Modify: `tests/gut/test_input_profiles.gd`, `tests/gut/test_flight_runtime_load.gd`, `common/smoke/headless_smoke.gd`

- [ ] Write focused failing tests for the Mode 2 axis table, schema rejection of the prior profile, shared deadzone/response curve, and normalized Channel Monitor values.
- [ ] Run the focused GUT tests and verify each failure reports the old mapping or linear curve.
- [ ] Implement the schema bump, canonical mapping, central soft response curve, and all call-site semantic updates.
- [ ] Re-run the focused GUT tests and smoke verification; commit the green slice.

### Task 2: Telemetry-derived 2.5D rotor diagram (#203)

**Files:**
- Modify: `common/flight/status_diagram_debug.gd`, `common/flight/flight_runtime.gd`, `common/flight/hardware_config.gd`
- Modify: relevant GUT and headed acceptance tests

- [ ] Write failing state tests for RPM phase progression, config-derived spin direction, thrust/saturation appearance data, and stale/unavailable telemetry.
- [ ] Run those tests and verify the current text-grid state cannot satisfy them.
- [ ] Implement a compact `Control`-drawn rotor diagram backed by the existing motor HUD state and hardware spin directions.
- [ ] Verify the focused tests and headed geometry; commit the green slice.

### Task 3: Assisted vertical, heading, and horizontal hold (#205–#207)

**Files:**
- Modify: `src/native/aerosim_flight_control.hpp`, `src/native/aerosim_flight_control.cpp`, `src/native/aerosim_native.cpp`
- Modify: `common/flight/flight_runtime.gd`, `common/flight/replay_integration_runner.gd`
- Modify: `tests/native/test_flight_control.cpp`, `tests/native/test_replay.cpp`, relevant GUT/headless coverage

- [ ] Write failing native tests for velocity-command altitude capture, heading capture, body-relative position braking/hold, safe landing disarm, and deterministic replay state.
- [ ] Run the narrow native tests and verify the existing altitude-only controller fails those behaviors.
- [ ] Add the minimal assisted controller state and native binding surface; route FlightRuntime only through that surface while preserving collision authority handoff.
- [ ] Re-run native, replay, and headless flight-flow tests; commit the green slice.

### Task 4: Xbox controller diagram and responsive cockpit (#204, #208)

**Files:**
- Modify: `common/flight/flight_runtime.gd`, `project.godot`, `locales/ui.csv`
- Modify: `tests/gut/test_flight_runtime_load.gd`, `tests/headed/headed_acceptance.gd`, `common/smoke/headless_smoke.gd`

- [ ] Write failing tests for injected stick-dot state, connection/mode labels, persistent panel geometry, and localized visible labels.
- [ ] Run the focused tests and verify current HUD has no graphical controller/cockpit contract.
- [ ] Implement the container-based three-column layout and an immediate-mode controller diagram sharing `GamepadProfile` normalized values.
- [ ] Re-run GUT, headed and localization checks; commit the green slice.

### Task 5: Product documentation and full verification

**Files:**
- Modify: `PRD_AeroSim.md`, release/issue evidence as needed

- [ ] Carry the v4.1.9 approved requirements into the branch.
- [ ] Run native, hardcoded-airframe, license, Python, headless smoke, headed acceptance, and the repository's issue-11 Linux gate.
- [ ] Fix any regressions with a fresh narrow failing test first.
- [ ] Push the branch, open a PR linked to #201 and #202–#208, wait for required CI, merge, and verify the merged commit is on the default branch.
