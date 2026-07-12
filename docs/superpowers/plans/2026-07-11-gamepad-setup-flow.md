> **SUPERSEDED（2026-07-12）**：本計畫已被 `2026-07-12-xbox-default-profile.md`、PRD v3.4 與 `docs/decisions/2026-07-12-xbox-default-profile.md` 取代。保留本檔僅為審計軌跡，不得作為實作依據。

# Gamepad Setup Flow Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver #40's Xbox 360-compatible gamepad calibration wizard, session-only `CalibrationProfile`, automated G4B.UI2 contract coverage, and the Linux headed evidence handoff.

**Architecture:** Keep all calibration math and state transitions in a testable GDScript core which receives injected samples and produces either a complete profile or a named rejection. A dedicated Control renders that core state and forwards gamepad events; `flight_runtime.gd` only hosts the panel and gates Quick Fly on an in-memory profile. #49 receives the documented profile schema and remains the owner of persistence, import/export, and reconnect behavior.

**Tech Stack:** Godot 4.7, GDScript, existing headless smoke scene, existing headed acceptance harness, GitHub Actions.

## Global Constraints

- Target input is Xbox 360-compatible USB/Bluetooth gamepads; do not add RC, RadioProfile, or 16-channel behavior.
- Keep all PRD values unchanged: endpoint >= 95%, center <= +/-2%, stationary 1-second RMS <= 0.5%, Arm/Mode debounce <= 50 ms, and throttle must be low before arm.
- Use the merged `docs/gamepad-calibration-contract.md` as the source for the good sample plus center-offset, noise, endpoint, bounce, throttle-high, and duplicate-axis negative samples.
- `CalibrationProfile` is session-only in #40. #49 owns cross-session persistence, factory reset, import/export, and reconnect.
- Do not change `flight_runtime.gd` functions `_acro_roll_stick`, `_acro_pitch_stick`, `_acro_yaw_stick`, or `_gamepad_axis`, which belong to active PR #106.
- Linux evidence sequence is automation, local real-DISPLAY headed run, then @jhihweijhan play acceptance. xvfb output is regression-only, not headed acceptance evidence.
- The implementation PR must use `Refs #40`, never `Closes #40`; #40 stays open until the maintainer manually records play acceptance.
- Do not modify `.github/workflows/docs-ai.yml` or open a docs-ai PR.

---

### Task 1: Create the Pure Calibration Core and Contract Tests

**Files:**
- Create: `common/flight/gamepad_calibration.gd`
- Create: `tests/headless/gamepad_calibration_contract.gd`
- Modify: `common/smoke/headless_smoke.gd:24-105,1513-1569`

**Interfaces:**
- Consumes: injected axis samples as `Array[float]`, axis indices as `int`, button press timestamps as `int` milliseconds.
- Produces: `GamepadCalibration.CalibrationProfile`, or `last_rejection` set to one of `duplicate_axis`, `endpoint_coverage`, `center_offset`, `stationary_noise`, `duplicate_button`, `button_bounce`, or `throttle_not_low`.

- [ ] **Step 1: Write the failing contract test scene**

```gdscript
extends SceneTree

const Calibration = preload("res://common/flight/gamepad_calibration.gd")

func _initialize() -> void:
	var calibration := Calibration.GamepadCalibration.new()
	for entry in [["roll", 0], ["pitch", 1], ["yaw", 2], ["throttle", 3]]:
		assert(calibration.assign_axis(entry[0], entry[1]))
		assert(calibration.record_axis_range(entry[0], PackedFloat32Array([-1.0, 1.0])))
		assert(calibration.record_stationary_samples(entry[0], PackedFloat32Array([0.0, 0.0, 0.0, 0.0])))
		assert(calibration.set_axis_direction(entry[0], -1.0 if entry[0] == "pitch" else 1.0))
	assert(calibration.assign_button("arm", JOY_BUTTON_A))
	assert(calibration.assign_button("mode", JOY_BUTTON_Y))
	assert(calibration.record_button_press("arm", 1000))
	assert(calibration.throttle_is_low(0.0))
	assert(calibration.finish() != null)
	quit(0)
```

- [ ] **Step 2: Run the new test and verify the expected red state**

