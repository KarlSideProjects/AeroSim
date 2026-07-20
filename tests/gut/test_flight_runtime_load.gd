extends GutTest

const InputProfiles = preload("res://common/flight/input_profiles.gd")
const GamepadDeviceState = preload("res://common/flight/gamepad_device_state.gd")
const CollisionProbeBody = preload("res://common/flight/collision_probe_body.gd")
const RatesProfile = preload("res://common/flight/rates_profile.gd")
const AirSimSession = preload("res://common/rpc/airsim_session.gd")
const FlightRuntime = preload("res://common/flight/flight_runtime.gd")
const SmokeScene = preload("res://levels/smoke/smoke.tscn")


class FakeNative:
    extends RefCounted

    var disarmed := false
    var armed := false

    func flight_control_armed() -> bool:
        return armed

    func arm_flight_control(_timestamp: float) -> bool:
        armed = true
        return true

    func flight_control_arm_reject_code() -> String:
        return ""

    func disarm_flight_control() -> void:
        disarmed = true


class FakeDeviceState:
    extends GamepadDeviceState.DeviceState

    var supported := true

    func _init(is_supported: bool = true) -> void:
        supported = is_supported

    func is_joy_known(device_id: int) -> bool:
        return supported and device_id == 7

    func connected_joypads() -> Array[int]:
        return [7]

    func joy_name(_device_id: int) -> String:
        return "Xbox Controller" if supported else "Unknown Controller"


class RecoverySettingsStore:
    extends RefCounted

    var save_called := false
    var retained_document := {
        "schema_version": 1,
        "confirmed_gamepad": null,
        "rates": null,
        "osd": null,
        "camera": null,
        "language": {"locale": "en"},
        "quality": null,
    }

    func load_document() -> Dictionary:
        return {"ok": false, "error": "settings recovery required", "document": retained_document, "recovered": true}

    func save_document(_candidate: Dictionary) -> Dictionary:
        save_called = true
        return {"ok": true, "error": "", "document": retained_document}


class PersistedGamepadSettingsStore:
    extends RefCounted

    var document: Dictionary

    func _init(profile: Dictionary) -> void:
        document = {
            "schema_version": 1,
            "confirmed_gamepad": profile,
            "rates": null,
            "osd": null,
            "camera": null,
            "language": {"locale": "en"},
            "quality": null,
        }

    func load_document() -> Dictionary:
        return {"ok": true, "error": "", "document": document, "recovered": false}


class QualitySettingsStore:
    extends RefCounted

    var document: Dictionary
    var save_calls := 0
    var fail_save := false
    var factory_reset_calls := 0
    var fail_factory_reset := false

    var save_called: bool:
        get:
            return save_calls > 0

    func _init(render_scale: Variant) -> void:
        var quality = null if render_scale == null else {"schema_version": 1, "render_scale": render_scale}
        document = {
            "schema_version": 1,
            "confirmed_gamepad": null,
            "rates": null,
            "osd": null,
            "camera": null,
            "language": null,
            "quality": quality,
        }

    func load_document() -> Dictionary:
        return {"ok": true, "error": "", "document": document.duplicate(true), "recovered": false}

    func save_document(candidate: Dictionary) -> Dictionary:
        save_calls += 1
        if fail_save:
            return {"ok": false, "error": "test save failure", "document": document}
        document = candidate.duplicate(true)
        return {"ok": true, "error": "", "document": document, "recovered": false}

    func factory_reset() -> Dictionary:
        factory_reset_calls += 1
        if fail_factory_reset:
            return {"ok": false, "error": "test factory reset failure", "document": document}
        document = {
            "schema_version": 1,
            "confirmed_gamepad": null,
            "rates": null,
            "osd": null,
            "camera": null,
            "language": null,
            "quality": null,
        }
        return {"ok": true, "error": "", "document": document, "recovered": false}


func _graphics_runtime_with_store(render_scale: Variant) -> FlightRuntime:
    var runtime := SmokeScene.instantiate() as FlightRuntime
    get_tree().root.add_child(runtime)
    autofree(runtime)
    runtime.settings_store = QualitySettingsStore.new(render_scale)
    runtime._load_player_settings()
    return runtime


