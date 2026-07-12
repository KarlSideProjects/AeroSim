# Xbox Default Profile Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the obsolete calibration wizard with confirmed, fixed Xbox mapping and a safe Keyboard fallback.

**Architecture:** `input_profiles.gd` becomes the deep module that owns the versioned fixed mapping and known-device predicate. `flight_runtime.gd` hosts a confirmation panel and consumes the profile; it never infers axes itself. The old calibration core, panel, contract test, and schema handoff are deleted because PRD v3.4 supersedes them.

**Tech Stack:** Godot 4.7, GDScript, Godot SDL controller mapping, existing smoke and headed harnesses.

## Global Constraints

- Apply Xbox mapping only when `Input.is_joy_known(device_id)` is true; unknown devices are blocked and offered Keyboard fallback.
- Fixed raw-axis deadzone must be a named 0.08-0.10 constant in profile schema, never the InputMap default 0.5.
- Arm and Mode are distinct; debounce is <=50 ms; preflight retains throttle-low blocking.
- Do not implement calibration, manual mappings, RC, persistence, import/export, or reconnect.
- `Refs #40` only; no `Closes #40`; maintainer hardware playthrough remains required.

---

### Task 1: Replace Calibration Data with Fixed Profile

**Files:**
- Modify: `common/flight/input_profiles.gd`
- Delete: `common/flight/gamepad_calibration.gd`
- Delete: `tests/headless/gamepad_calibration_contract.gd`

- [ ] Write failing assertions that `GamepadProfile.xbox_default(device_id)` returns schema version, four fixed distinct axes, distinct Arm/Mode, and `RAW_AXIS_DEADZONE` in [0.08, 0.10], while `Input.is_joy_known(device_id) == false` returns null.
- [ ] Implement `const RAW_AXIS_DEADZONE := 0.08`, `static func xbox_default(device_id: int) -> GamepadProfile`, and `static func is_supported_device(device_id: int) -> bool`; copy only fixed mapping fields into the profile.
- [ ] Remove calibration-only fields and all calibration contract tests.
- [ ] Run `GODOT_BIN="/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64" --headless --path . --script res://common/smoke/headless_smoke.gd -- --runtime-only`; expect exit 0.
- [ ] Commit: `git commit -am "feat: add xbox default profile"`.

### Task 2: Replace Eight-Step UI with Confirmation

**Files:**
- Delete: `common/flight/gamepad_setup_panel.gd`
- Modify: `common/flight/flight_runtime.gd`
- Modify: `common/smoke/headless_smoke.gd`
- Modify: `tests/headed/headed_acceptance.gd`

- [ ] Write failing smoke cases for known-unconfirmed -> confirmation, confirmation -> preflight, unknown -> fallback, and confirmation panel exposing fixed mapping plus live raw/normalized values.
- [ ] Implement one confirmation panel with `USE XBOX DEFAULT PROFILE` and fallback action; create its profile only through `GamepadProfile.xbox_default(device_id)`. Route unknown devices to fallback; remove calibration entry points and messages.
- [ ] Keep the preflight throttle-low status and existing non-ACRO runtime helpers unchanged.
- [ ] Run runtime smoke and `scripts/run_headed_acceptance.sh`; expect exit 0 and a visible confirmation screenshot.
- [ ] Commit: `git commit -am "feat: confirm xbox default profile"`.

### Task 3: Update Handoff and Evidence

**Files:**
- Modify: `docs/calibration-profile-schema.md`
- Modify: `docs/reports/gamepad-setup-validation-*.md`

- [ ] Replace calibration schema text with confirmed fixed mapping + schema version handoff for #49; state persistence is #49 scope.
- [ ] Record automation, headed evidence, and unverified maintainer hardware playthrough without claiming calibration checks.
- [ ] Run `scripts/test_native.sh`, the runtime smoke, and real-display headed acceptance; expect exit 0 before committing evidence.
- [ ] Commit: `git commit -am "docs: validate xbox default profile"`.

## Plan Self-Review

- Spec coverage: Task 1 owns fixed mapping and deadzone; Task 2 owns known/unknown routing, UI, and safety; Task 3 owns #49 handoff and evidence.
- Scope: calibration data, wizard, manual mapping, and their tests are explicitly deleted rather than left reachable.
- Type consistency: runtime obtains `GamepadProfile` only from `GamepadProfile.xbox_default(device_id)`.