Run: `"$GODOT_BIN" --headless --path . --script res://tests/headless/gamepad_calibration_contract.gd`

Expected: non-zero exit because `gamepad_calibration.gd` does not exist.

- [ ] **Step 3: Implement the core with named validation failures**

```gdscript
class CalibrationProfile:
	const SCHEMA_VERSION := 1
	var axis_for_role: Dictionary
	var reversed_for_role: Dictionary
	var axis_ranges: Dictionary
	var arm_button := -1
	var mode_button := -1
	var sticky_throttle := true

	func to_dictionary() -> Dictionary:
		return {
			"schema_version": SCHEMA_VERSION,
			"axis_for_role": axis_for_role.duplicate(true),
			"reversed_for_role": reversed_for_role.duplicate(true),
			"axis_ranges": axis_ranges.duplicate(true),
			"arm_button": arm_button,
			"mode_button": mode_button,
			"sticky_throttle": sticky_throttle,
		}

class GamepadCalibration:
	const ROLES := ["roll", "pitch", "yaw", "throttle"]
	const MIN_ENDPOINT_COVERAGE := 0.95
	const MAX_CENTER_OFFSET := 0.02
	const MAX_STATIONARY_RMS := 0.005
	const MAX_DEBOUNCE_MS := 50
	const MAX_THROTTLE_LOW := 0.02

	var axis_for_role := {}
	var reversed_for_role := {}
	var axis_ranges := {}
	var buttons := {}
	var last_button_press_ms := {}
	var last_rejection := ""

	func assign_axis(role: String, axis: int) -> bool:
		if not ROLES.has(role) or axis < 0 or axis_for_role.values().has(axis):
			last_rejection = "duplicate_axis"
			return false
		axis_for_role[role] = axis
		return true

	func record_axis_range(role: String, samples: PackedFloat32Array) -> bool:
		if not axis_for_role.has(role) or samples.is_empty():
			last_rejection = "endpoint_coverage"
			return false
		var minimum := samples[0]
		var maximum := samples[0]
		for value in samples:
			if not is_finite(value):
				last_rejection = "endpoint_coverage"
				return false
			minimum = minf(minimum, value)
			maximum = maxf(maximum, value)
		if maximum < MIN_ENDPOINT_COVERAGE or minimum > -MIN_ENDPOINT_COVERAGE:
			last_rejection = "endpoint_coverage"
			return false
		axis_ranges[role] = {"minimum": minimum, "maximum": maximum}
		return true

	func record_stationary_samples(role: String, samples: PackedFloat32Array) -> bool:
		if not axis_ranges.has(role) or samples.is_empty():
			last_rejection = "center_offset"
			return false
		var mean := 0.0
		for value in samples:
			if not is_finite(value):
				last_rejection = "center_offset"
				return false
			mean += value
		mean /= samples.size()
		if absf(mean) > MAX_CENTER_OFFSET:
			last_rejection = "center_offset"
			return false
		var variance := 0.0
		for value in samples:
			variance += pow(value - mean, 2.0)
		if sqrt(variance / samples.size()) > MAX_STATIONARY_RMS:
			last_rejection = "stationary_noise"
			return false
		axis_ranges[role]["center"] = mean
		return true

	func set_axis_direction(role: String, observed_value: float) -> bool:
		if not axis_for_role.has(role) or not is_finite(observed_value) or is_zero_approx(observed_value):
			last_rejection = "endpoint_coverage"
			return false
		reversed_for_role[role] = observed_value < 0.0
		return true

	func assign_button(role: String, button: int) -> bool:
		if not ["arm", "mode"].has(role) or button < 0 or buttons.values().has(button):
			last_rejection = "duplicate_button"
			return false
		buttons[role] = button
		return true

	func record_button_press(role: String, timestamp_ms: int) -> bool:
		if not buttons.has(role):
			last_rejection = "duplicate_button"
			return false
		if last_button_press_ms.has(role) and timestamp_ms - int(last_button_press_ms[role]) < MAX_DEBOUNCE_MS:
			last_rejection = "button_bounce"
			return false
		last_button_press_ms[role] = timestamp_ms
		return true

	func throttle_is_low(value: float) -> bool:
		if not is_finite(value) or value > MAX_THROTTLE_LOW:
			last_rejection = "throttle_not_low"
			return false
		return true

	func finish() -> CalibrationProfile:
		if axis_for_role.size() != 4 or axis_ranges.size() != 4 or reversed_for_role.size() != 4 or buttons.size() != 2:
			last_rejection = "incomplete_profile"
			return null
		var profile := CalibrationProfile.new()
		profile.axis_for_role = axis_for_role.duplicate(true)
		profile.reversed_for_role = reversed_for_role.duplicate(true)
		profile.axis_ranges = axis_ranges.duplicate(true)
		profile.arm_button = buttons.arm
		profile.mode_button = buttons.mode
		return profile
```

