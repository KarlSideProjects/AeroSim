extends SceneTree

const InputProfiles = preload("res://common/flight/input_profiles.gd")
const SmokeScene = preload("res://levels/smoke/smoke.tscn")

class InputProbe:
    extends Node

    var action := ""
    var pressed := false

    func _input(event: InputEvent) -> void:
        if event.is_action_pressed(action):
            pressed = true

func _initialize() -> void:
    call_deferred("_run")

func _run() -> void:
    var output_path := _output_path()
    var csv_output_path := _csv_output_path()
    var requested_frames := _requested_frames()
    var requested_seconds := _requested_seconds(requested_frames)
    if not await _verify_keyboard_profile_actions():
        quit(1)
        return
    if not await _verify_gamepad_profile_actions():
        quit(1)
        return
    var input_fallback_status := _input_fallback_status()
    if not input_fallback_status.contains("KeyboardProfile") or not input_fallback_status.contains("non-sim"):
        push_error("No-controller fallback status must explicitly name KeyboardProfile and non-sim control")
        quit(1)
        return

    var native: Object = ClassDB.instantiate("AeroSimNative")
    if native == null:
        push_error("AeroSimNative is not registered")
        quit(1)
        return

    var probe_value: int = native.call("probe_value")

    if probe_value != 47:
        push_error("AeroSimNative.probe_value returned %d" % probe_value)
        quit(1)
        return
    if native.call("arm_flight_control", 0.25):
        push_error("AeroSimNative.arm_flight_control must reject high throttle")
        quit(1)
        return
    if native.call("flight_control_arm_reject_code") != "throttle_not_low":
        push_error("AeroSimNative must expose a high-throttle arm rejection reason")
        quit(1)
        return
    if not _verify_flight_control_public_path(native):
        quit(1)
        return
    if not await _verify_runtime_actions():
        quit(1)
        return

    var trajectory := PackedFloat64Array()
    native.call("reset_simulation")
    for _frame in range(requested_frames):
        await physics_frame
        var row: PackedFloat64Array = native.call("step_simulation", Engine.physics_ticks_per_second, 1000, 0.0)
        trajectory.append_array(row)

    var mobile_trajectory: PackedFloat64Array = native.call("simulate_trajectory", 1.0, 120, 500, 0.0)
    var stride: int = native.call("trajectory_stride")

    if trajectory.is_empty() or mobile_trajectory.is_empty() or stride != 12:
        push_error("AeroSimNative.simulate_trajectory returned invalid data")
        quit(1)
        return

    if not _write_trajectory_csv(csv_output_path, trajectory, stride):
        quit(1)
        return

    var file := FileAccess.open(output_path, FileAccess.WRITE)
    if file == null:
        push_error("Cannot write smoke output: %s" % output_path)
        quit(1)
        return

    file.store_string(JSON.stringify({
        "schema_version": 1,
        "native_probe": probe_value,
        "physics_ticks_per_second": Engine.physics_ticks_per_second,
        "requested_seconds": float(requested_frames) / float(Engine.physics_ticks_per_second),
        "simulated_frames": requested_frames,
        "trajectory_csv": csv_output_path,
        "trajectory_stride": stride,
        "trajectory_samples": int(trajectory.size() / stride),
        "input_fallback_status": input_fallback_status,
        "desktop_substep_hz": 1000,
        "desktop_substeps": int(trajectory[trajectory.size() - 1]),
        "mobile_substep_hz": 500,
        "mobile_substeps_1s": int(mobile_trajectory[mobile_trajectory.size() - 1])
    }))
    quit(0)

func _input_fallback_status() -> String:
    return InputProfiles.fallback_status(Input.get_connected_joypads())

