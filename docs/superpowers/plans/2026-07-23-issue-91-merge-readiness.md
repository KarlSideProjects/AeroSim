# Issue 91 Merge-Readiness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` task-by-task. Steps use checkbox syntax for tracking.

**Goal:** Make #91 mergeable by completing the FRD four-motor flight loop, atomic failure contract, replay/collision evidence, persistent motor HUD, and exact-artifact Ubuntu gates.

**Architecture:** Keep all control state in FRD and make one named FRD↔Godot boundary. Public native steps stage/restore mutable state and return a status-bearing result. The HUD is a pure, fresh 30 Hz telemetry view that does not affect simulation or replay.

**Tech Stack:** C++17 GDExtension, Godot 4.7 GDScript/GUT, native standalone tests, shell/Python CI helpers.

## Global Constraints

- Ubuntu Linux x86_64 is the only blocking runtime; Betaflight SITL and deferred-platform CI remain out of scope.
- Preserve frozen G2.4/G2.5/G0.6a/G0.8/G0.1 thresholds; never relax a product gate.
- FRD→Godot is exactly `{F,-D,R}` and inverse is `{X,Z,-Y}`; controller state is FRD while public PID telemetry remains `[pitch,yaw,roll]`.
- Quad-X is fixed RR/FR/RL/FL with spins CW/CCW/CCW/CW; do not add a generic allocator.
- All numeric airframe values continue to come from validated hardware configuration/presets.
- Do not copy ArduPilot GPL code, identifiers, or default values.
- Every public step failure is atomic and emits one native error in the exact documented format.
- The motor HUD is a persistent flight-HUD view of existing telemetry, not an OSD element and not a native/replay change.

---

### Task 1: Replace the legacy rate loop with the FRD cascade controller

**Files:**
- Modify: `src/native/aerosim_flight_control.hpp`, `src/native/aerosim_flight_control.cpp`
- Modify: `src/native/aerosim_simulation.hpp`, `src/native/aerosim_simulation.cpp`
- Modify: `tests/native/test_cascaded_flight_control.cpp`, `tests/native/test_flight_control.cpp`, `tests/native/test_quad_x_mixer.cpp`, `tests/native/test_telemetry_snapshot.cpp`

**Interfaces:**
- Replace `previous_target_rates_y_up_` with FRD target-angle, target-rate, I/D/previous-error, mode-family, and saturation state.
- `control_substep` receives/returns FRD values internally; `quad_x_mix_thrust` remains the only physical allocation point.

- [ ] Write failing native tests for the one-way FRD transform, motor-pair signs, coupled `(30,20,10)` quaternion fixture, bidirectional Acro↔Angle reset, shaper overshoot snap, and motor-clamp anti-windup.

```cpp
expect(frd_to_y_up({2,-3,4}) == Vec3{2,-4,-3});
expect(roll_pair_response.angular_velocity.x > 0.0);
expect(coupled_angle_rate_setpoint == Vec3{});
expect(integral_after_saturated_error <= integral_before);
```

- [ ] Run the narrow tests and record their expected RED failures against the legacy Y-up P+I implementation.

Run: `scripts/test_native.sh`

- [ ] Implement the fixed 1 kHz order: validation, family initialization, first-order target shaping, FRD quaternion attitude error, provisional rate PID, Quad-X mix, same-substep anti-windup, motor/rigid-body integration, saturation latch, then telemetry/clock commit.

```cpp
rate_cmd = clamp(wrap_pi(desired - target) / input_tc, -rate_max, rate_max);
target_rate = move_toward(target_rate, rate_cmd, accel_max * dt);
if (crossed_target) { target = desired; target_rate = 0.0; }
```

- [ ] Add shipped 5-inch-6S G2.4/G2.5 tests: 30-degree roll timing/overshoot/settling and 720-degree/s 250 ms reach, 50 ms hold, 500 ms upper-bound behavior. Preserve the 30 Hz public PID ordering and saturation latch.
- [ ] Run the focused tests then the full native suite; commit.

Run: `scripts/test_native.sh`