- [ ] **Step 4: Add all six negative samples to the contract test**

```gdscript
func _reject(calibration: Calibration.GamepadCalibration, expected: String) -> void:
	assert(calibration.finish() == null or calibration.last_rejection == expected)
	assert(calibration.last_rejection == expected)

func _test_rejections() -> void:
	var duplicate := Calibration.GamepadCalibration.new()
	assert(duplicate.assign_axis("roll", 0))
	assert(not duplicate.assign_axis("pitch", 0))
	assert(duplicate.last_rejection == "duplicate_axis")
	var endpoint := Calibration.GamepadCalibration.new()
	assert(endpoint.assign_axis("roll", 0))
	assert(not endpoint.record_axis_range("roll", PackedFloat32Array([-0.8, 0.8])))
	assert(endpoint.last_rejection == "endpoint_coverage")
	var center := Calibration.GamepadCalibration.new()
	assert(center.assign_axis("roll", 0))
	assert(center.record_axis_range("roll", PackedFloat32Array([-1.0, 1.0])))
	assert(not center.record_stationary_samples("roll", PackedFloat32Array([0.03, 0.03, 0.03, 0.03])))
	assert(center.last_rejection == "center_offset")
	var noise := Calibration.GamepadCalibration.new()
	assert(noise.assign_axis("roll", 0))
	assert(noise.record_axis_range("roll", PackedFloat32Array([-1.0, 1.0])))
	assert(not noise.record_stationary_samples("roll", PackedFloat32Array([-0.01, 0.01, -0.01, 0.01])))
	assert(noise.last_rejection == "stationary_noise")
	var bounce := Calibration.GamepadCalibration.new()
	assert(bounce.assign_button("arm", JOY_BUTTON_A))
	assert(bounce.record_button_press("arm", 1000))
	assert(not bounce.record_button_press("arm", 1020))
	assert(bounce.last_rejection == "button_bounce")
	var throttle := Calibration.GamepadCalibration.new()
	assert(not throttle.throttle_is_low(0.3))
	assert(throttle.last_rejection == "throttle_not_low")
```

- [ ] **Step 5: Run the core contract test and the existing input smoke**

Run: `"$GODOT_BIN" --headless --path . --script res://tests/headless/gamepad_calibration_contract.gd`

Expected: exit 0.

Run: `"$GODOT_BIN" --headless --path . --script res://common/smoke/headless_smoke.gd -- --runtime-only`

Expected: exit 0; existing keyboard and gamepad action checks remain green.

- [ ] **Step 6: Commit the core and its tests**

```bash
git add common/flight/gamepad_calibration.gd tests/headless/gamepad_calibration_contract.gd common/smoke/headless_smoke.gd
git commit -m "feat: add gamepad calibration contract"
```

### Task 2: Document and Expose the Session Calibration Profile

**Files:**
- Create: `docs/calibration-profile-schema.md`
- Modify: `common/flight/input_profiles.gd:1-13`
- Modify: `tests/headless/gamepad_calibration_contract.gd`

**Interfaces:**
- Consumes: `GamepadCalibration.CalibrationProfile` from Task 1.
- Produces: `GamepadProfile.from_calibration(profile)` and schema documentation for #49.

- [ ] **Step 1: Extend the test with profile conversion assertions**

