# Ubuntu Channel Monitor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:executing-plans` for inline task-by-task execution. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the existing Settings → Controller panel into #41's live canonical-Xbox Channel Monitor without adding a second input state, mapping, or pause entry.

**Architecture:** `flight_runtime.gd` keeps the existing panel and `_process` refresh path. A single new monitor label renders data from the active `session_gamepad_profile`; the existing session helpers remain the source of axis normalization, throttle-low state, arm state, and mode. The existing disconnect safety screen remains responsible for disconnect UI. The headed harness measures the visible monitor's refresh counter while physics is paused.

**Tech Stack:** Godot 4.7, GDScript, GUT, existing headed acceptance harness, Linux GDExtension.

## Global Constraints

- Ubuntu Linux x86_64 only; run every Godot command with `GODOT_BIN=/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64`.
- Read samples only from `session_gamepad_device_id` and `session_gamepad_profile`; do not scan for a replacement controller, construct a fallback `GamepadProfile`, add a mapping store, or add an availability enum.
- `UNAVAILABLE` never renders synthetic zero channel values; the existing device/fallback diagnostics and disconnect safety screen remain authoritative.
- While visible, the monitor refreshes from `_process`, including while `paused`; no timer or polling loop is added.
- #41 adds no Pause Overlay button or return route. CAP-006 must pass before any DEV-M visual/usability review is requested.
- Use the existing 0.08 deadzone, direction inversion, throttle-low helper, button handler, and actual arm/mode state. Do not mutate sticky throttle while rendering.

---

### Task 1: Specify the monitor with failing GUT tests

**Files:**
- Modify: `tests/gut/test_flight_runtime_load.gd`
- Modify: `common/flight/flight_runtime.gd`

**Interfaces:**
- Consumes: `FlightRuntime._profile_axis(role: String) -> float`, `_profile_throttle_is_low() -> bool`, `_flight_control_armed() -> bool`, `session_gamepad_profile`, and `session_gamepad_device_id`.
- Produces: `controller_settings_monitor_label: Label` named `ChannelMonitor` and `controller_monitor_refresh_count: int` for headed evidence.

- [ ] **Step 1: Write failing active-session and unavailable monitor tests**

Add a GUT helper that creates `main_menu_layer`, builds the existing Controller panel, makes it visible, then injects canonical axis values. Add assertions for the live label:

```gdscript
assert_string_contains(monitor.text, "CHANNEL MONITOR (30 Hz)")
assert_string_contains(monitor.text, "roll:     [------------|----] raw +0.500 | normalized +0.457")
assert_string_contains(monitor.text, "pitch:    [------------|----] raw -0.500 | normalized +0.457")
assert_string_contains(monitor.text, "throttle: [--|--------------] raw -0.750 | normalized -0.728 | LOW")
assert_string_contains(monitor.text, "ARM: RELEASED | flight control: DISARMED")
assert_string_contains(monitor.text, "MODE: RELEASED | flight mode: ANGLE")

runtime.session_gamepad_profile = null
runtime.session_gamepad_device_id = -1
runtime._refresh_controller_settings()
assert_eq(runtime.controller_settings_mapping_label.text, "FIXED XBOX MAPPING: UNAVAILABLE")
assert_string_contains(monitor.text, "roll:     UNAVAILABLE")
assert_string_contains(monitor.text, "pitch:    UNAVAILABLE")
assert_string_contains(monitor.text, "yaw:      UNAVAILABLE")
assert_string_contains(monitor.text, "throttle: UNAVAILABLE")
```

Also add a preflight high-throttle A-button test that invokes `_handle_gamepad_button()` and proves the physical flag is pressed while the actual native arm state stays disarmed.

- [ ] **Step 2: Run the narrow GUT suite and verify RED**

Run:

```bash
GODOT_BIN=/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 scripts/run_gut_tests.sh
```

Expected: the new monitor assertions fail because `ChannelMonitor` and its refresh contract do not yet exist; existing tests remain the only passing behavior.

- [ ] **Step 3: Add the minimal Controller Monitor implementation**

In `flight_runtime.gd`, add only:

```gdscript
var controller_settings_monitor_label: Label
var controller_monitor_refresh_count := 0

func _controller_monitor_bar(value: float) -> String:
    var marker := clampi(roundi((clampf(value, -1.0, 1.0) + 1.0) * 8.0), 0, 16)
    return "[%s|%s]" % ["-".repeat(marker), "-".repeat(16 - marker)]
```

Replace the redundant standalone deadzone and button-status rows with one `ChannelMonitor` label below the fixed mapping. In `_refresh_controller_settings()`, preserve the existing device label, render `FIXED XBOX MAPPING: UNAVAILABLE` plus a monitor header and four `UNAVAILABLE` channel rows when `_has_active_gamepad_profile()` is false, and return before reading axes or constructing a profile. With a valid session, use `Input.get_joy_axis()` for raw values and `_profile_axis(role)` for normalized values; render four rows, `DEADZONE: 0.080 (fixed)`, LOW/HIGH from `_profile_throttle_is_low()`, physical Arm/Mode flags, `_flight_control_armed()`, and `flight_mode`. Increment `controller_monitor_refresh_count` on each visible refresh. Reset that counter in `show_controller_settings()`.

- [ ] **Step 4: Run the narrow GUT suite and verify GREEN**

Run the same command. Expected: all GUT tests pass with a non-empty JUnit report and no `ERROR:` or `SCRIPT ERROR:` lines.

- [ ] **Step 5: Commit the tested runtime slice**