### Task 2: Add status-bearing atomic native public steps

**Files:**
- Modify: `src/native/aerosim_native.hpp`, `src/native/aerosim_native.cpp`
- Modify: `src/native/aerosim_flight_control.hpp`, `src/native/aerosim_flight_control.cpp`
- Modify: `src/native/aerosim_collision.hpp`, `src/native/aerosim_collision.cpp`
- Modify: `src/native/aerosim_imu.hpp`, `src/native/aerosim_imu.cpp`
- Modify: `common/flight/flight_runtime.gd`
- Test: `tests/native/test_flight_control.cpp`, `tests/native/test_collision.cpp`, `tests/native/test_imu.cpp`, `tests/gut/test_flight_runtime_load.gd`

**Interfaces:**
- Add `StepStatus { Ok, InvalidCommand, InvalidConfig, InvalidState, InvalidControlOutput, ResourceLimitExceeded }` and a result carrying status, rows, and failed frame.
- Expose `last_step_error`; all native entry points retain it until success/reset.

- [ ] Write RED tests that inject NaN/+Inf/-Inf in every command/config/state/attitude/timing/tuning/collision route at the fourth 1 kHz substep and compare every observable state with an untouched clone.

```cpp
expect(result.status == StepStatus::InvalidCommand);
expect_state_bits_equal(after_failure, before_call);
expect_state_bits_equal(next_legal, untouched_clone_next_legal);
```

- [ ] Implement staged-copy/commit-or-restore for Angle, Acro, Altitude Hold, `sync_flight_state`, and all collision entry points, including controller telemetry buffers, IMU history/RNG/bias/walk, clock, authority/contact/clear frames, arm/reset/tuning state.
- [ ] Implement native-only error ownership and GDScript failure handling: one exact native error, `last_step_error`, synchronous `set_paused(true)`, frozen body, error screen, no normal row/contact reset/duplicate `push_error`.
- [ ] Add GUT coverage for frozen/error UI and native tests for atomic restoration and IMU continuation. Run RED/GREEN tests, then commit.

Run: `scripts/test_native.sh`

### Task 3: Make collision recovery and replay prove the new state

**Files:**
- Modify: `src/native/aerosim_replay.hpp`, `src/native/aerosim_replay.cpp`
- Modify: `src/native/aerosim_collision.cpp`
- Modify: `tests/native/test_replay.cpp`, `tests/native/test_collision.cpp`
- Modify: `scripts/test_replay_integration.sh`, `scripts/compare_replay_artifacts.py`

**Interfaces:**
- Upgrade replay schema 2→3 and compare controller target/rate, PID I/D, mode/init/latches, motors, clock, and first response substep field-by-field.
- Batches return `{status, rows, failed_frame}` and enforce checked `size_t` frame arithmetic with `kMaxBatchTrajectoryFrames=1'000'000`.

- [ ] Write RED replay tests for one changed controller/motor/clock field, empty/zero batch, negative/non-finite seconds, failed frame retention, and oversized length.
- [ ] Write RED collision tests for four scenes × 100 seeds × Angle/Acro with exact neutral/response commands, one reset, ≤1.01 collision energy, FlightCore authority, motor-response epsilon, and bitwise first-response replay.
- [ ] Implement schema-v3 serialization/comparison and checked batch allocation behavior; implement the paired-counterfactual recovery assertion without a height proxy.
- [ ] Run replay and collision tests plus the full native suite; commit.

Run: `scripts/test_native.sh && GODOT_BIN=/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 scripts/test_replay_integration.sh`

### Task 2b: Complete the native error, collision-variant, IMU, and GDScript atomic boundary

**Files:**
- Modify: `src/native/aerosim_native.hpp`, `src/native/aerosim_native.cpp`, `src/native/aerosim_collision.hpp`, `src/native/aerosim_collision.cpp`, `src/native/aerosim_imu.hpp`, `src/native/aerosim_imu.cpp`
- Modify: `common/flight/flight_runtime.gd`
- Test: `tests/native/test_collision.cpp`, `tests/native/test_imu.cpp`, `tests/gut/test_flight_runtime_load.gd`