```gdscript
var profile := calibration.finish()
var gamepad := InputProfiles.GamepadProfile.from_calibration(profile)
assert(gamepad.axis_for_role == {"roll": 0, "pitch": 1, "yaw": 2, "throttle": 3})
assert(gamepad.arm_button == JOY_BUTTON_A)
assert(gamepad.mode_button == JOY_BUTTON_Y)
assert(gamepad.sticky_throttle)
assert(gamepad.profile_schema_version == 1)
```

- [ ] **Step 2: Run the test and verify it fails for the missing conversion API**

Run: `"$GODOT_BIN" --headless --path . --script res://tests/headless/gamepad_calibration_contract.gd`

Expected: non-zero exit naming `from_calibration`.

- [ ] **Step 3: Implement the session adapter without persistence**

```gdscript
const Calibration = preload("res://common/flight/gamepad_calibration.gd")

class GamepadProfile:
	var deadzone := 0.05
	var throttle := 0.0
	var axis_for_role := {}
	var reversed_for_role := {}
	var arm_button := -1
	var mode_button := -1
	var sticky_throttle := true
	var profile_schema_version := 0

	static func from_calibration(profile: Calibration.CalibrationProfile) -> GamepadProfile:
		var gamepad := GamepadProfile.new()
		gamepad.axis_for_role = profile.axis_for_role.duplicate(true)
		gamepad.reversed_for_role = profile.reversed_for_role.duplicate(true)
		gamepad.arm_button = profile.arm_button
		gamepad.mode_button = profile.mode_button
		gamepad.sticky_throttle = profile.sticky_throttle
		gamepad.profile_schema_version = profile.SCHEMA_VERSION
		return gamepad
```

- [ ] **Step 4: Write the #49 handoff schema**

```markdown
# CalibrationProfile Schema

`schema_version` is `1`. `axis_for_role` maps `roll`, `pitch`, `yaw`, and `throttle` to distinct non-negative Godot joy-axis indices. `reversed_for_role` has exactly the same keys and boolean values. `axis_ranges` has one entry per role with finite `minimum`, `maximum`, and `center` numeric values. `arm_button` and `mode_button` are distinct non-negative Godot joy-button indices. `sticky_throttle` is a boolean.

#40 keeps this value in memory only. #49 serializes it, validates this schema on import, and owns migration for a later version.
```

- [ ] **Step 5: Run the profile test and inspect the schema**

Run: `"$GODOT_BIN" --headless --path . --script res://tests/headless/gamepad_calibration_contract.gd`

Expected: exit 0.

Run: `git diff --check`

Expected: no output.

- [ ] **Step 6: Commit the public handoff**

```bash
git add common/flight/input_profiles.gd docs/calibration-profile-schema.md tests/headless/gamepad_calibration_contract.gd
git commit -m "docs: define calibration profile schema"
```

### Task 3: Build the Setup Panel and Fixed Eight-Step UI

**Files:**
- Create: `common/flight/gamepad_setup_panel.gd`
- Modify: `common/flight/flight_runtime.gd:3-58,198-214,270-286,340-384`
- Modify: `common/smoke/headless_smoke.gd:1042-1131`

**Interfaces:**
- Consumes: `GamepadCalibration.GamepadCalibration` and `InputProfiles.GamepadProfile`.
- Produces: `completed(profile: CalibrationProfile)` and `rejected(code: String)` signals; runtime method `complete_controller_setup(profile)`.

- [ ] **Step 1: Add a failing runtime smoke assertion for the Controller path**

```gdscript
var controller_button := scene.get_node_or_null("MainMenu/Entries/Controller") as Button
if controller_button == null:
	push_error("Main menu must expose an interactive Controller entry")
	return false
controller_button.pressed.emit()
await process_frame
if scene.screen != "controller_setup" or scene.gamepad_setup_panel == null:
	push_error("Controller entry must open the fixed Gamepad Setup Flow")
	return false
if scene.gamepad_setup_panel.step_names != [
	"Detect device", "Live monitor", "Assign axes", "Calibrate endpoints",
	"Detect reverse", "Map Arm/Mode", "Throttle low", "Hover test"
]:
	push_error("Gamepad Setup Flow must preserve the PRD fixed step order")
	return false
```

