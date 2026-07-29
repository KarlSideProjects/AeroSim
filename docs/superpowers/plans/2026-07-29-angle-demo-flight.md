# ANGLE Demo Flight Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Demo Flight fly Terrain Range through bounded native ANGLE stick controls, with no per-frame pose override.

**Architecture:** Keep `step_collision_angle_mode` and its 17-field publication contract. `FlightRuntime` starts the route after reset/arm commit, turns route/state feedback into body-frame ANGLE controls, and synchronizes Godot body state into native only at demo start or an existing Jolt collision handoff.

**Tech Stack:** Godot 4.7 GDScript, AeroSim C++ GDExtension, GUT, X11/xdotool.

## Global Constraints

- Keep `flight_mode == "ANGLE"` throughout Demo Flight.
- Use existing `step_collision_angle_mode`; do not alter its 17-field contract.
- Do not add dependencies or airframe constants; use `_configured_hover_throttle()` and existing ANGLE limits.
- Never route-call `apply_native_state()` with target position, rotation, or zero velocity.
- Keep Quick Fly third-person and the X11 game/GSP 3:2 split.
- Leave generated Godot artifacts untracked.

---

## File Structure

- `common/flight/flight_runtime.gd`: route lifecycle, demo authority gate, ANGLE feedback, safety exit.
- `common/flight/demo_flight_route.gd`: deterministic simulation-delta timeline.
- `tests/gut/test_demo_flight_route.gd`: deterministic timeline assertions.
- `tests/gut/test_flight_runtime_load.gd`: native command/HUD, physical-flight, collision-handoff assertions.

### Task 1: Start the route after reset commit

**Files:**

- Modify: `common/flight/demo_flight_route.gd:12-45`
- Modify: `common/flight/flight_runtime.gd:2289-2325,2830-2880`
- Test: `tests/gut/test_demo_flight_route.gd`

**Interfaces:** Consumes `DemoFlightRoute.advance(delta, position, velocity, yaw)`. Produces `DemoFlightRoute.start(spawn: Vector3)` and `FlightRuntime._start_demo_route_after_reset() -> void`.

- [ ] **Step 1: Write the failing deterministic test**

```gdscript
func test_route_advances_only_by_simulation_delta() -> void:
    var route := DemoFlightRoute.new()
    route.start(Vector3.ZERO)
    route.advance(2.5, Vector3.ZERO, Vector3.ZERO, 0.0)
    assert_eq(route.snapshot().phase, "hover")
    route.advance(0.6, Vector3.ZERO, Vector3.ZERO, 0.0)
    assert_eq(route.snapshot().phase, "low_pass")
```

- [ ] **Step 2: Run it and verify it fails**

Run: `GODOT_BIN=/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 $GODOT_BIN --headless --path . --script addons/gut/gut_cmdln.gd -- -gconfig= -gtest=res://tests/gut/test_demo_flight_route.gd -gexit -gdisable_colors`

Expected: FAIL while the wall-clock start path remains available.

- [ ] **Step 3: Implement the minimal lifecycle**

```gdscript
func _start_demo_route_after_reset() -> void:
    var spawn := _current_spawn_marker()
    if spawn == null:
        cancel_demo_flight()
        return
    demo_flight_route.start(spawn.global_position)

# After _complete_takeoff_after_reset() succeeds:
_start_demo_route_after_reset()
```

Remove wall-clock route timing; always accumulate `maxf(delta, 0.0)` in `advance()`.

- [ ] **Step 4: Run the route test and commit**

Run the command from Step 2. Expected: PASS.

```bash
git add common/flight/demo_flight_route.gd common/flight/flight_runtime.gd tests/gut/test_demo_flight_route.gd
git commit -m "fix: start demo route after reset"
```

### Task 2: Make ANGLE sticks the only flight command

**Files:**

- Modify: `common/flight/flight_runtime.gd:135-140,1598-1615,1683-1748,2343-2368,6309-6329`
- Test: `tests/gut/test_flight_runtime_load.gd:980-1048`

**Interfaces:** Consumes route `target_position` and `target_speed_mps`, plus `_configured_hover_throttle() -> float`. Produces `_demo_controls_for_frame(delta: float) -> Dictionary`, `_demo_needs_native_sync() -> bool`, and `_demo_safety_error() -> String`.

- [ ] **Step 1: Write failing native-command/HUD tests**

```gdscript
func test_demo_controls_are_angle_commands_and_drive_both_sticks() -> void:
    var controls := runtime._demo_controls_for_frame(1.0 / 60.0)
    runtime._refresh_gamepad_hud()
    assert_eq(controls.mode, "ANGLE")
    assert_gt(absf(float(controls.roll)) + absf(float(controls.pitch)), 0.25)
    assert_gt(absf(float(controls.yaw_rate)) + absf(float(controls.throttle) * 2.0 - 1.0), 0.25)
    assert_eq(display.state.roll, float(controls.roll) / FlightRuntime.ANGLE_MAX_TILT_DEGREES)
```

Extend the existing fake native with a `step_collision_angle_mode` argument recorder. Assert the HUD axes normalize those recorded `roll`, `pitch`, `yaw_rate`, and `throttle` values.

- [ ] **Step 2: Run it and verify it fails**

Run: `GODOT_BIN=/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 $GODOT_BIN --headless --path . --script addons/gut/gut_cmdln.gd -- -gconfig= -gtest=res://tests/gut/test_flight_runtime_load.gd -gexit -gdisable_colors`

