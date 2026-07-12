# Xbox Flight Controls Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Route a confirmed Xbox `GamepadProfile` into simulated flight controls while enforcing throttle-low arming and debounced Arm/Mode buttons.

**Architecture:** `GamepadProfile` remains the fixed mapping and state holder. `flight_runtime.gd` samples its axes at the physics boundary, transforms the values for native Angle/ACRO calls, validates raw throttle before arming, and owns device-specific button event handling. The existing headless smoke injects a known SDL controller and proves the behavior through the real runtime and native diagnostics.

**Tech Stack:** Godot 4.7 GDScript, GDExtension native flight control, headless smoke test.

## Global Constraints

- Keep the fixed Xbox mapping, `Input.is_joy_known()` unknown-device rejection, and KeyboardProfile fallback.
- Do not add calibration, manual mapping, persistence (#49), or modify `docs-ai`.
- Do not modify #106 ACRO helpers; only provide processed profile axes at their caller.
- Arm/Mode button debounce must be at most 50 ms and releases must remain observable.
- Use TDD: run each new smoke assertion against the existing implementation and observe its expected failure before implementation.

---

### Task 1: Specify Profile-Driven Runtime Behavior

**Files:**
- Modify: `common/smoke/headless_smoke.gd:1045-1313`

**Interfaces:**
- Consumes: `flight_runtime.gd` public runtime scene state and virtual joystick injection.
- Produces: discriminating runtime smoke coverage for profile axis routing, throttle-low arming, and button debounce.

- [ ] **Step 1: Write failing runtime smoke assertions**

Add a helper that injects `InputEventJoypadButton` for the known device, then assert that a confirmed profile changes native thrust and attitude/rates inputs, that a high profile throttle blocks Arm, and that repeated Arm/Mode presses within 50 ms do not retrigger while releases update observable state.

- [ ] **Step 2: Run the runtime smoke to verify it fails**

Run: `GODOT_BIN=/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 scripts/run_headless_smoke.sh --frames 5`

Expected: FAIL because the runtime still supplies `FLIGHT_THROTTLE`, zero Angle sticks, and has no profile button state/debounce.

### Task 2: Route Axes and Enforce Arm Preconditions

**Files:**
- Modify: `common/flight/input_profiles.gd:1-35`
- Modify: `common/flight/flight_runtime.gd:67-171,186-197,429-460,495-530`

**Interfaces:**
- Consumes: `GamepadProfile.axis_for_role`, `reversed_for_role`, `deadzone`, `sticky_throttle`, and the confirmed device ID.
- Produces: `GamepadProfile.apply_throttle_axis(raw)`, `GamepadProfile.throttle_axis_is_low(raw)`, runtime axis readers, and real HUD state.

- [ ] **Step 1: Implement the minimum profile APIs and runtime routing**

Keep `RAW_AXIS_DEADZONE = 0.08`, add a named low threshold no greater than 0.10, update sticky throttle from raw input outside the deadzone, sample roll/pitch/yaw/throttle only from an active confirmed profile, and pass these values to existing Angle/Altitude Hold/ACRO native callers. Reject `arm_and_takeoff()` before native arming when the live raw profile throttle is above the low threshold.

- [ ] **Step 2: Run runtime smoke to verify it passes these assertions**

Run: `GODOT_BIN=/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 scripts/run_headless_smoke.sh --frames 5`

Expected: success with a valid JSON and CSV smoke artifact.

### Task 3: Handle Debounced Xbox Buttons

**Files:**
- Modify: `common/flight/flight_runtime.gd:67-78,429-460`

**Interfaces:**
- Consumes: `InputEventJoypadButton`, active profile button IDs, device ID, and monotonic time in milliseconds.
- Produces: profile Arm/Mode `pressed` state, ≤50 ms press debounce, and Button HUD state.

- [ ] **Step 1: Implement minimum raw button event handling**

In `_unhandled_input`, dispatch a matching active-device `InputEventJoypadButton` before InputMap actions. Always store releases; accept a press only if it is at least 50 ms after the preceding accepted press for that button. Arm calls `arm_and_takeoff()` and Mode calls `toggle_altitude_hold()` only on accepted presses. Keyboard actions retain their existing behavior.

- [ ] **Step 2: Run runtime smoke to verify all assertions pass**

Run: `GODOT_BIN=/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 scripts/run_headless_smoke.sh --runtime-only --frames 5`

Expected: success; profile axes, arm gate, button state, and debounce are all covered.

### Task 4: Validate and Report

**Files:**
- Create: `.superpowers/sdd/xbox-flight-controls-report.md`

**Interfaces:**
- Consumes: actual validation command output.
- Produces: a report of changed behavior, TDD evidence, command results, benchmark result, and residual concerns.

- [ ] **Step 1: Run required validation**

Run the fixed Godot headless runtime smoke and full smoke, `scripts/test_native.sh`, and `git diff --check`. Run the benchmark smoke if headed-display and required dependencies are present; otherwise record its exact prerequisite failure.

- [ ] **Step 2: Write the report**

Record exact commands, pass/fail results, the observed RED failure, changed files, and any benchmark limitation.

- [ ] **Step 3: Commit only task files**

Run `git status --short`, stage only the profile/runtime/smoke/report/plan files changed for this task, then create a conventional commit describing profile-driven Xbox flight controls.