func _native_runtime_available() -> bool:
    if ClassDB.class_exists("AeroSimNative"):
        return true
    pending("native extension is intentionally unavailable in GUT recovery mode")
    return false


func _send_ui_action(action: String, device: int = -1) -> void:
    for pressed in [true, false]:
        var event := InputEventAction.new()
        event.action = action
        event.device = device
        event.pressed = pressed
        event.strength = 1.0
        Input.parse_input_event(event)


func _send_ui_action_and_wait(action: String, device: int = -1) -> void:
    _send_ui_action(action, device)
    await get_tree().process_frame


func _controller_monitor_runtime() -> FlightRuntime:
    var runtime := FlightRuntime.new()
    runtime.main_menu_layer = CanvasLayer.new()
    runtime.add_child(runtime.main_menu_layer)
    runtime._build_controller_settings_panel()
    runtime.controller_settings_panel.show()
    runtime.session_gamepad_device_id = 0
    runtime.session_gamepad_profile = InputProfiles.GamepadProfile.new()
    for axis_value in [
        {"axis": JOY_AXIS_LEFT_X, "value": 0.5},
        {"axis": JOY_AXIS_LEFT_Y, "value": -0.5},
        {"axis": JOY_AXIS_RIGHT_X, "value": 0.25},
        {"axis": JOY_AXIS_RIGHT_Y, "value": -0.75},
    ]:
        var event := InputEventJoypadMotion.new()
        event.device = 0
        event.axis = axis_value.axis
        event.axis_value = axis_value.value
        Input.parse_input_event(event)
    return runtime


func test_production_flight_runtime_script_loads_with_airsim_rpc_dependencies() -> void:
    var runtime_script := load("res://common/flight/flight_runtime.gd")

    assert_not_null(runtime_script)


func test_graphics_startup_applies_persisted_viewport_scale() -> void:
    if not _native_runtime_available():
        return
    var runtime := _graphics_runtime_with_store(0.75)

    assert_eq(runtime.render_scale, 0.75)
    assert_eq(runtime.get_viewport().scaling_3d_scale, 0.75)


func test_graphics_null_quality_uses_default_viewport_scale() -> void:
    if not _native_runtime_available():
        return
    var runtime := _graphics_runtime_with_store(null)

    assert_eq(runtime.render_scale, 1.0)
    assert_eq(runtime.get_viewport().scaling_3d_scale, 1.0)


func test_graphics_focus_moves_to_slider_on_open_and_settings_graphics_on_close() -> void:
    if not _native_runtime_available():
        return
    var runtime := _graphics_runtime_with_store(1.0)
    var graphics_button := runtime.get_node("MainMenu/SettingsPanel/Rows/Graphics") as Button
    graphics_button.pressed.emit()
    var slider := runtime.get_node("MainMenu/GraphicsPanel/Rows/RenderScale") as HSlider
    assert_eq(runtime.get_viewport().gui_get_focus_owner(), slider)
    var back_button := runtime.get_node("MainMenu/GraphicsPanel/Rows/Back") as Button
    back_button.pressed.emit()
    assert_eq(runtime.get_viewport().gui_get_focus_owner(), graphics_button)


func test_keyboard_ui_actions_reach_graphics_apply_and_return() -> void:
    if not _native_runtime_available():
        return
    var runtime := _graphics_runtime_with_store(1.0)
    var quick_fly := runtime.get_node("MainMenu/Entries/QuickFly") as Button
    assert_eq(runtime.get_viewport().gui_get_focus_owner(), quick_fly)
    for _step in range(4):
        await _send_ui_action_and_wait("ui_down")
    await _send_ui_action_and_wait("ui_accept")
    assert_eq(runtime.screen, "settings")
    var graphics_button := runtime.get_node("MainMenu/SettingsPanel/Rows/Graphics") as Button
    assert_eq(runtime.get_viewport().gui_get_focus_owner(), graphics_button)
    await _send_ui_action_and_wait("ui_accept")
    assert_eq(runtime.screen, "graphics")
    for _step in range(5):
        await _send_ui_action_and_wait("ui_left")
    assert_eq(runtime.render_scale, 0.75)
    assert_eq((runtime.get_node("MainMenu/GraphicsPanel/Rows/RenderScaleValue") as Label).text, "RENDER SCALE: 75%")
    await _send_ui_action_and_wait("ui_down")
    await _send_ui_action_and_wait("ui_accept")
    var store := runtime.settings_store as QualitySettingsStore
    assert_eq(store.document.quality.render_scale, 0.75)
    for _step in range(2):
        await _send_ui_action_and_wait("ui_down")
    await _send_ui_action_and_wait("ui_accept")
    assert_eq(runtime.screen, "settings")