func _verify_flight_control_public_path(native: Object) -> bool:
    native.call("reset_flight")
    var disarmed_row: PackedFloat64Array = native.call("step_angle_mode", Engine.physics_ticks_per_second, 1000, 0.75, 0.0, 0.0, 0.0)
    if disarmed_row[2] > 0.0:
        push_error("Disarmed Angle Mode throttle must not produce lift")
        return false

    native.call("reset_flight")
    var bypass_row: PackedFloat64Array = native.call("step_simulation", Engine.physics_ticks_per_second, 1000, 1000.0)
    if bypass_row[2] > 0.0:
        push_error("Public step_simulation must not bypass arm safety with direct thrust")
        return false

    native.call("reset_flight")
    if not native.call("arm_flight_control", 0.0):
        push_error("Low throttle should arm flight control through Godot public path")
        return false
    var armed_row: PackedFloat64Array = native.call("step_angle_mode", Engine.physics_ticks_per_second, 1000, 0.75, 0.0, 0.0, 0.0)
    if armed_row[2] <= disarmed_row[2]:
        push_error("Armed Angle Mode throttle should produce lift")
        return false

    native.call("reset_flight")
    if not native.call("flight_control_armed"):
        push_error("reset_flight should keep armed state for immediate throttle follow")
        return false
    var reset_row: PackedFloat64Array = native.call("step_angle_mode", Engine.physics_ticks_per_second, 1000, 0.0, 0.0, 0.0, 0.0)
    if int(reset_row[11]) <= 0:
        push_error("reset_flight should clear the substep clock before the next step")
        return false
    return true

func _verify_runtime_actions() -> bool:
    var scene := SmokeScene.instantiate()
    root.add_child(scene)
    await process_frame
    if scene.native == null:
        push_error("Smoke runtime must instantiate AeroSimNative")
        scene.queue_free()
        return false
    if not scene.last_profile_status.contains("KeyboardProfile"):
        push_error("Smoke runtime must expose no-controller KeyboardProfile fallback UI")
        scene.queue_free()
        return false

    await _press_key(KEY_T)
    await physics_frame
    if not scene.takeoff_requested or not scene.native.call("flight_control_armed"):
        push_error("flight_takeoff action must request takeoff and arm through runtime")
        scene.queue_free()
        return false

    await _press_key(KEY_P)
    if not scene.paused:
        push_error("flight_pause action must pause runtime")
        scene.queue_free()
        return false

    await _press_key(KEY_R)
    if scene.reset_count != 1 or scene.takeoff_requested:
        push_error("flight_respawn action must reset runtime flight state")
        scene.queue_free()
        return false

    await _press_key(KEY_ESCAPE)
    if not scene.exit_requested:
        push_error("flight_exit action must request exit")
        scene.queue_free()
        return false

    scene.queue_free()
    return true

func _press_key(keycode: int) -> void:
    var event := InputEventKey.new()
    event.keycode = keycode
    event.physical_keycode = keycode
    event.pressed = true
    Input.parse_input_event(event)
    await process_frame
    event = InputEventKey.new()
    event.keycode = keycode
    event.physical_keycode = keycode
    event.pressed = false
    Input.parse_input_event(event)
    await process_frame

func _verify_keyboard_profile_actions() -> bool:
    var actions := {
        "flight_takeoff": KEY_T,
        "flight_pause": KEY_P,
        "flight_respawn": KEY_R,
        "flight_exit": KEY_ESCAPE
    }
    for action in actions:
        if not InputMap.has_action(action):
            push_error("KeyboardProfile missing InputMap action: %s" % action)
            return false

        var probe := InputProbe.new()
        probe.action = action
        probe.set_process_input(true)
        root.add_child(probe)
        await process_frame

        var event := InputEventKey.new()
        event.keycode = actions[action]
        event.physical_keycode = actions[action]
        event.pressed = true
        Input.parse_input_event(event)
        await process_frame
        if not probe.pressed:
            push_error("KeyboardProfile action did not trigger via Input.parse_input_event: %s" % action)
            probe.queue_free()
            return false

        event = InputEventKey.new()
        event.keycode = actions[action]
        event.physical_keycode = actions[action]
        event.pressed = false
        Input.parse_input_event(event)
        await process_frame
        probe.queue_free()
    return true