**Interfaces:**
- Build on Task 2a `StepStatus`/`StepResult`; do not replace its staged controller rollback.
- Native owns `last_step_error` and the single exact `AeroSimNative.<method>: <status_code>: <field/reason>` error; GDScript only consumes it.

- [ ] Write failing tests for collision Acro/Altitude/PX4 invalid inputs and IMU continuation after a failed public call; assert complete rollback before mutation.
- [ ] Write failing GUT coverage that an invalid native result synchronously pauses, freezes the body, displays the native error, leaves contact/state untouched, and does not emit a second error.
- [ ] Implement snapshot/restore and prevalidation for the remaining collision variants and IMU state; route native public APIs through the status/error boundary.
- [ ] Implement the single GDScript failure branch before normal row application, replay recording, contact reset, or sensor progression.
- [ ] Run focused native/GUT tests, full native suite, extension build/GUT if available, diff/hardcoded guards; commit and report.

### Task 4: Add the persistent physical four-motor HUD

**Files:**
- Modify: `common/flight/flight_runtime.gd`, `common/flight/status_diagram_debug.gd`
- Modify: `common/flight/localization.gd` and locale resources used by it
- Test: `tests/gut/test_status_diagram_vehicle_selector.gd`, `tests/gut/test_flight_runtime_load.gd`, `tests/headed/headed_acceptance.gd`

**Interfaces:**
- Reuse `telemetry_snapshot().motors` and its frozen `[RR,FR,RL,FL]` order; no native API addition.
- Render nose-up grid `FL FR / RL RR`, each cell N/RPM/A plus non-colour saturation text, and keep it independent of OSD presets.

- [ ] Write RED GUT tests for physical cell mapping, rad/s→RPM conversion, localization, saturation marker, malformed/non-finite/incomplete data, stale publish-count/receipt-age, paused/error state, and Minimal preset visibility.
- [ ] Implement the HUD using the existing flight-HUD/status-diagram freshness state. Display unavailable/error rather than stale live-looking values; never mutate simulation or replay.
- [ ] Add headed acceptance assertions for panel visibility/readability and exact physical cell labels; run GUT and headed checks, then commit.

Run: `GODOT_BIN=/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 scripts/run_gut_tests.sh`

### Task 5: Bind merge evidence to one built native artifact

**Files:**
- Modify: `.github/workflows/ci.yml`, `scripts/verify_issue_11.sh`, `scripts/run_headed_acceptance.sh`
- Modify: `scripts/run_performance_benchmark.sh`, `scripts/performance_report.py`, `tests/performance/physics_benchmark.gd`
- Modify: `tests/test_ci_strategy.py`, `tests/test_performance_report.py`

**Interfaces:**
- One debug GDExtension build/commit hash is the prerequisite for GUT, isolated negative process, headed acceptance, replay, and effects-off/on evidence.

- [ ] Write RED strategy tests for required order `build → GUT → isolated-negative → headed`, exact binary/HEAD provenance, and fail-loud missing artifact behavior.
- [ ] Implement provenance recording and reject skipped/stale artifacts. Preserve Ubuntu-only CI and the frozen G0.1 effects-off/on thresholds.
- [ ] Run strategy/performance tests, full Linux verification, headless, headed, both performance modes, and review all generated JSON/log provenance. Commit.

Run: `RUNNER_TEMP=/tmp/aerosim-ci GODOT_BIN=/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 scripts/verify_issue_11.sh`

## Final verification

- [ ] Run `git diff --check`, `scripts/check_hardcoded_airframe_constants.sh`, `scripts/test_license_scan.sh`, native suite, GUT, replay, headless smoke, headed acceptance, effects-off/on performance, and Linux verification from the exact branch HEAD.
- [ ] Dispatch independent final adversarial code review; fix all Critical/High findings and re-review.
- [ ] Push/open a draft PR, wait for every required CI job, attach exact commit/native-hash evidence, then request merge review. Do not close #91 or merge automatically.