- [ ] **Step 2: Run runtime-only smoke and verify it fails for the missing panel**

Run: `"$GODOT_BIN" --headless --path . --script res://common/smoke/headless_smoke.gd -- --runtime-only`

Expected: non-zero exit naming `gamepad_setup_panel`.

- [ ] **Step 3: Implement the panel as a UI adapter over the pure core**

```gdscript
extends PanelContainer

signal completed(profile)
signal rejected(code: String)

const Calibration = preload("res://common/flight/gamepad_calibration.gd")
const InputProfiles = preload("res://common/flight/input_profiles.gd")

var step_names := [
	"Detect device", "Live monitor", "Assign axes", "Calibrate endpoints",
	"Detect reverse", "Map Arm/Mode", "Throttle low", "Hover test"
]
var step_index := 0
var calibration := Calibration.GamepadCalibration.new()
var status_label := Label.new()

func _ready() -> void:
	name = "GamepadSetup"
	add_child(status_label)
	_refresh_status()

func submit_axis(role: String, axis: int, range_samples: PackedFloat32Array, stationary_samples: PackedFloat32Array, direction: float) -> bool:
	if not calibration.assign_axis(role, axis) or not calibration.record_axis_range(role, range_samples) or not calibration.record_stationary_samples(role, stationary_samples) or not calibration.set_axis_direction(role, direction):
		rejected.emit(calibration.last_rejection)
		_refresh_status()
		return false
	step_index = mini(step_index + 1, step_names.size() - 1)
	_refresh_status()
	return true

func submit_buttons(arm_button: int, mode_button: int, arm_press_ms: int, mode_press_ms: int) -> bool:
	if not calibration.assign_button("arm", arm_button) or not calibration.assign_button("mode", mode_button) or not calibration.record_button_press("arm", arm_press_ms) or not calibration.record_button_press("mode", mode_press_ms):
		rejected.emit(calibration.last_rejection)
		_refresh_status()
		return false
	step_index = 6
	_refresh_status()
	return true

func submit_throttle_and_finish(throttle: float) -> bool:
	if not calibration.throttle_is_low(throttle):
		rejected.emit(calibration.last_rejection)
		_refresh_status()
		return false
	var profile := calibration.finish()
	if profile == null:
		rejected.emit(calibration.last_rejection)
		_refresh_status()
		return false
	step_index = 7
	completed.emit(profile)
	_refresh_status()
	return true

func _refresh_status() -> void:
	status_label.text = "%d/8 %s%s" % [step_index + 1, step_names[step_index], "" if calibration.last_rejection.is_empty() else ": " + calibration.last_rejection]
```

- [ ] **Step 4: Wire the panel into only the non-ACRO runtime sections**

```gdscript
const GamepadSetupPanel = preload("res://common/flight/gamepad_setup_panel.gd")

var gamepad_setup_panel: Control
var session_gamepad_profile: InputProfiles.GamepadProfile

func begin_controller_setup() -> void:
	screen = "controller_setup"
	if gamepad_setup_panel == null:
		gamepad_setup_panel = GamepadSetupPanel.new()
		gamepad_setup_panel.completed.connect(complete_controller_setup)
		gamepad_setup_panel.rejected.connect(_show_setup_rejection)
		flight_hud_layer.add_child(gamepad_setup_panel)
	gamepad_setup_panel.show()
	_refresh_flight_hud()

func complete_controller_setup(profile) -> void:
	session_gamepad_profile = InputProfiles.GamepadProfile.from_calibration(profile)
	gamepad_setup_panel.hide()
	enter_preflight()

func _show_setup_rejection(code: String) -> void:
	last_error_message = "Controller setup rejected: %s" % code
	_refresh_flight_hud()
```

Connect the existing `Controller` menu button to `begin_controller_setup`, make `quick_fly("uncalibrated")` call it, and do not touch the four excluded ACRO helpers.

- [ ] **Step 5: Run runtime smoke and inspect the UI tree**

Run: `"$GODOT_BIN" --headless --path . --script res://common/smoke/headless_smoke.gd -- --runtime-only`

Expected: exit 0; Controller enters Setup and the eight step names match the PRD order.

Run: `git diff --check`

Expected: no output.