func test_joypad_ui_actions_reach_graphics_apply_and_return() -> void:
    if not _native_runtime_available():
        return
    var runtime := _graphics_runtime_with_store(1.0)
    var quick_fly := runtime.get_node("MainMenu/Entries/QuickFly") as Button
    assert_eq(runtime.get_viewport().gui_get_focus_owner(), quick_fly)
    for _step in range(4):
        await _send_ui_action_and_wait("ui_down", 7)
    await _send_ui_action_and_wait("ui_accept", 7)
    assert_eq(runtime.screen, "settings")
    var graphics_button := runtime.get_node("MainMenu/SettingsPanel/Rows/Graphics") as Button
    assert_eq(runtime.get_viewport().gui_get_focus_owner(), graphics_button)
    await _send_ui_action_and_wait("ui_accept", 7)
    assert_eq(runtime.screen, "graphics")
    for _step in range(5):
        await _send_ui_action_and_wait("ui_left", 7)
    assert_eq(runtime.render_scale, 0.75)
    await _send_ui_action_and_wait("ui_down", 7)
    await _send_ui_action_and_wait("ui_accept", 7)
    var store := runtime.settings_store as QualitySettingsStore
    assert_eq(store.document.quality.render_scale, 0.75)
    for _step in range(2):
        await _send_ui_action_and_wait("ui_down", 7)
    await _send_ui_action_and_wait("ui_accept", 7)
    assert_eq(runtime.screen, "settings")


func test_graphics_preview_back_restores_the_committed_viewport_scale() -> void:
    if not _native_runtime_available():
        return
    var runtime := _graphics_runtime_with_store(1.0)
    runtime.show_graphics()
    runtime._on_render_scale_changed(0.75)
    assert_eq(runtime.render_scale, 0.75)
    var store := runtime.settings_store as QualitySettingsStore
    assert_false(store.save_called)
    runtime._close_graphics_panel()
    assert_eq(runtime.render_scale, 1.0)


func test_graphics_slider_and_reset_preview_without_persisting_and_button_signal_applies() -> void:
    if not _native_runtime_available():
        return
    var runtime := _graphics_runtime_with_store(1.0)
    runtime.show_graphics()
    var slider := runtime.get_node("MainMenu/GraphicsPanel/Rows/RenderScale") as HSlider
    var reset_button := runtime.get_node("MainMenu/GraphicsPanel/Rows/ResetDefaults") as Button
    var apply_button := runtime.get_node("MainMenu/GraphicsPanel/Rows/Apply") as Button
    slider.value = 0.75
    assert_eq(runtime.render_scale, 0.75)
    reset_button.pressed.emit()
    assert_eq(runtime.render_scale, 1.0)
    var store := runtime.settings_store as QualitySettingsStore
    assert_false(store.save_called)
    slider.value = 0.75
    apply_button.pressed.emit()
    assert_eq(store.save_calls, 1)
    assert_eq(store.document.quality.render_scale, 0.75)


func test_graphics_apply_persists_once_and_failed_apply_restores_preview() -> void:
    if not _native_runtime_available():
        return
    var runtime := _graphics_runtime_with_store(1.0)
    runtime.show_graphics()
    runtime._on_render_scale_changed(0.75)
    runtime._apply_graphics_settings()
    var store := runtime.settings_store as QualitySettingsStore
    assert_eq(store.save_calls, 1)
    assert_eq(store.document.quality.render_scale, 0.75)
    store.fail_save = true
    runtime.show_graphics()
    runtime._on_render_scale_changed(0.50)
    runtime._apply_graphics_settings()
    assert_eq(runtime.render_scale, 0.75)