Expected: FAIL while `_apply_demo_flight_pose()` supplies the visual movement.

- [ ] **Step 3: Implement bounded body-frame ANGLE feedback**

```gdscript
func _demo_needs_native_sync() -> bool:
    return not _demo_native_state_synced or (drone_body != null and drone_body.contact_seen)

func _demo_controls_for_frame(delta: float) -> Dictionary:
    var state := demo_flight_route.advance(delta, drone_body.global_position, drone_body.linear_velocity, drone_body.rotation.y)
    var error_world: Vector3 = state.target_position - drone_body.global_position
    var body_error := drone_body.global_transform.basis.inverse() * Vector3(error_world.x, 0.0, error_world.z)
    var hover := _configured_hover_throttle()
    return {
        "mode": "ANGLE",
        "throttle": clampf(hover + error_world.y * 0.08 - drone_body.linear_velocity.y * 0.04, 0.0, 1.0),
        "roll": clampf(body_error.z * 1.5, -demo_max_tilt_degrees, demo_max_tilt_degrees),
        "pitch": clampf(-body_error.x * 1.5, -demo_max_tilt_degrees, demo_max_tilt_degrees),
        "yaw_rate": clampf(yaw_error_degrees * 2.0, -ANGLE_MAX_YAW_RATE_DPS, ANGLE_MAX_YAW_RATE_DPS),
    }
```

Delete `_apply_demo_flight_pose()` and its target/heading state. Gate `_sync_native_from_drone()` with `_demo_needs_native_sync()`, but keep `step_collision_angle_mode` and its returned 17-field state publication on every frame.

- [ ] **Step 4: Add fail-closed safety**

```gdscript
func _demo_safety_error() -> String:
    if not is_finite(drone_body.global_position.y) or drone_body.linear_velocity.length() > demo_max_speed_mps:
        return "Demo Flight safety limit exceeded"
    if absf(drone_body.global_position.y - _demo_spawn_height) > demo_max_relative_altitude_m:
        return "Demo Flight altitude limit exceeded"
    return ""
```

Call `cancel_demo_flight()` before the native step when this returns an error. Define named demo limits in `FlightRuntime`; do not add airframe values.

- [ ] **Step 5: Run tests and commit**

Run the command from Step 2. Expected: PASS with `MODE: ANGLE`, captured native commands matching the HUD, and no route pose function.

```bash
git add common/flight/flight_runtime.gd tests/gut/test_flight_runtime_load.gd
git commit -m "feat: fly demo route through angle controls"
```

### Task 3: Prove physical flight and visual recording behavior

**Files:**

- Modify: `tests/gut/test_flight_runtime_load.gd:1030-1048`
- Modify: `tests/gut/test_demo_flight_route.gd`
- Modify: `common/flight/flight_runtime.gd` only when safety coverage exposes a missing guard.

**Interfaces:** Consumes final demo controls and native 17-field publication. Produces physical ANGLE Demo Flight regression coverage.

- [ ] **Step 1: Write failing physical-flight, handoff, and safety tests**

```gdscript
await get_tree().create_timer(8.0).timeout
assert_eq(runtime.flight_mode, "ANGLE")
assert_gt(runtime.drone_body.linear_velocity.length(), 0.1)
assert_gt(Vector2(displacement.x, displacement.z).length(), 1.0)
assert_lt(absf(displacement.y), 8.0)
assert_gt(absf(runtime.drone_body.rotation.x) + absf(runtime.drone_body.rotation.z), 0.01)
```

Add a one-frame `contact_seen` fixture that asserts a re-sync at Jolt handoff, and an altitude/speed limit fixture that asserts demo cancellation before another command is sent.

- [ ] **Step 2: Run the native tests and tune only named demo gains/limits**

Run: `GODOT_BIN=/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 $GODOT_BIN --headless --path . --script addons/gut/gut_cmdln.gd -- -gconfig= -gtest=res://tests/gut/test_demo_flight_route.gd,res://tests/gut/test_flight_runtime_load.gd -gexit -gdisable_colors`

Expected: PASS with a bounded low pass, nonzero native velocity, non-level travel attitude, and collision handoff.

- [ ] **Step 3: Run the full automated gate**

Run: `GODOT_BIN=/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 $GODOT_BIN --headless --path . --script addons/gut/gut_cmdln.gd -- -gconfig= -gtest=res://tests/gut/test_demo_flight_route.gd,res://tests/gut/test_flight_runtime_load.gd,res://tests/gut/test_gsp_pause_actions.gd -gexit -gdisable_colors && scripts/check_hardcoded_airframe_constants.sh`

Expected: all GUT tests pass and the airframe-constant scan is clean.

- [ ] **Step 4: Perform X11 visual verification**

Launch Godot, choose `Map`, then `Demo Flight`, and capture low-pass and orbit/climb frames. Verify the game is upper 3/5, GSP is connected in lower 2/5, HUD says `MODE: ANGLE`, drone framing matches Quick Fly, and both stick dots visibly differ between frames.

- [ ] **Step 5: Commit**

```bash
git add common/flight/flight_runtime.gd common/flight/demo_flight_route.gd tests/gut/test_demo_flight_route.gd tests/gut/test_flight_runtime_load.gd
git commit -m "test: cover native angle demo flight"
```