```bash
git add common/flight/flight_runtime.gd tests/gut/test_flight_runtime_load.gd
git commit -m "feat: add channel monitor UI"
```

### Task 2: Extend paused headed acceptance evidence

**Files:**
- Modify: `tests/headed/headed_acceptance.gd`
- Modify: `scripts/run_headed_acceptance.sh`

**Interfaces:**
- Consumes: `runtime.show_controller_settings()`, `runtime.controller_monitor_refresh_count`, `runtime.airsim_session.simulation_time_seconds`, and existing `_inject_joy_axis()`.
- Produces: `build/headed/07_channel_monitor_paused.png` and `report.json.channel_monitor` with elapsed wall time, refresh count, refresh rate, frozen-state flags, and screenshot path.

- [ ] **Step 1: Write failing headed assertions and artifact requirement**

After the harness starts an armed flight and pauses it, open the existing Settings Monitor path. Add `_inject_joy_button()` and assertions that:

```gdscript
_expect(monitor_rate_hz >= 30.0, "paused Channel Monitor refreshes at least 30 Hz")
_expect(runtime.drone_body.global_position.distance_to(paused_position) <= 1e-6, "Channel Monitor leaves paused physics position frozen")
_expect(absf(runtime.airsim_session.simulation_time_seconds - paused_time) <= 1e-6, "Channel Monitor leaves paused simulation time frozen")
_expect(monitor.text.contains("ARM: PRESSED | flight control: ARMED"), "A button physical state remains distinct from armed state")
_expect(monitor.text.contains("MODE: PRESSED | flight mode: ALTITUDE_HOLD"), "Y button shows the actual resulting flight mode")
```

For at least one monotonic wall-clock second, inject canonical axes while awaiting `process_frame`; use the delta in `controller_monitor_refresh_count` to calculate `monitor_rate_hz`. Save `07_channel_monitor_paused.png` and include evidence in `report.json`. Require that PNG in `scripts/run_headed_acceptance.sh`.

- [ ] **Step 2: Run headed acceptance and verify RED**

Run:

```bash
GODOT_BIN=/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 scripts/run_headed_acceptance.sh --out-dir build/headed-channel-monitor-red
```

Expected: failure because the new screenshot/report requirement and monitor evidence do not exist yet.

- [ ] **Step 3: Implement the smallest headed harness extension**

Add:

```gdscript
func _inject_joy_button(device_id: int, button: JoyButton, pressed: bool) -> void:
    var event := InputEventJoypadButton.new()
    event.device = device_id
    event.button_index = button
    event.pressed = pressed
    Input.parse_input_event(event)
```

Record the paused monitor evidence in one dictionary and write it with the existing failures/passed report. Do not add a new test scene, timer, production pause entry, or custom controller adapter.

- [ ] **Step 4: Run headed acceptance and verify GREEN**

Run:

```bash
GODOT_BIN=/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 scripts/run_headed_acceptance.sh --out-dir build/headed-channel-monitor
```

Expected: exit 0; `report.json.passed == true`; the monitor evidence has `refresh_rate_hz >= 30`; `07_channel_monitor_paused.png` and `godot.log` exist; the log has no `ERROR:` or `SCRIPT ERROR:` prefix.

- [ ] **Step 5: Commit headed evidence**

```bash
git add tests/headed/headed_acceptance.gd scripts/run_headed_acceptance.sh
git commit -m "test: verify paused channel monitor"
```

### Task 3: Run the #41 verification stack and inspect the visible artifact

**Files:**
- No source changes expected.

**Interfaces:**
- Consumes: committed Tasks 1–2 and the Linux GDExtension.
- Produces: native, GUT, headless-smoke, headed, and AI visual evidence for a PR using `Refs #41`.

- [ ] **Step 1: Run native and hardcoded-constant checks**

```bash
scripts/test_native.sh
scripts/check_hardcoded_airframe_constants.sh
```

Expected: both exit 0.

- [ ] **Step 2: Run headless smoke after GDScript changes**

```bash
GODOT_BIN=/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 scripts/run_headless_smoke.sh --output build/headless_smoke.json --frames 5
```

Expected: exit 0 and `build/headless_smoke.json` reports the smoke path succeeded.

- [ ] **Step 3: Run the final headed acceptance and inspect the paused monitor image**

```bash
GODOT_BIN=/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 scripts/run_headed_acceptance.sh --out-dir build/headed-channel-monitor-final
```

Inspect `build/headed-channel-monitor-final/07_channel_monitor_paused.png` and `report.json`; record that the panel is readable and the report's refresh/frozen-state evidence is present. This is provisional Codex AI Visual Verification, not human review.

- [ ] **Step 4: Commit the final verification-only adjustments if any**

If verification exposes a real #41 defect, add the smallest failing test first, fix it, re-run the affected checks, and commit only the related files. Otherwise make no verification-only code change.

## Plan self-review

- Spec coverage: Task 1 implements live raw/normalized/deadzone/bars, LOW/HIGH, physical button vs actual control state, and `UNAVAILABLE` from canonical session truth. Task 2 proves 30 Hz monitor updates during pause, injected A/Y input, frozen transform/timestamp, screenshot/report, and clean logs. Task 3 runs native, GUT, headless, and headed gates plus provisional visual inspection.
- Placeholder scan: no deferred implementation, generic test, or implicit error-handling instruction remains.
- Type consistency: all named runtime fields, helpers, Godot event classes, report fields, test paths, and commands are defined in the task that introduces them.

## Execution Handoff

The user explicitly requested execution. Proceed inline with `superpowers:executing-plans`, preserving the red-green order above.