func test_graphics_value_label_uses_integer_percent() -> void:
    if not _native_runtime_available():
        return
    var runtime := _graphics_runtime_with_store(0.75)
    runtime.show_graphics()

    assert_eq((runtime.get_node("MainMenu/GraphicsPanel/Rows/RenderScaleValue") as Label).text, "RENDER SCALE: 75%")


func test_factory_reset_changes_viewport_only_after_successful_persistence() -> void:
    if not _native_runtime_available():
        return
    var runtime := _graphics_runtime_with_store(0.75)
    var store := runtime.settings_store as QualitySettingsStore
    runtime.factory_reset_player_settings()
    assert_eq(store.factory_reset_calls, 1)
    assert_eq(runtime.render_scale, 1.0)
    assert_eq(runtime.get_viewport().scaling_3d_scale, 1.0)
    assert_null(store.document.quality)

    runtime._preview_render_scale(0.75)
    store.document.quality = {"schema_version": 1, "render_scale": 0.75}
    store.fail_factory_reset = true
    runtime.factory_reset_player_settings()
    assert_eq(store.factory_reset_calls, 2)
    assert_eq(runtime.render_scale, 0.75)
    assert_eq(runtime.get_viewport().scaling_3d_scale, 0.75)
    assert_eq(store.document.quality.render_scale, 0.75)


func test_exported_replay_runner_is_available_to_the_main_scene() -> void:
    var runner_script := load("res://common/flight/replay_integration_runner.gd")

    assert_not_null(runner_script)


func test_runtime_replay_records_and_replays_two_bound_native_vehicles() -> void:
    var runtime := FlightRuntime.new()
    autofree(runtime)
    if not ClassDB.class_exists("AeroSimNative"):
        pending("native extension is intentionally unavailable in GUT recovery mode")
        return
    var upper: Object = ClassDB.instantiate("AeroSimNative")
    var lower: Object = ClassDB.instantiate("AeroSimNative")
    if upper == null or lower == null:
        pending("native extension is intentionally unavailable in GUT recovery mode")
        return
    assert_not_null(upper)
    assert_not_null(lower)
    var per_motor := {
        "inertia_frd": Vector3(0.01, 0.01, 0.02),
        "position_frd": [Vector3(-0.1, 0.1, 0.0), Vector3(0.1, 0.1, 0.0), Vector3(-0.1, -0.1, 0.0), Vector3(0.1, -0.1, 0.0)],
        "spin_direction": [1.0, -1.0, -1.0, 1.0],
        "max_thrust_per_motor_newtons": 1.0,
        "max_current_per_motor_a": 1.0,
        "yaw_torque_per_newton": 0.01,
    }
    for vehicle in [upper, lower]:
        assert_true(bool(vehicle.call("set_hardware_mass_kg", 1.0)))
        assert_true(bool(vehicle.call("set_hardware_power_model", 4.0, 0.5, 0.03, 22.2, 6.0, 0.003, 4.0)))
        assert_true(bool(vehicle.call("set_hardware_telemetry_model", 10000.0, 1000.0)))
        assert_true(bool(vehicle.call("set_hardware_per_motor_model", per_motor)))
    runtime.native = upper
    runtime._airsim_secondary_native = lower
    runtime._airsim_vehicle_name = "DroneA"
    runtime._airsim_vehicle_names = ["DroneA", "DroneB"]
    runtime.airsim_session = AirSimSession.new(240)
    runtime.drone_body = CollisionProbeBody.new()
    runtime.secondary_drone_body = CollisionProbeBody.new()
    autofree(runtime.drone_body)
    autofree(runtime.secondary_drone_body)
    get_tree().root.add_child(runtime.drone_body)
    get_tree().root.add_child(runtime.secondary_drone_body)
    runtime.takeoff_requested = true
    runtime._airsim_vehicle_contexts["DroneB"] = {
        "api_control": true,
        "armed": true,
        "command_state": {},
        "hold_controls": {"mode": "ANGLE", "throttle": 0.0, "roll": 0.0, "pitch": 0.0, "yaw_rate": 0.0},
        "command_remaining_frames": 0,
    }

    runtime._begin_complete_replay_recording({"SettingsVersion": 1.2, "SimMode": "Multirotor"})
    assert_true(runtime._replay_recording_active)
    runtime._physics_process(1.0 / 240.0)
    var finish: Dictionary = runtime._finish_complete_replay_recording("gut-runtime")
    assert_true(bool(finish.get("ok", false)))
    var recorded: Dictionary = JSON.parse_string(String(finish.get("serialized", "")))
    assert_true(recorded.events.size() >= 2)
    var replay: Dictionary = runtime.replay_complete_session(
            String(finish.get("serialized", "")), runtime._replay_settings_manifest_hash,
            runtime._replay_upper_config_manifest_hash, runtime._replay_lower_config_manifest_hash)
    assert_true(bool(replay.get("ok", false)), "runtime replay failed: %s" % replay)

    var altered_manifest := recorded.duplicate(true)
    altered_manifest.vehicles[0].config.mass_kg = 1.25
    var altered_result: Dictionary = runtime.replay_complete_session(
            JSON.stringify(altered_manifest), runtime._replay_settings_manifest_hash,
            runtime._replay_upper_config_manifest_hash, runtime._replay_lower_config_manifest_hash)
    assert_false(bool(altered_result.get("ok", true)))

    var swapped_manifest := recorded.duplicate(true)
    swapped_manifest.vehicles[0].name = "DroneB"
    swapped_manifest.vehicles[1].name = "DroneA"
    var swapped_result: Dictionary = runtime.replay_complete_session(
            JSON.stringify(swapped_manifest), runtime._replay_settings_manifest_hash,
            runtime._replay_upper_config_manifest_hash, runtime._replay_lower_config_manifest_hash)
    assert_false(bool(swapped_result.get("ok", true)))