- [ ] **Step 6: Commit the UI integration**

```bash
git add common/flight/gamepad_setup_panel.gd common/flight/flight_runtime.gd common/smoke/headless_smoke.gd
git commit -m "feat: add gamepad setup flow"
```

### Task 4: Gate Quick Fly on the Session Profile and Cover Red/Green Paths

**Files:**
- Modify: `common/flight/flight_runtime.gd:198-214,373-384`
- Modify: `common/smoke/headless_smoke.gd:1089-1129,1513-1569`
- Modify: `tests/headed/headed_acceptance.gd:18-58`

**Interfaces:**
- Consumes: `session_gamepad_profile` from Task 3.
- Produces: calibrated gamepad path to `preflight`, uncalibrated path to Setup, and no-controller path to KeyboardProfile fallback.

- [ ] **Step 1: Add failing calibrated and uncalibrated Quick Fly assertions**

```gdscript
var valid_calibration := Calibration.GamepadCalibration.new()
for entry in [["roll", 0], ["pitch", 1], ["yaw", 2], ["throttle", 3]]:
	assert(valid_calibration.assign_axis(entry[0], entry[1]))
	assert(valid_calibration.record_axis_range(entry[0], PackedFloat32Array([-1.0, 1.0])))
	assert(valid_calibration.record_stationary_samples(entry[0], PackedFloat32Array([0.0, 0.0, 0.0, 0.0])))
	assert(valid_calibration.set_axis_direction(entry[0], 1.0))
assert(valid_calibration.assign_button("arm", JOY_BUTTON_A))
assert(valid_calibration.assign_button("mode", JOY_BUTTON_Y))
assert(valid_calibration.record_button_press("arm", 1000))
assert(valid_calibration.record_button_press("mode", 1100))
assert(valid_calibration.throttle_is_low(0.0))
var valid_profile := valid_calibration.finish()
assert(valid_profile != null)
scene.quick_fly("calibrated")
if scene.screen != "controller_setup":
	push_error("A detected but uncalibrated gamepad must route Quick Fly to Setup")
	return false
scene.complete_controller_setup(valid_profile)
scene.quick_fly("calibrated")
if scene.screen != "preflight":
	push_error("A session calibration profile must let Quick Fly enter preflight")
	return false
```

- [ ] **Step 2: Run runtime-only smoke and verify it fails before the gate changes**

Run: `"$GODOT_BIN" --headless --path . --script res://common/smoke/headless_smoke.gd -- --runtime-only`

Expected: non-zero exit because the old `_quick_fly_entry_state()` treats every connected pad as calibrated.

- [ ] **Step 3: Make the runtime use the session profile honestly**

```gdscript
func _quick_fly_entry_state() -> String:
	if Input.get_connected_joypads().is_empty():
		return "no_controller"
	return "calibrated" if session_gamepad_profile != null else "uncalibrated"

func quick_fly(entry_state: String = _quick_fly_entry_state()) -> void:
	if entry_state == "no_controller":
		last_error_message = InputProfiles.fallback_status([])
		screen = "fallback_prompt"
		_refresh_flight_hud()
		return
	if entry_state == "uncalibrated":
		begin_controller_setup()
		return
	if entry_state != "calibrated" or session_gamepad_profile == null:
		last_error_message = "Quick Fly cannot continue: missing session calibration"
		screen = "error"
		_refresh_flight_hud()
		return
	enter_preflight()
```

- [ ] **Step 4: Extend headed acceptance with a visible Setup route**

```gdscript
runtime.quick_fly("uncalibrated")
await _settle(10)
await _snapshot("01_controller_setup")
_expect(runtime.screen == "controller_setup", "uncalibrated gamepad enters visible Controller Setup")
_expect(runtime.gamepad_setup_panel != null and runtime.gamepad_setup_panel.is_visible_in_tree(), "Controller Setup panel is visible")
```

Keep the existing no-controller KeyboardProfile branch and snapshot sequence; add the new screenshot rather than replacing it.

- [ ] **Step 5: Run the focused automated checks**

Run: `"$GODOT_BIN" --headless --path . --script res://tests/headless/gamepad_calibration_contract.gd`