func _verify_gamepad_profile_actions() -> bool:
    var profile := InputProfiles.GamepadProfile.new()
    profile.apply_throttle_axis(0.7)
    profile.apply_throttle_axis(0.0)
    if not is_equal_approx(profile.throttle, 0.7):
        push_error("GamepadProfile throttle must be sticky when the stick returns to center")
        return false

    profile.apply_throttle_axis(0.02)
    if not is_equal_approx(profile.throttle, 0.7):
        push_error("GamepadProfile throttle deadzone must ignore small drift")
        return false

    var actions := {
        "flight_takeoff": JOY_BUTTON_A,
        "flight_pause": JOY_BUTTON_START,
        "flight_respawn": JOY_BUTTON_X,
        "flight_exit": JOY_BUTTON_B
    }
    for action in actions:
        if not InputMap.has_action(action):
            push_error("GamepadProfile missing InputMap action: %s" % action)
            return false

        var has_joypad_button := false
        for mapped_event in InputMap.action_get_events(action):
            if mapped_event is InputEventJoypadButton:
                has_joypad_button = true
                break
        if not has_joypad_button:
            push_error("GamepadProfile action lacks joypad binding: %s" % action)
            return false

        var probe := InputProbe.new()
        probe.action = action
        probe.set_process_input(true)
        root.add_child(probe)
        await process_frame

        var event := InputEventJoypadButton.new()
        event.button_index = actions[action]
        event.pressed = true
        Input.parse_input_event(event)
        await process_frame
        if not probe.pressed:
            push_error("GamepadProfile action did not trigger via Input.parse_input_event: %s" % action)
            probe.queue_free()
            return false

        event = InputEventJoypadButton.new()
        event.button_index = actions[action]
        event.pressed = false
        Input.parse_input_event(event)
        await process_frame
        probe.queue_free()
    return true

func _output_path() -> String:
    var args := OS.get_cmdline_user_args()
    for index in range(args.size() - 1):
        if args[index] == "--output":
            return _project_path(args[index + 1])
    return _project_path("build/headless_smoke.json")

func _csv_output_path() -> String:
    var args := OS.get_cmdline_user_args()
    for index in range(args.size() - 1):
        if args[index] == "--csv-output":
            return _project_path(args[index + 1])
    return _project_path("build/headless_trajectory.csv")

func _requested_frames() -> int:
    var frames := _int_arg("--frames", 3)
    var seconds := _float_arg("--seconds", 0.0)
    if seconds > 0.0:
        frames = ceili(seconds * float(Engine.physics_ticks_per_second))
    return maxi(frames, 1)

func _requested_seconds(requested_frames: int) -> float:
    var seconds := _float_arg("--seconds", 0.0)
    if seconds > 0.0:
        return seconds
    return float(requested_frames) / float(Engine.physics_ticks_per_second)

func _write_trajectory_csv(path: String, trajectory: PackedFloat64Array, stride: int) -> bool:
    var file := FileAccess.open(path, FileAccess.WRITE)
    if file == null:
        push_error("Cannot write trajectory CSV: %s" % path)
        return false

    file.store_line("time_s,position_x_m,position_y_m,position_z_m,orientation_x,orientation_y,orientation_z,orientation_w,velocity_x_mps,velocity_y_mps,velocity_z_mps,substeps")
    for row in range(int(trajectory.size() / stride)):
        var offset := row * stride
        var values: Array[String] = []
        for column in range(stride):
            values.append("%.10f" % trajectory[offset + column])
        file.store_line(",".join(values))
    return true

func _int_arg(name: String, default_value: int) -> int:
    var args := OS.get_cmdline_user_args()
    for index in range(args.size() - 1):
        if args[index] == name:
            return args[index + 1].to_int()
    return default_value

func _float_arg(name: String, default_value: float) -> float:
    var args := OS.get_cmdline_user_args()
    for index in range(args.size() - 1):
        if args[index] == name:
            return args[index + 1].to_float()
    return default_value

func _project_path(path: String) -> String:
    if path.is_absolute_path():
        return path
    return ProjectSettings.globalize_path("res://").path_join(path)