func test_runtime_rejects_more_than_two_named_vehicles_before_dashboard_setup() -> void:
    var runtime_script := load("res://common/flight/flight_runtime.gd")
    var runtime = runtime_script.new()
    var validation: Dictionary = runtime._validate_airsim_startup_settings({
        "SettingsVersion": 1.2,
        "SimMode": "Multirotor",
        "Vehicles": {
            "DroneA": {"VehicleType": "SimpleFlight"},
            "DroneB": {"VehicleType": "SimpleFlight"},
            "DroneC": {"VehicleType": "SimpleFlight"},
        },
    })

    assert_false(validation.ok)
    assert_string_contains(validation.error, "one or two")
    runtime.free()


func test_runtime_rejects_secondary_px4_without_a_second_bridge() -> void:
    var runtime_script := load("res://common/flight/flight_runtime.gd")
    var runtime = runtime_script.new()
    var validation: Dictionary = runtime._validate_airsim_startup_settings({
        "SettingsVersion": 1.2,
        "SimMode": "Multirotor",
        "Vehicles": {
            "DroneA": {"VehicleType": "SimpleFlight"},
            "DroneB": {"VehicleType": "PX4Multirotor"},
        },
    })

    assert_false(validation.ok)
    assert_string_contains(validation.error, "secondary")
    assert_string_contains(validation.error, "PX4Multirotor")
    runtime.free()


func test_single_vehicle_disables_secondary_collision_shape_and_restores_scene_ownership() -> void:
    var runtime_script := load("res://common/flight/flight_runtime.gd")
    var runtime = runtime_script.new()
    var body := RigidBody3D.new()
    body.collision_layer = 4
    body.collision_mask = 8
    var shape := CollisionShape3D.new()
    body.add_child(shape)
    runtime.add_child(body)
    runtime.secondary_drone_body = body

    runtime._set_secondary_collision_enabled(false)
    assert_eq(body.collision_layer, 0)
    assert_eq(body.collision_mask, 0)
    assert_true(shape.disabled)

    runtime._set_secondary_collision_enabled(true)
    assert_eq(body.collision_layer, 4)
    assert_eq(body.collision_mask, 8)
    assert_false(shape.disabled)
    runtime.free()


func test_set_paused_freezes_and_sleeps_secondary_until_resume() -> void:
    var runtime_script := load("res://common/flight/flight_runtime.gd")
    var runtime = runtime_script.new()
    var secondary_body := RigidBody3D.new()
    runtime.add_child(secondary_body)
    runtime.secondary_drone_body = secondary_body

    runtime.set_paused(true, false)
    assert_true(secondary_body.freeze)
    assert_true(secondary_body.sleeping)

    runtime.set_paused(false, false)
    assert_false(secondary_body.freeze)
    assert_false(secondary_body.sleeping)
    runtime.free()