Expected: exit 0.

Run: `"$GODOT_BIN" --headless --path . --script res://common/smoke/headless_smoke.gd -- --runtime-only`

Expected: exit 0.

Run: `git diff --check`

Expected: no output.

- [ ] **Step 6: Commit Quick Fly gating and harness coverage**

```bash
git add common/flight/flight_runtime.gd common/smoke/headless_smoke.gd tests/headed/headed_acceptance.gd
git commit -m "feat: gate quick fly on gamepad calibration"
```

### Task 5: Produce Evidence, Review Readiness, and the Maintainer Handoff

**Files:**
- Modify: `docs/gamepad-calibration-contract.md` only if automated sample names differ from the documented six cases
- Modify: `docs/calibration-profile-schema.md` only if the implemented schema differs from Task 2
- Create: `docs/reports/gamepad-setup-validation-<commit>.md`

**Interfaces:**
- Consumes: passing Task 1 through Task 4 checks and headed screenshots.
- Produces: evidence linked from #40 and a draft PR body using `Refs #40`.

- [ ] **Step 1: Run the full relevant automation in the isolated worktree**

Run: `scripts/test_native.sh`

Expected: exit 0.

Run: `"$GODOT_BIN" --headless --path . --script res://tests/headless/gamepad_calibration_contract.gd`

Expected: exit 0.

Run: `scripts/run_headless_smoke.sh --frames 5`

Expected: exit 0 and writes its requested artifacts.

- [ ] **Step 2: Run headed regression and then the required real-display acceptance**

Run: `scripts/run_headed_acceptance.sh --xvfb`

Expected: exit 0; regression evidence only.

Run: `scripts/run_headed_acceptance.sh`

Expected: a Godot window visibly opens on the local Linux display, screenshots include `01_controller_setup`, report has no failures, active Camera3D is present, and every screenshot has maximum single-color ratio below 0.99.

- [ ] **Step 3: Write the validation report without claiming unperformed manual acceptance**

```markdown
# #40 Validation Report

## Automated

- `scripts/test_native.sh`: PASS
- `tests/headless/gamepad_calibration_contract.gd`: PASS
- `scripts/run_headless_smoke.sh --frames 5`: PASS

## Linux headed

- Command: `scripts/run_headed_acceptance.sh`
- Environment: local Linux real display; Godot window was visible to the maintainer.
- Evidence: `build/headed/report.json` and screenshots including `01_controller_setup.png`.

## Not verified

- Xbox 360-compatible hardware playthrough: awaiting @jhihweijhan.
- Cross-session persistence, import/export, and reconnect: #49 scope; not claimed as complete.
```

- [ ] **Step 4: Open the draft PR and request adversarial review**

Use this exact PR body fragment:

```markdown
Refs #40

## Scope

- Implements session-only Gamepad Setup and CalibrationProfile.
- Does not implement #49 persistence, import/export, or reconnect.

## Verification

- Link the automated and real-display headed report.

## Not verified

- Maintainer Xbox 360-compatible gamepad playthrough remains required before #40 can close.
```

Post an #40 comment starting with `> *This was generated by AI during triage.*`, include `agent-20260711-c9e4`, link the report and draft PR, and @jhihweijhan for the final play acceptance. Do not close #40.

- [ ] **Step 5: Commit the evidence report**

```bash
git add docs/reports/gamepad-setup-validation-*.md
git commit -m "docs: record gamepad setup validation"
```

## Plan Self-Review

- Spec coverage: Task 1 implements all six contract checks and six documented bad samples. Task 2 documents the #49 schema handoff. Task 3 implements all eight ordered UI steps. Task 4 covers setup routing, Quick Fly gating, keyboard fallback, and headed visibility. Task 5 enforces the required Linux evidence order, `Refs #40`, adversarial review, and manual-close rule.
- Placeholder scan: no TBD, TODO, deferred implementation, or unspecified test steps are present. The only deferred scope is explicitly owned by #49.
- Type consistency: `GamepadCalibration.CalibrationProfile` is created by Task 1, converted by `GamepadProfile.from_calibration` in Task 2, emitted by Task 3, and stored as `session_gamepad_profile` in Task 4.