func test_direct_spawn_reset_clears_primary_acceleration_sampling_state() -> void:
    var runtime_script := load("res://common/flight/flight_runtime.gd")
    var runtime = runtime_script.new()
    var map := Node3D.new()
    var spawn := Marker3D.new()
    spawn.name = "SpawnNorth"
    map.add_child(spawn)
    get_tree().root.add_child(map)
    runtime.loaded_map = map
    runtime.drone_body = CollisionProbeBody.new()
    runtime._airsim_last_velocity = Vector3(4.0, 5.0, 6.0)
    runtime._airsim_linear_acceleration = Vector3(7.0, 8.0, 9.0)
    runtime._airsim_last_body_angular_velocity = Vector3(1.0, 2.0, 3.0)
    runtime._airsim_angular_acceleration = Vector3(4.0, 5.0, 6.0)

    assert_true(runtime.reset_to_spawn())

    assert_eq(runtime._airsim_last_velocity, Vector3.ZERO)
    assert_eq(runtime._airsim_linear_acceleration, Vector3.ZERO)
    assert_eq(runtime._airsim_last_body_angular_velocity, Vector3.ZERO)
    assert_eq(runtime._airsim_angular_acceleration, Vector3.ZERO)
    runtime.drone_body.free()
    runtime.free()
    map.queue_free()


func test_rates_save_does_not_overwrite_settings_when_load_recovers() -> void:
    var runtime_script := load("res://common/flight/flight_runtime.gd")
    var runtime = runtime_script.new()
    var recovery_store := RecoverySettingsStore.new()
    runtime.settings_store = recovery_store

    var result: Dictionary = runtime._save_rates_profile(RatesProfile.default_profile())

    assert_false(result.ok)
    assert_string_contains(result.error, "unavailable")
    assert_false(recovery_store.save_called)
    assert_eq(recovery_store.retained_document.language.locale, "en")
    assert_null(recovery_store.retained_document.rates)
    runtime.free()


func test_controller_monitor_renders_active_session_channels_and_unavailable_without_one() -> void:
    var runtime := _controller_monitor_runtime()
    autofree(runtime)
    runtime.native = FakeNative.new()
    await get_tree().process_frame

    runtime.show_controller_settings()

    var monitor: Label = runtime.controller_settings_monitor_label
    assert_string_contains(monitor.text, "CHANNEL MONITOR (30 Hz)")
    assert_string_contains(monitor.text, "roll:     [------------|----] raw +0.500 | normalized +0.457")
    assert_string_contains(monitor.text, "pitch:    [------------|----] raw -0.500 | normalized +0.457")
    assert_string_contains(monitor.text, "yaw:      [---------|-------] raw +0.250 | normalized +0.185")
    assert_string_contains(monitor.text, "throttle: [--|--------------] raw -0.750 | normalized -0.728 | LOW")
    assert_string_contains(monitor.text, "DEADZONE: 0.080 (fixed)")
    assert_string_contains(monitor.text, "ARM: RELEASED | flight control: DISARMED")
    assert_string_contains(monitor.text, "MODE: RELEASED | flight mode: ANGLE")

    var high_throttle := InputEventJoypadMotion.new()
    high_throttle.device = 0
    high_throttle.axis = JOY_AXIS_RIGHT_Y
    high_throttle.axis_value = 0.75
    Input.parse_input_event(high_throttle)
    await get_tree().process_frame
    runtime._refresh_controller_settings()
    assert_string_contains(monitor.text, "throttle: [--------------|--] raw +0.750 | normalized +0.728 | HIGH")

    var roll_deadzone := InputEventJoypadMotion.new()
    roll_deadzone.device = 0
    roll_deadzone.axis = JOY_AXIS_LEFT_X
    roll_deadzone.axis_value = 0.08
    Input.parse_input_event(roll_deadzone)
    var yaw_deadzone := InputEventJoypadMotion.new()
    yaw_deadzone.device = 0
    yaw_deadzone.axis = JOY_AXIS_RIGHT_X
    yaw_deadzone.axis_value = -0.08
    Input.parse_input_event(yaw_deadzone)
    await get_tree().process_frame
    runtime._refresh_controller_settings()
    assert_string_contains(monitor.text, "roll:     [--------|--------] raw +0.080 | normalized +0.000")
    assert_string_contains(monitor.text, "yaw:      [--------|--------] raw -0.080 | normalized +0.000")

    var throttle_boundary := InputEventJoypadMotion.new()
    throttle_boundary.device = 0
    throttle_boundary.axis = JOY_AXIS_RIGHT_Y
    throttle_boundary.axis_value = 0.08
    Input.parse_input_event(throttle_boundary)
    await get_tree().process_frame
    runtime._refresh_controller_settings()
    assert_string_contains(monitor.text, "throttle: [--------|--------] raw +0.080 | normalized +0.000 | LOW")
    throttle_boundary.axis_value = 0.081
    Input.parse_input_event(throttle_boundary)
    await get_tree().process_frame
    runtime._refresh_controller_settings()
    assert_string_contains(monitor.text, "throttle: [--------|--------] raw +0.081 | normalized +0.001 | HIGH")

    runtime.session_gamepad_profile = null
    runtime.session_gamepad_device_id = -1
    runtime._refresh_controller_settings()
    assert_eq(runtime.controller_settings_mapping_label.text, "FIXED XBOX MAPPING: UNAVAILABLE")
    assert_eq(monitor.text, "\n".join([
        "CHANNEL MONITOR (30 Hz)",
        "roll:     UNAVAILABLE",
        "pitch:    UNAVAILABLE",
        "yaw:      UNAVAILABLE",
        "throttle: UNAVAILABLE",
        "DEADZONE: 0.080 (fixed)",
        "ARM: UNAVAILABLE",
        "MODE: UNAVAILABLE",
    ]))


func test_startup_restores_persisted_profile_for_connected_channel_monitor() -> void:
    var runtime := FlightRuntime.new()
    autofree(runtime)
    runtime.native = FakeNative.new()
    runtime.gamepad_device_state = FakeDeviceState.new()
    var profile := InputProfiles.GamepadProfile.xbox_default(7, runtime.gamepad_device_state)
    runtime.settings_store = PersistedGamepadSettingsStore.new(profile.to_persisted_dict())
    runtime.main_menu_layer = CanvasLayer.new()
    runtime.add_child(runtime.main_menu_layer)
    runtime._build_controller_settings_panel()
    runtime.controller_settings_panel.show()
    runtime._load_player_settings()
    runtime._restore_startup_gamepad_session()

    assert_eq(runtime.screen, "main_menu")
    assert_eq(runtime.session_gamepad_device_id, 7)
    assert_not_null(runtime.session_gamepad_profile)

    var roll := InputEventJoypadMotion.new()
    roll.device = 7
    roll.axis = JOY_AXIS_LEFT_X
    roll.axis_value = 0.5
    Input.parse_input_event(roll)
    await get_tree().process_frame
    runtime.show_controller_settings()

    assert_string_contains(runtime.controller_settings_monitor_label.text, "roll:     [------------|----] raw +0.500 | normalized +0.457")
    assert_false(runtime.takeoff_requested)
    assert_false(runtime.controller_safety_latched)
    if runtime.session_gamepad_profile != null:
        runtime.session_gamepad_profile.throttle = 0.8
        assert_eq(runtime.persisted_gamepad_profile.throttle, 0.0)


func test_startup_restore_requires_unlatched_supported_device() -> void:
    var profile := InputProfiles.GamepadProfile.xbox_default(7, FakeDeviceState.new())

    var latched := FlightRuntime.new()
    autofree(latched)
    latched.gamepad_device_state = FakeDeviceState.new()
    latched.persisted_gamepad_profile = InputProfiles.GamepadProfile.from_persisted_dict(profile.to_persisted_dict())
    latched.controller_safety_latched = true
    latched.paused = true
    latched.screen = "controller_disconnected"
    latched._restore_startup_gamepad_session()

    assert_null(latched.session_gamepad_profile)
    assert_eq(latched.session_gamepad_device_id, -1)
    assert_true(latched.controller_safety_latched)
    assert_true(latched.paused)
    assert_eq(latched.screen, "controller_disconnected")

    var unsupported := FlightRuntime.new()
    autofree(unsupported)
    unsupported.gamepad_device_state = FakeDeviceState.new(false)
    unsupported.persisted_gamepad_profile = InputProfiles.GamepadProfile.from_persisted_dict(profile.to_persisted_dict())
    unsupported._restore_startup_gamepad_session()

    assert_null(unsupported.session_gamepad_profile)
    assert_eq(unsupported.session_gamepad_device_id, -1)


func test_high_throttle_arm_button_stays_pressed_without_arming_native_control() -> void:
    var runtime := FlightRuntime.new()
    autofree(runtime)
    var fake_native := FakeNative.new()
    runtime.native = fake_native
    runtime.screen = "preflight"
    runtime.session_gamepad_device_id = 0
    runtime.session_gamepad_profile = InputProfiles.GamepadProfile.new()

    var throttle := InputEventJoypadMotion.new()
    throttle.device = 0
    throttle.axis = JOY_AXIS_RIGHT_Y
    throttle.axis_value = 0.75
    Input.parse_input_event(throttle)
    await get_tree().process_frame
    var arm := InputEventJoypadButton.new()
    arm.device = 0
    arm.button_index = JOY_BUTTON_A
    arm.pressed = true

    assert_true(runtime._handle_gamepad_button(arm))
    assert_true(runtime.session_gamepad_profile.arm_pressed)
    assert_false(fake_native.armed)
    assert_false(runtime._flight_control_armed())


func test_controller_disconnect_latches_disarm_freeze_and_blocks_keyboard_resume() -> void:
    var runtime_script := load("res://common/flight/flight_runtime.gd")
    var runtime = runtime_script.new()
    var fake_native := FakeNative.new()
    runtime.native = fake_native
    runtime.screen = "flight"
    runtime.takeoff_requested = true
    runtime.session_gamepad_device_id = 7
    runtime.session_gamepad_profile = InputProfiles.GamepadProfile.new()

    runtime.handle_controller_connection_changed(7, false)

    assert_true(runtime.controller_safety_latched)
    assert_false(runtime.takeoff_requested)
    assert_true(runtime.paused)
    assert_eq(runtime.screen, "controller_disconnected")
    assert_null(runtime.session_gamepad_profile)
    assert_eq(runtime.session_gamepad_device_id, -1)
    assert_true(fake_native.disarmed)

    runtime.arm_and_takeoff()
    assert_true(runtime.controller_safety_latched)
    assert_false(runtime.takeoff_requested)
    runtime.respawn()
    assert_true(runtime.controller_safety_latched)
    assert_false(runtime.takeoff_requested)
    assert_false(runtime._airsim_arm_disarm(true, "").ok)
    assert_false(runtime._airsim_command("takeoff", [], "").ok)
    runtime.free()


func test_controller_reconnect_restores_profile_but_not_authority() -> void:
    var runtime_script := load("res://common/flight/flight_runtime.gd")
    var runtime = runtime_script.new()
    runtime.native = FakeNative.new()
    runtime.gamepad_device_state = FakeDeviceState.new()
    runtime.persisted_gamepad_profile = InputProfiles.GamepadProfile.new()
    runtime.screen = "flight"
    runtime.takeoff_requested = true
    runtime.session_gamepad_device_id = 7
    runtime.session_gamepad_profile = InputProfiles.GamepadProfile.new()

    runtime.handle_controller_connection_changed(7, false)
    runtime.handle_controller_connection_changed(7, true)

    assert_true(runtime.controller_safety_latched)
    assert_true(runtime.controller_reconnected)
    assert_true(runtime.paused)
    assert_false(runtime.takeoff_requested)
    assert_eq(runtime.screen, "preflight")
    assert_not_null(runtime.session_gamepad_profile)
    assert_eq(runtime.session_gamepad_device_id, 7)
    runtime.session_gamepad_profile.throttle = 0.8
    assert_eq(runtime.persisted_gamepad_profile.throttle, 0.0)
    runtime.arm_and_takeoff()
    assert_true(runtime.controller_safety_latched)
    runtime.free()
