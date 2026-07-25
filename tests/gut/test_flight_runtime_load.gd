extends GutTest

const InputProfiles = preload("res://common/flight/input_profiles.gd")
const GamepadDeviceState = preload("res://common/flight/gamepad_device_state.gd")
const CollisionProbeBody = preload("res://common/flight/collision_probe_body.gd")
const RatesProfile = preload("res://common/flight/rates_profile.gd")
const LanguageProfile = preload("res://common/flight/language_profile.gd")
const Localization = preload("res://common/flight/localization.gd")
const AirSimSession = preload("res://common/rpc/airsim_session.gd")
const AirSimSensorSuite = preload("res://common/rpc/airsim_sensor_suite.gd")
const Px4SitlBridge = preload("res://common/rpc/px4_sitl_bridge.gd")
const OsdProfile = preload("res://common/flight/osd_profile.gd")
const FlightRuntime = preload("res://common/flight/flight_runtime.gd")
const SmokeScene = preload("res://levels/smoke/smoke.tscn")
const StatusDiagramDebug = preload("res://common/flight/status_diagram_debug.gd")


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

    func reset_flight() -> void:
        armed = false

    func hardware_power_diagnostics() -> Dictionary:
        return {"hover_throttle": 0.30}


class FailingStepNative:
    extends FakeNative

    var step_calls := 0
    var sync_calls := 0

    func sync_flight_state(
        _position_x: float,
        _position_y: float,
        _position_z: float,
        _orientation_x: float,
        _orientation_y: float,
        _orientation_z: float,
        _orientation_w: float,
        _velocity_x: float,
        _velocity_y: float,
        _velocity_z: float,
        _angular_velocity_x: float,
        _angular_velocity_y: float,
        _angular_velocity_z: float
    ) -> void:
        sync_calls += 1

    func step_collision_angle_mode(
        _physics_hz: int,
        _substep_hz: int,
        _throttle: float,
        _roll: float,
        _pitch: float,
        _yaw_rate: float,
        _touching: bool,
        _normal_x: float,
        _normal_y: float,
        _normal_z: float,
        _impulse_x: float,
        _impulse_y: float,
        _impulse_z: float,
        _restitution: float,
        _velocity_x: float,
        _velocity_y: float,
        _velocity_z: float,
        _angular_velocity_x: float,
        _angular_velocity_y: float,
        _angular_velocity_z: float,
        _energy_limit: float
    ) -> PackedFloat64Array:
        step_calls += 1
        return PackedFloat64Array()


class FailingAtomicNative:
    extends RefCounted

    var step_calls := 0
    var error := ""

    func flight_control_armed() -> bool:
        return true

    func step_angle_mode(_physics_hz: int, _substep_hz: int, _throttle: float, _roll: float, _pitch: float, _yaw: float) -> PackedFloat64Array:
        step_calls += 1
        error = "AeroSimNative.step_angle_mode: InvalidControlOutput: simulation"
        return PackedFloat64Array()

    func last_step_error() -> String:
        return error


class SuccessfulAtomicNative:
    extends RefCounted

    var step_calls := 0

    func flight_control_armed() -> bool:
        return true

    func step_angle_mode(_physics_hz: int, _substep_hz: int, _throttle: float, _roll: float, _pitch: float, _yaw: float) -> PackedFloat64Array:
        step_calls += 1
        var row := PackedFloat64Array()
        row.resize(17)
        row[7] = 1.0
        return row

    func a5_downwash_configuration() -> Dictionary:
        return {}

    func last_step_error() -> String:
        return ""


class SecondaryAtomicNative:
    extends RefCounted

    var sync_calls := 0
    var step_calls := 0
    var error := ""

    func flight_control_armed() -> bool:
        return true

    func sync_flight_state(_position_x: float, _position_y: float, _position_z: float, _orientation_x: float, _orientation_y: float, _orientation_z: float, _orientation_w: float, _velocity_x: float, _velocity_y: float, _velocity_z: float, _angular_x: float, _angular_y: float, _angular_z: float) -> void:
        sync_calls += 1

    func step_collision_angle_mode(_physics_hz: int, _substep_hz: int, _throttle: float, _roll: float, _pitch: float, _yaw: float, _touching: bool, _normal_x: float, _normal_y: float, _normal_z: float, _impulse_x: float, _impulse_y: float, _impulse_z: float, _restitution: float, _velocity_x: float, _velocity_y: float, _velocity_z: float, _angular_x: float, _angular_y: float, _angular_z: float, _energy_limit: float) -> PackedFloat64Array:
        step_calls += 1
        error = "AeroSimNative.step_collision_angle_mode: InvalidControlOutput: simulation"
        return PackedFloat64Array()

    func last_step_error() -> String:
        return error

    func set_a5_downwash_model(_enabled: bool, _radius: float, _coeff_1: float, _coeff_2: float, _coeff_3: float) -> bool:
        return true


class FakeBodyDragPanel extends Node:
    var blind_mode := false
    var paused := false

    func set_blind_mode(value: bool) -> void:
        blind_mode = value

    func set_paused(value: bool) -> void:
        paused = value


class FakeTakeoffBody extends RefCounted:
    var global_position := Vector3.ZERO
    var linear_velocity := Vector3.ZERO
    var freeze := true
    var sleeping := true

    func reset_contact() -> void:
        pass

    func apply_native_state(position: Vector3, _orientation: Quaternion, velocity: Vector3, _angular: Vector3) -> void:
        global_position = position
        linear_velocity = velocity


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


class FakeLicenseProvider extends Node:
    var snapshot: Dictionary
    var activation_result: Dictionary = {"ok": true}
    var refresh_result: Dictionary = {"ok": true}
    var activation_snapshot: Dictionary = {}
    var refresh_snapshot: Dictionary = {}
    var activation_calls := 0
    var refresh_calls := 0

    func _init(status: String, last_online_result := "never", fatal: Dictionary = {}) -> void:
        snapshot = {
            "ok": status in ["online_valid", "offline_grace_valid", "not_activated"],
            "status": status,
            "last_online_result": last_online_result,
        }
        if not fatal.is_empty():
            snapshot["fatal"] = fatal

    func get_snapshot() -> Dictionary:
        return snapshot.duplicate(true)

    func activate(_license_key: String) -> Dictionary:
        activation_calls += 1
        if not activation_snapshot.is_empty():
            snapshot = activation_snapshot.duplicate(true)
        return activation_result.duplicate(true)

    func refresh_online() -> Dictionary:
        refresh_calls += 1
        if not refresh_snapshot.is_empty():
            snapshot = refresh_snapshot.duplicate(true)
        return refresh_result.duplicate(true)


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


class GamepadSchemaRecoverySettingsStore extends RecoverySettingsStore:
    func load_document() -> Dictionary:
        return {"ok": false, "error": "unsupported confirmed_gamepad schema", "document": retained_document, "recovered": true}


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


func _flight_exit_event(use_gamepad: bool) -> InputEvent:
    if use_gamepad:
        var gamepad_event := InputEventJoypadButton.new()
        gamepad_event.button_index = JOY_BUTTON_B
        gamepad_event.pressed = true
        return gamepad_event
    var key_event := InputEventKey.new()
    key_event.keycode = KEY_ESCAPE
    key_event.physical_keycode = KEY_ESCAPE
    key_event.pressed = true
    return key_event


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


func _runtime_with_missing_license_config() -> FlightRuntime:
    var runtime := FlightRuntime.new()
    autofree(runtime)
    runtime.development_license_bypass = false
    runtime._configure_license_provider({})
    return runtime


func _runtime_with_license_snapshot(status: String, last_online_result := "never", fatal: Dictionary = {}) -> FlightRuntime:
    var runtime := FlightRuntime.new()
    autofree(runtime)
    runtime.development_license_bypass = false
    var provider := FakeLicenseProvider.new(status, last_online_result, fatal)
    runtime.license_provider = provider
    runtime.add_child(provider)
    return runtime


func _licensed_runtime() -> FlightRuntime:
    var runtime := _runtime_with_license_snapshot("online_valid")
    runtime.gamepad_device_state = FakeDeviceState.new(false)
    return runtime


func _attach_runtime_ui(runtime: FlightRuntime) -> FlightRuntime:
    runtime._build_main_menu()
    runtime._build_flight_hud()
    for layer in [runtime.main_menu_layer, runtime.flight_hud_layer]:
        runtime.remove_child(layer)
        get_tree().root.add_child(layer)
        autofree(layer)
    return runtime


func _interactive_runtime() -> FlightRuntime:
    return _attach_runtime_ui(_licensed_runtime())


func _menu_runtime() -> FlightRuntime:
    var runtime := _licensed_runtime()
    autofree(runtime)
    runtime._build_main_menu()
    var menu_layer := runtime.main_menu_layer
    runtime.remove_child(menu_layer)
    get_tree().root.add_child(menu_layer)
    autofree(menu_layer)
    return runtime


func _runtime_with_startup_license_path(path: String) -> FlightRuntime:
    var runtime := FlightRuntime.new()
    autofree(runtime)
    runtime.development_license_bypass = false
    runtime._build_main_menu()
    runtime._build_flight_hud()
    runtime._configure_license_provider_from_path(path)
    return runtime


func _write_license_config(path: String, public_key_path: String) -> void:
    var file := FileAccess.open(path, FileAccess.WRITE)
    file.store_string(JSON.stringify({
        "schema_version": 1,
        "issue_endpoint": "https://license.example.test/issue",
        "verify_endpoint": "https://license.example.test/verify",
        "public_key_path": public_key_path,
        "allowed_kids": ["ubuntu-2026"],
        "state_path": "user://aerosim-task-1-fix-state.json",
    }))
    file.close()


func after_each() -> void:
    Localization.set_locale(LanguageProfile.DEFAULT_LOCALE)
    for path in [
        "user://aerosim-task-1-fix-missing-key.json",
        "user://aerosim-task-1-fix-state.json",
    ]:
        DirAccess.remove_absolute(path)
        DirAccess.remove_absolute("%s.tmp" % path)


func test_production_flight_runtime_script_loads_with_airsim_rpc_dependencies() -> void:
    var runtime_script := load("res://common/flight/flight_runtime.gd")

    assert_not_null(runtime_script)


func test_quick_fly_fails_loudly_when_license_provider_configuration_fails() -> void:
    var runtime := _runtime_with_missing_license_config()
    assert_eq(runtime.screen, "license_blocked")
    runtime.quick_fly()
    assert_false(runtime.takeoff_requested)


func test_flight_setup_fly_requires_current_license_before_preflight() -> void:
    var runtimes: Array[FlightRuntime] = [
        _runtime_with_license_snapshot("revoked"),
        _runtime_with_missing_license_config(),
    ]
    for runtime in runtimes:
        runtime.flight_setup = runtime.default_flight_setup()
        runtime._fly_from_flight_setup()
        assert_eq(runtime.screen, "license_blocked")
        assert_null(runtime.loaded_map)


func test_drone_and_map_open_the_same_flight_setup_with_different_focus() -> void:
    var runtime := _licensed_runtime()
    runtime.open_flight_setup("drone")
    assert_eq(runtime.screen, "flight_setup")
    assert_eq(runtime.flight_setup_focus, "drone")
    runtime.open_flight_setup("map")
    assert_eq(runtime.flight_setup_focus, "map")


func test_drone_and_map_buttons_share_panel_and_move_actual_focus() -> void:
    var runtime := _menu_runtime()
    var panel := runtime.flight_setup_panel
    var drone_entry := runtime.main_menu_layer.get_node("Entries/Drone") as Button
    var map_entry := runtime.main_menu_layer.get_node("Entries/Map") as Button
    var drone_button := runtime.flight_setup_panel.get_node("Rows/Drone") as Button
    var map_button := runtime.flight_setup_panel.get_node("Rows/Map") as Button

    drone_entry.pressed.emit()
    assert_eq(runtime.flight_setup_panel, panel)
    assert_eq(runtime.main_menu_layer.get_viewport().gui_get_focus_owner(), drone_button)
    map_entry.pressed.emit()
    assert_eq(runtime.flight_setup_panel, panel)
    assert_eq(runtime.main_menu_layer.get_viewport().gui_get_focus_owner(), map_button)


func test_quick_fly_reapplies_default_setup_after_a_prior_setup_choice() -> void:
    var runtime := _licensed_runtime()
    runtime.apply_flight_setup({"wind_preset": "severe"})
    runtime.flight_setup["stale"] = "invalid"
    runtime.quick_fly()
    assert_eq(runtime.flight_setup, runtime.default_flight_setup())
    assert_eq(runtime.selected_wind_preset, "calm")


func test_controller_confirmation_from_menu_returns_to_menu() -> void:
    var runtime := _licensed_runtime()
    runtime.gamepad_device_state = FakeDeviceState.new()
    runtime.settings_store = QualitySettingsStore.new(null)
    runtime._build_flight_hud()
    runtime.open_controller_from_menu()
    assert_eq(runtime.screen, "controller_confirmation")
    runtime.accept_controller_confirmation()
    assert_eq(runtime.screen, "main_menu")
    assert_false(runtime.takeoff_requested)


func test_controller_fallback_and_cancel_from_menu_return_to_menu() -> void:
    var runtime := _licensed_runtime()
    runtime.gamepad_device_state = FakeDeviceState.new(false)
    runtime._build_flight_hud()
    runtime.open_controller_from_menu()
    assert_eq(runtime.screen, "fallback_prompt")
    runtime.accept_fallback()
    assert_eq(runtime.screen, "main_menu")

    runtime.gamepad_device_state = FakeDeviceState.new()
    runtime.open_controller_from_menu()
    assert_eq(runtime.screen, "controller_confirmation")
    runtime._handle_primary_action()
    assert_eq(runtime.screen, "main_menu")


func test_controller_route_exit_input_cancels_each_caller_without_requesting_exit() -> void:
    for use_gamepad in [false, true]:
        for route in ["main_menu", "controller_settings", "preflight"]:
            for fallback in [false, true]:
                var runtime := _interactive_runtime()
                runtime.settings_store = QualitySettingsStore.new(null)
                runtime.gamepad_device_state = FakeDeviceState.new(not fallback)
                if route == "main_menu":
                    (runtime.main_menu_layer.get_node("Entries/Controller") as Button).pressed.emit()
                elif route == "controller_settings":
                    runtime.show_controller_settings()
                    (runtime.main_menu_layer.get_node("ControllerSettingsPanel/Rows/ResetXboxDefault") as Button).pressed.emit()
                else:
                    (runtime.main_menu_layer.get_node("Entries/QuickFly") as Button).pressed.emit()
                assert_eq(runtime.screen, "fallback_prompt" if fallback else "controller_confirmation", "%s/%s starts the expected route" % [route, "B" if use_gamepad else "Escape"])
                runtime._unhandled_input(_flight_exit_event(use_gamepad))
                assert_eq(runtime.screen, "controller_settings" if route == "controller_settings" else "main_menu", "%s/%s cancels to its caller" % [route, "B" if use_gamepad else "Escape"])
                assert_false(runtime.exit_requested, "%s/%s does not request cleanup exit" % [route, "B" if use_gamepad else "Escape"])
                if route == "controller_settings":
                    var reset_button := runtime.main_menu_layer.get_node("ControllerSettingsPanel/Rows/ResetXboxDefault") as Button
                    assert_eq(runtime.main_menu_layer.get_viewport().gui_get_focus_owner(), reset_button, "%s/%s returns focus to Controller Settings reset" % ["fallback" if fallback else "confirmation", "B" if use_gamepad else "Escape"])


func test_controller_route_completion_rechecks_current_license_before_preflight() -> void:
    var confirmation_runtime := _interactive_runtime()
    confirmation_runtime.settings_store = QualitySettingsStore.new(null)
    confirmation_runtime.gamepad_device_state = FakeDeviceState.new()
    (confirmation_runtime.main_menu_layer.get_node("Entries/QuickFly") as Button).pressed.emit()
    assert_eq(confirmation_runtime.screen, "controller_confirmation")
    (confirmation_runtime.license_provider as FakeLicenseProvider).snapshot = {"ok": false, "status": "revoked"}
    confirmation_runtime.accept_controller_confirmation()
    assert_eq(confirmation_runtime.screen, "license_blocked")
    assert_null(confirmation_runtime.loaded_map)

    var fallback_runtime := _interactive_runtime()
    fallback_runtime.gamepad_device_state = FakeDeviceState.new(false)
    (fallback_runtime.main_menu_layer.get_node("Entries/QuickFly") as Button).pressed.emit()
    assert_eq(fallback_runtime.screen, "fallback_prompt")
    (fallback_runtime.license_provider as FakeLicenseProvider).snapshot = {"ok": false, "status": "offline_grace_expired"}
    fallback_runtime.accept_fallback()
    assert_eq(fallback_runtime.screen, "license_blocked")
    assert_null(fallback_runtime.loaded_map)


func test_controller_route_focuses_its_visible_primary_action() -> void:
    var confirmation_runtime := _interactive_runtime()
    confirmation_runtime.gamepad_device_state = FakeDeviceState.new()
    (confirmation_runtime.main_menu_layer.get_node("Entries/Controller") as Button).pressed.emit()
    var confirm_button := confirmation_runtime.flight_hud_layer.get_node("ControllerConfirmation/Rows/UseXboxDefaultProfile") as Button
    assert_eq(confirmation_runtime.main_menu_layer.get_viewport().gui_get_focus_owner(), confirm_button)

    var fallback_runtime := _interactive_runtime()
    fallback_runtime.gamepad_device_state = FakeDeviceState.new(false)
    (fallback_runtime.main_menu_layer.get_node("Entries/Controller") as Button).pressed.emit()
    assert_eq(fallback_runtime.main_menu_layer.get_viewport().gui_get_focus_owner(), fallback_runtime.arm_takeoff_button)


func test_lab_mode_button_reuses_runtime_and_visible_back_control_returns_to_menu() -> void:
    var runtime := _interactive_runtime()
    var native_before := FakeNative.new()
    runtime.native = native_before
    var lab_button := runtime.main_menu_layer.get_node("Entries/LabMode") as Button
    lab_button.pressed.emit()
    assert_eq(runtime.screen, "lab_mode")
    assert_eq(runtime.dashboard_layout_mode, "full")
    assert_same(runtime.native, native_before)
    var back_button := runtime.flight_hud_layer.get_node_or_null("StatusMargin/StatusPanel/StatusRows/LabBack") as Button
    assert_not_null(back_button)
    assert_true(back_button.visible)
    assert_eq(runtime.main_menu_layer.get_viewport().gui_get_focus_owner(), back_button)
    back_button.pressed.emit()
    assert_eq(runtime.screen, "main_menu")
    assert_eq(runtime.dashboard_layout_mode, "compact")


func test_main_menu_exposes_the_ordered_cap006_entries_and_defaults() -> void:
    var runtime := _licensed_runtime()
    assert_eq(runtime.main_menu_entries, ["Quick Fly", "Lab Mode", "Controller", "Drone", "Map", "Settings", "Quit"])
    assert_eq(runtime.default_flight_setup(), {
        "hardware_preset": "res://config/drones/5_inch_6s.json",
        "map_id": "industrial_yard",
        "mode": "ANGLE",
        "wind_preset": "calm",
    })


func test_flight_setup_localizes_dynamic_mode_values() -> void:
    var runtime := _licensed_runtime()
    runtime._build_main_menu()
    Localization.set_locale("zh_TW")
    runtime.flight_setup = runtime.default_flight_setup()
    runtime._refresh_flight_setup_panel()

    var mode_label := runtime.main_menu_layer.get_node("FlightSetupPanel/Rows/Mode") as Label
    assert_eq(mode_label.text, "模式：角度")

    runtime.flight_setup["mode"] = "ACRO"
    runtime._refresh_flight_setup_panel()
    assert_eq(mode_label.text, "模式：特技")


func test_px4_hud_localizes_finite_state_and_diagnostic() -> void:
    var runtime := FlightRuntime.new()
    autofree(runtime)
    var bridge := Px4SitlBridge.new()
    bridge.state = "starting"
    bridge._message = "waiting for PX4 heartbeat"
    runtime.px4_sitl_bridge = bridge
    Localization.set_locale("zh_TW")

    var status := runtime._px4_status_text()
    assert_string_contains(status, "PX4")
    assert_string_contains(status, "啟動中")
    assert_string_contains(status, "等待 PX4 心跳")
    assert_false(status.contains("STARTING"))
    assert_false(status.contains("waiting for PX4 heartbeat"))

    var visible_messages := [
        "PX4 disarmed",
        "PX4 is not connected",
        "PX4 SITL requires UseTcp=true",
        "PX4 SITL bridge requires VehicleType PX4Multirotor",
        "PX4 SITL bridge does not support serial/HITL transport",
        "PX4 SITL bridge ports must be in the range 1..65535",
        "PX4 SITL bridge timeouts must be positive and ordered",
        "PX4 heartbeat received; awaiting actuator output",
        "PX4 simulator TCP connection failed: 7",
        "PX4 control UDP bind failed on 127.0.0.1:14540: 98",
        "PX4 authority is inactive",
        "PX4 command 400 rejected with result 4",
        "PX4 SITL does not support AirSim command 'foo' in this slice",
        "PX4 moveOnPath requires at least one waypoint",
        "PX4 actuator output is pending",
        "PX4 thrust output is pending",
        "PX4 arm failed: denied",
    ]
    for message in visible_messages:
        var localized := runtime._localize_fallback_message(message)
        assert_false(localized.contains(message))
        assert_false(localized.contains("ui."))
    var combined := runtime._localize_fallback_message(
        "PX4 SITL requires UseTcp=true; PX4 SITL bridge ports must be in the range 1..65535")
    assert_false(combined.contains("PX4 SITL requires UseTcp=true"))
    assert_false(combined.contains("PX4 SITL bridge ports must be in the range 1..65535"))
    assert_true(combined.contains("；"))
    var heartbeat_with_semicolon := runtime._localize_fallback_message("PX4 heartbeat received; awaiting actuator output")
    assert_false(heartbeat_with_semicolon.contains("awaiting actuator output"))
    assert_true(heartbeat_with_semicolon.contains("等待致動器輸出"))


func test_finite_settings_messages_are_localized_without_generic_error_prefix() -> void:
    var runtime := FlightRuntime.new()
    autofree(runtime)
    Localization.set_locale("zh_TW")

    assert_eq(runtime._localize_fallback_message("Graphics settings applied"), "圖形設定已套用")
    assert_eq(runtime._localize_fallback_message("Graphics settings save failed: disk full"), "圖形設定儲存失敗")
    assert_eq(runtime._localize_fallback_message("Settings reset to factory defaults"), "設定已恢復原廠預設")
    assert_eq(runtime._localize_fallback_message("Arm blocked: throttle_not_low"), "解鎖受阻：油門未在低位")
    assert_eq(runtime._localize_fallback_message("Respawn blocked: controller_resume_required"), "重生受阻：需要先恢復控制器")
    assert_eq(runtime._localize_fallback_message("Settings recovered to factory defaults: invalid JSON"), "設定已恢復原廠預設")
    assert_eq(runtime._localize_fallback_message("Cannot load Free Flight map missing_map: unknown map"), "無法載入 Free Flight 地圖")
    assert_eq(runtime._localize_fallback_message("Cannot reset Free Flight: no map is loaded"), "無法重設 Free Flight：尚未載入地圖")
    assert_eq(runtime._localize_fallback_message("unclassified diagnostic"), "錯誤")


func test_failed_locale_persistence_restores_previous_locale() -> void:
    if not _native_runtime_available():
        return
    var runtime := _graphics_runtime_with_store(null)
    var store := runtime.settings_store as QualitySettingsStore
    store.document["language"] = {"schema_version": LanguageProfile.SCHEMA_VERSION, "locale": "zh_TW"}
    runtime._load_player_settings()
    store.fail_save = true

    assert_false(runtime.set_locale("en"))
    assert_eq(Localization.current_locale, "zh_TW")
    assert_eq(store.document["language"].locale, "zh_TW")


func test_factory_reset_applies_default_locale_after_successful_persistence() -> void:
    if not _native_runtime_available():
        return
    var runtime := _graphics_runtime_with_store(null)
    var store := runtime.settings_store as QualitySettingsStore
    store.document["language"] = {"schema_version": LanguageProfile.SCHEMA_VERSION, "locale": "zh_TW"}
    runtime._load_player_settings()
    assert_eq(Localization.current_locale, "zh_TW")

    runtime.factory_reset_player_settings()

    assert_eq(Localization.current_locale, LanguageProfile.DEFAULT_LOCALE)
    assert_null(store.document["language"])


func test_only_online_and_offline_grace_license_snapshots_can_start_quick_fly() -> void:
    var runtime := _runtime_with_license_snapshot("offline_grace_valid")
    assert_true(runtime.can_start_quick_fly())
    runtime = _runtime_with_license_snapshot("revoked")
    assert_false(runtime.can_start_quick_fly())


func test_debug_development_bypass_allows_quick_fly_without_license() -> void:
    var runtime := _runtime_with_license_snapshot("not_activated")
    runtime.development_license_bypass = true
    assert_true(runtime.can_start_quick_fly())


func test_debug_quick_fly_routes_without_license_block() -> void:
    var runtime := _attach_runtime_ui(_runtime_with_license_snapshot("not_activated"))
    runtime.development_license_bypass = true
    runtime.gamepad_device_state = FakeDeviceState.new(false)

    runtime.quick_fly()

    assert_eq(runtime.screen, "fallback_prompt")
    assert_false(runtime.license_panel.visible)


func test_flight_hud_hints_follow_active_input_profile() -> void:
    var runtime := _attach_runtime_ui(_licensed_runtime())
    runtime.screen = "preflight"
    runtime._refresh_flight_hud()
    assert_string_contains(runtime.key_hints_label.text, "T Arm/Takeoff")

    runtime.gamepad_device_state = FakeDeviceState.new()
    runtime.session_gamepad_profile = InputProfiles.GamepadProfile.xbox_default(7, runtime.gamepad_device_state)
    runtime.session_gamepad_device_id = 7
    runtime._refresh_flight_hud()

    assert_string_contains(runtime.key_hints_label.text, "A Arm/Takeoff")
    assert_string_contains(runtime.key_hints_label.text, "RB ACRO")
    assert_false(runtime.key_hints_label.text.contains("T Arm/Takeoff"))


func test_motor_hud_stays_visible_for_minimal_osd_and_shows_paused_or_error_state() -> void:
    var runtime := _attach_runtime_ui(_licensed_runtime())
    runtime.status_diagram = StatusDiagramDebug.new()
    autofree(runtime.status_diagram)
    runtime.status_diagram._ready()
    var snapshot := {
        "vehicle_name": "DroneA",
        "timestamp_us": 1_000_000,
        "publish_count": 1,
        "snapshot_hz": 30.0,
        "source": "native_double_buffer",
        "motors": [
            {"thrust_newtons": 1.0, "speed_rad_s": 2.0, "current_a": 3.0, "saturated": false},
            {"thrust_newtons": 1.0, "speed_rad_s": 2.0, "current_a": 3.0, "saturated": false},
            {"thrust_newtons": 1.0, "speed_rad_s": 2.0, "current_a": 3.0, "saturated": false},
            {"thrust_newtons": 4.0, "speed_rad_s": 20.0 * PI, "current_a": 5.0, "saturated": false},
        ],
    }
    runtime.status_diagram.update_from_snapshot(snapshot, 1_000_000)
    runtime.screen = "flight"
    runtime.osd_profile = OsdProfile.profile_for_preset("Minimal")
    runtime._refresh_flight_hud()

    var panel := runtime.flight_hud_layer.get_node_or_null("MotorHudMargin/MotorHudPanel") as PanelContainer
    var rotors := runtime.flight_hud_layer.get_node_or_null("MotorHudMargin/MotorHudPanel/RotorTelemetryPanel") as Control
    assert_not_null(panel)
    assert_not_null(rotors)
    if panel == null or rotors == null:
        return
    assert_true(panel.is_visible_in_tree())
    assert_eq(String(rotors.motor_hud.state), "live")
    assert_eq(int(round(float(rotors.motor_hud.cells[0].speed_rad_s) * 60.0 / TAU)), 600)

    runtime.paused = true
    runtime._refresh_flight_hud()
    assert_eq(String(rotors.motor_hud.state), "unavailable")
    runtime.paused = false
    runtime.screen = "error"
    runtime.last_error_message = "AeroSimNative.step: InvalidState"
    runtime._refresh_flight_hud()
    assert_true(panel.is_visible_in_tree())
    assert_eq(String(rotors.motor_hud.state), "error")


func test_request_takeoff_does_not_inject_jump_velocity() -> void:
    var runtime := FlightRuntime.new()
    autofree(runtime)
    var fake_native := FakeNative.new()
    runtime.native = fake_native
    runtime.loaded_map_id = "industrial_yard"
    var map_root := Node3D.new()
    var spawn := Marker3D.new()
    spawn.position = Vector3(2.0, 3.0, 4.0)
    map_root.add_child(spawn)
    get_tree().root.add_child(map_root)
    autofree(map_root)
    map_root.name = "LoadedMap"
    spawn.name = "SpawnNorth"
    runtime.loaded_map = map_root
    var body := FakeTakeoffBody.new()
    runtime.drone_body = body
    runtime.session_gamepad_device_id = 7
    runtime.session_gamepad_profile = InputProfiles.GamepadProfile.new()

    runtime.request_takeoff()

    assert_true(runtime.takeoff_requested)
    assert_true(runtime.takeoff_assist_active)
    assert_eq(runtime.takeoff_assist_throttle, 0.38)
    assert_false(body.freeze)
    assert_eq(body.global_position, spawn.global_position)
    assert_eq(body.linear_velocity, Vector3.ZERO)



func test_license_routes_expose_status_actions_and_only_retry_provider_states() -> void:
    var runtime := _runtime_with_license_snapshot("not_activated")
    assert_eq(runtime.license_actions(), ["activate_license", "diagnostics", "exit"])
    var provider := runtime.license_provider as FakeLicenseProvider
    runtime._build_flight_hud()
    runtime.license_key_input.text = runtime.license_key_input.placeholder_text
    var activation: Dictionary = await runtime.activate_license("")
    assert_true(activation.ok)
    assert_eq(provider.activation_calls, 1)
    var retry_before_activation: Dictionary = await runtime.retry_license()
    assert_false(retry_before_activation.ok)
    assert_eq(provider.refresh_calls, 0)

    runtime = _runtime_with_license_snapshot("revoked")
    provider = runtime.license_provider as FakeLicenseProvider
    assert_eq(runtime.license_actions(), ["retry_license", "diagnostics", "exit"])
    await runtime.retry_license()
    assert_eq(provider.refresh_calls, 1)


func test_activation_clears_the_real_nonpersistent_input_field_after_request() -> void:
    var runtime := _runtime_with_license_snapshot("not_activated")
    runtime._build_flight_hud()
    runtime.license_key_input.text = runtime.license_key_input.placeholder_text
    assert_false(runtime.license_key_input.text.is_empty())
    await runtime.activate_license("")
    assert_true(runtime.license_key_input.text.is_empty())


func test_missing_license_config_builds_observable_blocked_ui() -> void:
    var runtime := _runtime_with_startup_license_path("user://aerosim-task-1-fix-no-config.json")
    assert_eq(runtime.screen, "license_blocked")
    assert_not_null(runtime.get_node_or_null("MainMenu"))
    assert_true(runtime.license_panel.visible)
    assert_string_contains(runtime.license_status_label.text, "LICENSE BLOCKED")
    assert_eq(runtime.license_actions(), ["exit"])
    assert_false(runtime.license_status_label.text.contains("jwt"))


func test_missing_license_public_key_builds_observable_blocked_ui() -> void:
    var config_path := "user://aerosim-task-1-fix-missing-key.json"
    _write_license_config(config_path, "res://config/license-public-key-does-not-exist.pem")
    var runtime := _runtime_with_startup_license_path(config_path)
    assert_eq(runtime.screen, "license_blocked")
    assert_true(runtime.license_panel.visible)
    assert_eq(runtime.license_actions(), ["exit"])
    assert_false(runtime.license_status_label.text.contains("jwt"))


func test_license_status_table_exposes_exact_actions_and_dispatches_retry_safely() -> void:
    var cases := [
        {"status": "online_valid", "actions": [], "activation": 0, "refresh": 0},
        {"status": "offline_grace_valid", "actions": [], "activation": 0, "refresh": 0},
        {"status": "offline_grace_expired", "actions": ["retry_license", "diagnostics", "exit"], "activation": 1, "refresh": 0},
        {"status": "invalid_token", "actions": ["retry_license", "diagnostics", "exit"], "activation": 1, "refresh": 0},
        {"status": "revoked", "actions": ["retry_license", "diagnostics", "exit"], "activation": 0, "refresh": 1},
        {"status": "not_activated", "actions": ["activate_license", "diagnostics", "exit"], "activation": 0, "refresh": 0},
    ]
    for case in cases:
        var runtime := _runtime_with_license_snapshot(String(case.status))
        runtime._build_flight_hud()
        if String(case.status) in ["offline_grace_expired", "invalid_token"]:
            runtime.license_key_input.text = runtime.license_key_input.placeholder_text
        var provider := runtime.license_provider as FakeLicenseProvider
        assert_eq(runtime.license_actions(), case.actions, case.status)
        await runtime.retry_license()
        assert_eq(provider.activation_calls, int(case.activation), case.status)
        assert_eq(provider.refresh_calls, int(case.refresh), case.status)

    var fatal := _runtime_with_license_snapshot("invalid_token", "rejected", {"kind": "config", "code": "public_key_missing"})
    fatal._build_flight_hud()
    assert_eq(fatal.license_actions(), ["exit"])
    await fatal.retry_license()
    assert_eq((fatal.license_provider as FakeLicenseProvider).activation_calls, 0)
    assert_eq((fatal.license_provider as FakeLicenseProvider).refresh_calls, 0)

    var absent := FlightRuntime.new()
    autofree(absent)
    assert_eq(absent.license_actions(), ["exit"])
    await absent.retry_license()


func test_license_actions_reconcile_snapshot_after_activation_and_refresh() -> void:
    var runtime := _runtime_with_license_snapshot("not_activated")
    runtime._build_flight_hud()
    runtime.screen = "license_blocked"
    runtime.last_error_message = "activation pending"
    runtime._refresh_flight_hud()
    var provider := runtime.license_provider as FakeLicenseProvider
    provider.activation_snapshot = {"ok": true, "status": "online_valid", "last_online_result": "accepted"}
    runtime.license_key_input.text = runtime.license_key_input.placeholder_text
    await runtime.activate_license("")
    assert_eq(runtime.screen, "main_menu")
    assert_true(runtime.last_error_message.is_empty())

    runtime = _runtime_with_license_snapshot("revoked")
    runtime._build_flight_hud()
    runtime.screen = "license_blocked"
    runtime.last_error_message = "refresh pending"
    runtime._refresh_flight_hud()
    provider = runtime.license_provider as FakeLicenseProvider
    provider.refresh_snapshot = {"ok": false, "status": "revoked", "last_online_result": "rejected"}
    await runtime.retry_license()
    assert_eq(runtime.screen, "license_blocked")
    assert_true(runtime.license_panel.visible)
    assert_string_contains(runtime.license_status_label.text, "revoked")


func test_failed_license_actions_publish_only_typed_sanitized_reason_to_diagnostics() -> void:
    var activation_runtime := _attach_runtime_ui(_runtime_with_license_snapshot("not_activated"))
    activation_runtime.screen = "license_blocked"
    var activation_provider := activation_runtime.license_provider as FakeLicenseProvider
    activation_provider.activation_result = {
        "ok": false,
        "error_type": "request",
        "error_code": "activation_rejected",
        "error": "untyped-secret-canary",
    }
    activation_provider.activation_snapshot = {"ok": false, "status": "invalid_token"}
    activation_runtime.license_key_input.text = "test-license-key"
    await activation_runtime.activate_license("")
    assert_eq(activation_runtime.last_error_message, "License request failed: activation_rejected")
    var activation_diagnostics := activation_runtime.flight_hud_layer.get_node("LicensePanel/Rows/Diagnostics") as Button
    activation_diagnostics.pressed.emit()
    assert_eq(activation_runtime.screen, "settings")
    assert_eq(activation_runtime.settings_status_label.text, "License request failed: activation_rejected")
    assert_false(activation_runtime.settings_status_label.text.contains("untyped-secret-canary"))

    var retry_runtime := _attach_runtime_ui(_runtime_with_license_snapshot("revoked"))
    retry_runtime.screen = "license_blocked"
    var retry_provider := retry_runtime.license_provider as FakeLicenseProvider
    retry_provider.refresh_result = {
        "ok": false,
        "error_type": "network",
        "error_code": "refresh_unavailable",
        "error": "untyped-refresh-canary",
    }
    retry_provider.refresh_snapshot = {"ok": false, "status": "revoked"}
    await retry_runtime.retry_license()
    assert_eq(retry_runtime.last_error_message, "License network failed: refresh_unavailable")
    var retry_diagnostics := retry_runtime.flight_hud_layer.get_node("LicensePanel/Rows/Diagnostics") as Button
    retry_diagnostics.pressed.emit()
    assert_eq(retry_runtime.settings_status_label.text, "License network failed: refresh_unavailable")
    assert_false(retry_runtime.settings_status_label.text.contains("untyped-refresh-canary"))


func test_license_key_visibility_and_clearing_follow_activation_backed_statuses() -> void:
    var cases := [
        {"status": "not_activated", "key": true, "diagnostics": true},
        {"status": "offline_grace_expired", "key": true, "diagnostics": true},
        {"status": "invalid_token", "key": true, "diagnostics": true},
        {"status": "revoked", "key": false, "diagnostics": true},
        {"status": "online_valid", "key": false, "diagnostics": false},
        {"status": "offline_grace_valid", "key": false, "diagnostics": false},
        {"status": "unknown", "key": false, "diagnostics": false},
    ]
    for case in cases:
        var runtime := _runtime_with_license_snapshot(String(case.status))
        runtime._build_flight_hud()
        runtime.screen = "license_blocked"
        runtime._refresh_flight_hud()
        assert_eq(runtime.license_key_input.visible, bool(case.key), case.status)
        var diagnostics := runtime.get_node_or_null("FlightHud/LicensePanel/Rows/Diagnostics") as Button
        assert_not_null(diagnostics)
        assert_eq(diagnostics.visible, bool(case.diagnostics), case.status)
        if bool(case.key):
            runtime.license_key_input.text = runtime.license_key_input.placeholder_text
            (runtime.license_provider as FakeLicenseProvider).snapshot = {"ok": false, "status": "revoked"}
            runtime._refresh_flight_hud()
            assert_true(runtime.license_key_input.text.is_empty(), case.status)
            assert_false(runtime.license_key_input.visible, case.status)

    var fatal := _runtime_with_license_snapshot("invalid_token", "rejected", {"kind": "config", "code": "public_key_missing"})
    fatal._build_flight_hud()
    fatal.screen = "license_blocked"
    fatal._refresh_flight_hud()
    assert_false(fatal.license_key_input.visible)
    var fatal_diagnostics := fatal.get_node_or_null("FlightHud/LicensePanel/Rows/Diagnostics") as Button
    assert_not_null(fatal_diagnostics)
    assert_false(fatal_diagnostics.visible)


func test_license_diagnostics_clears_key_and_reuses_settings_screen() -> void:
    var runtime := _runtime_with_license_snapshot("not_activated")
    runtime._build_main_menu()
    runtime._build_flight_hud()
    runtime.screen = "license_blocked"
    runtime.last_error_message = "license diagnostics requested"
    runtime._refresh_flight_hud()
    runtime.license_key_input.text = runtime.license_key_input.placeholder_text
    var diagnostics := runtime.get_node_or_null("FlightHud/LicensePanel/Rows/Diagnostics") as Button
    assert_not_null(diagnostics)
    diagnostics.pressed.emit()
    assert_true(runtime.license_key_input.text.is_empty())
    assert_eq(runtime.screen, "settings")
    assert_true(runtime.settings_panel.visible)
    assert_eq(runtime.settings_status_label.text, runtime.last_error_message)


func test_activate_license_guards_sanitized_status_before_reading_key_or_calling_provider() -> void:
    var cases := [
        {"status": "not_activated", "allowed": true},
        {"status": "offline_grace_expired", "allowed": true},
        {"status": "invalid_token", "allowed": true},
        {"status": "online_valid", "allowed": false},
        {"status": "offline_grace_valid", "allowed": false},
        {"status": "revoked", "allowed": false},
        {"status": "unknown", "allowed": false},
    ]
    for case in cases:
        var runtime := _runtime_with_license_snapshot(String(case.status))
        runtime._build_flight_hud()
        runtime.license_key_input.text = runtime.license_key_input.placeholder_text
        var provider := runtime.license_provider as FakeLicenseProvider
        var result: Dictionary = await runtime.activate_license("")
        if bool(case.allowed):
            assert_true(result.ok, case.status)
            assert_eq(provider.activation_calls, 1, case.status)
        else:
            assert_false(result.ok, case.status)
            assert_eq(result.error_code, "activation_unavailable", case.status)
            assert_eq(provider.activation_calls, 0, case.status)

    var fatal := _runtime_with_license_snapshot("invalid_token", "rejected", {"kind": "config", "code": "public_key_missing"})
    var fatal_result: Dictionary = await fatal.activate_license("")
    assert_false(fatal_result.ok)
    assert_eq(fatal_result.error_type, "fatal")
    assert_eq((fatal.license_provider as FakeLicenseProvider).activation_calls, 0)

    var absent := FlightRuntime.new()
    autofree(absent)
    var absent_result: Dictionary = await absent.activate_license("")
    assert_false(absent_result.ok)
    assert_eq(absent_result.error_type, "fatal")


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
    for _step in range(5):
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
    for _step in range(5):
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


func test_native_failure_freezes_before_airsim_runtime_side_effects() -> void:
    var runtime := FlightRuntime.new()
    autofree(runtime)
    var primary := FailingAtomicNative.new()
    var secondary := SecondaryAtomicNative.new()
    var secondary_body := RigidBody3D.new()
    runtime.add_child(secondary_body)
    runtime.native = primary
    runtime._airsim_secondary_native = secondary
    runtime.secondary_drone_body = secondary_body
    runtime._airsim_vehicle_name = "DroneA"
    runtime._airsim_vehicle_names = ["DroneA", "DroneB"]
    runtime.airsim_session = AirSimSession.new(240)
    runtime.takeoff_requested = true
    runtime._airsim_vehicle_contexts["DroneB"] = {"api_control": true, "armed": true}

    runtime._physics_process(1.0 / 240.0)

    assert_eq(primary.step_calls, 1)
    assert_eq(secondary.sync_calls, 0)
    assert_eq(runtime.airsim_session.frame_index, 0)
    assert_true(runtime.paused)
    assert_true(secondary_body.freeze)
    assert_true(secondary_body.sleeping)
    assert_eq(runtime.last_error_message, "AeroSimNative.step_angle_mode: InvalidControlOutput: simulation")


func test_secondary_native_failure_freezes_before_airsim_runtime_side_effects() -> void:
    var runtime := FlightRuntime.new()
    autofree(runtime)
    var primary := SuccessfulAtomicNative.new()
    var secondary := SecondaryAtomicNative.new()
    var secondary_body := CollisionProbeBody.new()
    autofree(secondary_body)
    get_tree().root.add_child(secondary_body)
    runtime.native = primary
    runtime._airsim_secondary_native = secondary
    runtime.secondary_drone_body = secondary_body
    runtime._airsim_vehicle_name = "DroneA"
    runtime._airsim_vehicle_names = ["DroneA", "DroneB"]
    runtime.airsim_session = AirSimSession.new(240)
    runtime.takeoff_requested = true
    runtime._airsim_vehicle_contexts["DroneB"] = {"api_control": true, "armed": true}

    runtime._physics_process(1.0 / 240.0)

    assert_eq(primary.step_calls, 1)
    assert_eq(secondary.sync_calls, 1)
    assert_eq(secondary.step_calls, 1)
    assert_eq(runtime.airsim_session.frame_index, 0)
    assert_true(runtime.paused)
    assert_true(secondary_body.freeze)
    assert_true(secondary_body.sleeping)
    assert_eq(runtime.last_error_message, "AeroSimNative.step_collision_angle_mode: InvalidControlOutput: simulation")


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
        var config_json: String = runtime._replay_canonical_json(vehicle.call("replay_vehicle_config_manifest"))
        var config_hash := String(vehicle.call("replay_manifest_hash", config_json))
        assert_true(bool(vehicle.call("set_config_hash", config_hash)))
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
    assert_true(bool(lower.call("flight_control_armed")))
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


func test_native_failure_freezes_continue_for_frames_session() -> void:
    _assert_native_failure_freezes_explicit_session(false)


func test_native_failure_freezes_continue_for_time_session() -> void:
    _assert_native_failure_freezes_explicit_session(true)


func _assert_native_failure_freezes_explicit_session(use_time: bool) -> void:
    var runtime := FlightRuntime.new()
    autofree(runtime)
    var native := FailingStepNative.new()
    var body := CollisionProbeBody.new()
    autofree(body)
    get_tree().root.add_child(body)
    runtime.native = native
    runtime.drone_body = body
    runtime.screen = "flight"
    runtime.takeoff_requested = true
    runtime._airsim_vehicle_name = "Drone1"
    runtime._airsim_vehicle_names = ["Drone1"]
    runtime.airsim_session = AirSimSession.new(240)
    runtime.airsim_sensor_suite = AirSimSensorSuite.new()
    assert_true(runtime.airsim_sensor_suite.configure({
        "Vehicles": {"Drone1": {"VehicleType": "SimpleFlight", "Sensors": {}}},
    }, ["Drone1"]).ok)
    var start: Dictionary = runtime.airsim_session.continue_for_time(2.0 / 240.0) if use_time else runtime.airsim_session.continue_for_frames(2)
    assert_true(start.ok)

    runtime._physics_process(1.0 / 240.0)
    var frame_after_failure := runtime.airsim_session.frame_index
    var sensor_samples_after_failure: int = int(runtime.airsim_sensor_suite.stats("Drone1", AirSimSensorSuite.SENSOR_IMU, "").sample_count)
    var body_position_after_failure := body.global_position

    assert_true(runtime.paused)
    assert_true(runtime.airsim_session.is_paused())
    assert_true(body.freeze)
    assert_true(body.sleeping)
    assert_eq(runtime.last_error_message, "Native simulation step failed")
    assert_eq(runtime.screen, "flight")

    runtime._process(0.0)
    runtime._physics_process(1.0 / 240.0)

    assert_eq(native.step_calls, 1)
    assert_eq(native.sync_calls, 1)
    assert_eq(runtime.airsim_session.frame_index, frame_after_failure)
    assert_eq(runtime.airsim_sensor_suite.stats("Drone1", AirSimSensorSuite.SENSOR_IMU, "").sample_count, sensor_samples_after_failure)
    assert_eq(body.global_position, body_position_after_failure)
    assert_true(body.freeze)


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
    var debug_panel := FakeBodyDragPanel.new()
    runtime.add_child(debug_panel)
    runtime.body_drag_debug_panel = debug_panel

    runtime.set_paused(true, false)
    assert_true(secondary_body.freeze)
    assert_true(secondary_body.sleeping)
    assert_true(debug_panel.paused)
    assert_false(debug_panel.blind_mode)

    runtime.set_paused(false, false)
    assert_false(secondary_body.freeze)
    assert_false(secondary_body.sleeping)
    assert_false(debug_panel.paused)
    assert_false(debug_panel.blind_mode)
    runtime.free()


func test_pause_panel_exposes_the_frozen_overlay_contract() -> void:
    var runtime := FlightRuntime.new()
    runtime.flight_hud_layer = CanvasLayer.new()
    runtime.add_child(runtime.flight_hud_layer)

    runtime._build_pause_panel()

    var names := []
    for child in runtime.pause_panel.get_node("Rows").get_children():
        if child is Button:
            names.append(String(child.name))
    assert_eq(names, [
        "Resume",
        "Reset",
        "ChangeSpawn",
        "Rates",
        "Camera",
        "OSD",
        "ControllerMonitor",
        "StatusDiagram",
        "Exit",
    ])
    runtime.free()


func test_status_diagram_from_pause_exposes_user_return_button() -> void:
    var runtime := FlightRuntime.new()
    runtime.flight_hud_layer = CanvasLayer.new()
    runtime.add_child(runtime.flight_hud_layer)

    runtime._build_pause_panel()
    runtime._show_status_diagram_from_pause()

    assert_true(runtime.status_diagram_fullscreen)
    var back_button := runtime.status_diagram_back_button as Button
    assert_not_null(back_button)
    back_button.pressed.emit()
    assert_false(runtime.status_diagram_fullscreen)
    assert_true(runtime.pause_panel.visible)
    runtime.free()


func test_respawn_preserves_armed_state_and_resets_without_disarm() -> void:
    var runtime := FlightRuntime.new()
    var map := Node3D.new()
    var spawn := Marker3D.new()
    spawn.name = "SpawnNorth"
    map.add_child(spawn)
    get_tree().root.add_child(map)
    runtime.loaded_map = map
    runtime.drone_body = CollisionProbeBody.new()
    get_tree().root.add_child(runtime.drone_body)
    runtime.native = FakeNative.new()
    runtime.native.armed = true
    runtime.screen = "flight"
    runtime.takeoff_requested = true

    runtime.respawn()

    assert_true(runtime.native.armed)
    assert_false(runtime.native.disarmed)
    assert_true(runtime.takeoff_requested)
    assert_false(runtime.paused)
    runtime.drone_body.free()
    runtime.free()
    map.queue_free()


func test_change_spawn_cycles_formal_markers_and_preserves_arm_state() -> void:
    var runtime := FlightRuntime.new()
    var map := Node3D.new()
    var north := Marker3D.new()
    north.name = "SpawnNorth"
    north.position = Vector3(0.0, 0.6, -24.0)
    map.add_child(north)
    var south := Marker3D.new()
    south.name = "SpawnSouth"
    south.position = Vector3(-24.0, 0.6, 24.0)
    map.add_child(south)
    get_tree().root.add_child(map)
    runtime.loaded_map = map
    runtime.drone_body = CollisionProbeBody.new()
    get_tree().root.add_child(runtime.drone_body)
    runtime.native = FakeNative.new()
    runtime.native.armed = true
    runtime.screen = "flight"

    runtime.change_spawn()
    assert_eq(runtime.current_spawn_index, 1)
    assert_eq(runtime.drone_body.global_position, south.global_position)
    assert_true(runtime.native.armed)

    runtime.change_spawn()
    assert_eq(runtime.current_spawn_index, 0)
    assert_eq(runtime.drone_body.global_position, north.global_position)
    assert_true(runtime.native.armed)
    runtime.drone_body.free()
    runtime.free()
    map.queue_free()


func test_fixed_xbox_reset_and_start_x_chord_use_distinct_actions() -> void:
    var runtime := FlightRuntime.new()
    var map := Node3D.new()
    var north := Marker3D.new()
    north.name = "SpawnNorth"
    north.position = Vector3(0.0, 0.6, -24.0)
    map.add_child(north)
    var south := Marker3D.new()
    south.name = "SpawnSouth"
    south.position = Vector3(-24.0, 0.6, 24.0)
    map.add_child(south)
    get_tree().root.add_child(map)
    runtime.loaded_map = map
    runtime.drone_body = CollisionProbeBody.new()
    get_tree().root.add_child(runtime.drone_body)
    runtime.native = FakeNative.new()
    runtime.native.armed = true
    runtime.screen = "flight"
    runtime.session_gamepad_device_id = 7
    runtime.session_gamepad_profile = InputProfiles.GamepadProfile.new()

    var x := InputEventJoypadButton.new()
    x.device = 7
    x.button_index = JOY_BUTTON_X
    x.pressed = true
    runtime._unhandled_input(x)
    assert_eq(runtime.current_spawn_index, 0)
    assert_eq(runtime.drone_body.global_position, north.global_position)

    var start := InputEventJoypadButton.new()
    start.device = 7
    start.button_index = JOY_BUTTON_START
    start.pressed = true
    runtime._unhandled_input(start)
    runtime._unhandled_input(x)
    assert_eq(runtime.current_spawn_index, 1)
    assert_eq(runtime.drone_body.global_position, south.global_position)

    start.pressed = false
    runtime._unhandled_input(start)
    runtime._unhandled_input(x)
    assert_eq(runtime.current_spawn_index, 1)
    assert_eq(runtime.drone_body.global_position, south.global_position)

    runtime.handle_controller_connection_changed(7, false)
    assert_false(runtime.gamepad_pause_pressed)
    runtime.drone_body.free()
    runtime.free()
    map.queue_free()


func test_respawn_preserves_armed_px4_transport_without_restart() -> void:
    var runtime := FlightRuntime.new()
    var map := Node3D.new()
    var spawn := Marker3D.new()
    spawn.name = "SpawnNorth"
    map.add_child(spawn)
    get_tree().root.add_child(map)
    runtime.loaded_map = map
    runtime.drone_body = CollisionProbeBody.new()
    var bridge := Px4SitlBridge.new()
    assert_true(bridge.configure({
        "VehicleType": "PX4Multirotor",
        "Transport": "Fake",
        "HeartbeatTimeout": 1.0,
        "FailureTimeout": 3.0,
        "ActuatorTimeout": 1.0,
        "UseSerial": false,
        "LockStep": true,
    }).ok)
    assert_true(bridge.start().ok)
    bridge.inject_heartbeat(false)
    bridge.poll(0.0)
    bridge.arm_disarm(true)
    bridge.inject_heartbeat(true)
    bridge.inject_actuators([0.5, 0.5, 0.5, 0.5])
    bridge.poll(0.01)
    runtime.px4_sitl_bridge = bridge
    runtime.screen = "flight"

    assert_eq(bridge.state, "armed")
    runtime.respawn()

    assert_eq(bridge.state, "armed")
    assert_true(bridge.is_authority_active())
    assert_true(bridge.arm_disarm(true).ok)
    runtime.drone_body.free()
    runtime.free()
    map.queue_free()


func test_participant_mode_is_independent_and_hides_debug_panel_input() -> void:
    var runtime_script := load("res://common/flight/flight_runtime.gd")
    var panel_script := load("res://addons/debug_api/aerosim_body_drag_panel.gd")
    var runtime = runtime_script.new()
    var panel = panel_script.new()
    get_tree().root.add_child(panel)
    runtime.body_drag_debug_panel = panel
    var debug_canvas: Control = panel.get("_panel")
    var focus_button := Button.new()
    debug_canvas.add_child(focus_button)
    focus_button.grab_focus()

    runtime.set_paused(true, false)
    assert_true(debug_canvas.visible)
    assert_eq(String(panel.call("_text_value", "body_drag_operating_state")), "PAUSED")

    assert_true(runtime.has_method("set_participant_mode"))
    if not runtime.has_method("set_participant_mode"):
        panel.queue_free()
        runtime.free()
        return
    runtime.set_participant_mode(true)
    assert_true(runtime.participant_mode)
    assert_false(debug_canvas.visible)
    assert_false(panel.is_processing_input())
    assert_false(panel.get("_api").is_processing_input())
    assert_ne(panel.get_viewport().gui_get_focus_owner(), focus_button)

    runtime.set_paused(false, false)
    assert_false(debug_canvas.visible)
    runtime.set_participant_mode(false)
    assert_true(debug_canvas.visible)
    assert_true(panel.is_processing_input())
    panel.call("set_screen_visible", false)
    assert_false(debug_canvas.visible)
    panel.call("set_screen_visible", true)
    assert_true(debug_canvas.visible)
    panel.queue_free()
    runtime.free()


func test_body_drag_panel_waits_for_cold_start_telemetry() -> void:
    var panel_script := load("res://addons/debug_api/aerosim_body_drag_panel.gd")
    var panel = panel_script.new()
    get_tree().root.add_child(panel)
    await get_tree().process_frame

    assert_eq(String(panel.call("_text_value", "body_drag_operating_state")), "WAITING / UNAVAILABLE")
    assert_eq(String(panel.call("_vector", "wind_world_mps")), "WAITING / UNAVAILABLE")
    assert_eq(String(panel.call("_schema_status")), "WAITING / UNAVAILABLE")
    assert_eq(String(panel.call("_timestamp_status")), "WAITING / UNAVAILABLE")
    assert_false(String(panel.call("_vector", "wind_world_mps")).contains("NaN"))
    assert_eq(int(panel.get("_panel").get_config("anchor")), 2)
    panel.queue_free()


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


func test_gamepad_save_does_not_overwrite_settings_when_load_recovers() -> void:
    var runtime_script := load("res://common/flight/flight_runtime.gd")
    var runtime = runtime_script.new()
    var recovery_store := RecoverySettingsStore.new()
    runtime.settings_store = recovery_store

    var result: Dictionary = runtime._save_gamepad_profile(InputProfiles.GamepadProfile.new())

    assert_false(result.ok)
    assert_string_contains(result.error, "unavailable")
    assert_false(recovery_store.save_called)
    assert_null(recovery_store.retained_document.confirmed_gamepad)
    assert_eq(recovery_store.retained_document.language.locale, "en")
    runtime.free()


func test_gamepad_confirmation_replaces_only_a_recovered_legacy_profile() -> void:
    var runtime := FlightRuntime.new()
    var recovery_store := GamepadSchemaRecoverySettingsStore.new()
    runtime.settings_store = recovery_store

    var result: Dictionary = runtime._save_gamepad_profile(InputProfiles.GamepadProfile.new())

    assert_true(result.ok, result.error)
    assert_true(recovery_store.save_called)
    assert_not_null(runtime.persisted_gamepad_profile)
    runtime.free()


func test_controller_monitor_renders_active_session_channels_and_unavailable_without_one() -> void:
    var runtime := _controller_monitor_runtime()
    autofree(runtime)
    runtime.native = FakeNative.new()
    await get_tree().process_frame

    runtime.show_controller_settings()

    var monitor: Label = runtime.controller_settings_monitor_label
    assert_string_contains(monitor.text, "CHANNEL MONITOR (30 Hz)")
    assert_string_contains(monitor.text, "roll:     [---------|-------] raw +0.250 | normalized +0.167")
    assert_string_contains(monitor.text, "pitch:    [--------------|--] raw -0.750 | normalized +0.694")
    assert_string_contains(monitor.text, "yaw:      [-----------|-----] raw +0.500 | normalized +0.420")
    assert_string_contains(monitor.text, "throttle: [-----------|-----] raw -0.500 | normalized +0.420 | HIGH")
    assert_string_contains(monitor.text, "DEADZONE: 0.080 (fixed)")
    assert_string_contains(monitor.text, "ARM: RELEASED | flight control: DISARMED")
    assert_string_contains(monitor.text, "MODE: RELEASED | flight mode: ANGLE")

    var low_throttle := InputEventJoypadMotion.new()
    low_throttle.device = 0
    low_throttle.axis = JOY_AXIS_LEFT_Y
    low_throttle.axis_value = 1.0
    Input.parse_input_event(low_throttle)
    await get_tree().process_frame
    runtime._refresh_controller_settings()
    assert_string_contains(monitor.text, "throttle: [|----------------] raw +1.000 | normalized -1.000 | LOW")

    var yaw_deadzone := InputEventJoypadMotion.new()
    yaw_deadzone.device = 0
    yaw_deadzone.axis = JOY_AXIS_LEFT_X
    yaw_deadzone.axis_value = 0.08
    Input.parse_input_event(yaw_deadzone)
    var roll_deadzone := InputEventJoypadMotion.new()
    roll_deadzone.device = 0
    roll_deadzone.axis = JOY_AXIS_RIGHT_X
    roll_deadzone.axis_value = -0.08
    Input.parse_input_event(roll_deadzone)
    await get_tree().process_frame
    runtime._refresh_controller_settings()
    assert_string_contains(monitor.text, "roll:     [--------|--------] raw -0.080 | normalized +0.000")
    assert_string_contains(monitor.text, "yaw:      [--------|--------] raw +0.080 | normalized +0.000")

    var throttle_boundary := InputEventJoypadMotion.new()
    throttle_boundary.device = 0
    throttle_boundary.axis = JOY_AXIS_LEFT_Y
    throttle_boundary.axis_value = 0.08
    Input.parse_input_event(throttle_boundary)
    await get_tree().process_frame
    runtime._refresh_controller_settings()
    assert_string_contains(monitor.text, "throttle: [--------|--------] raw +0.080 | normalized +0.000 | HIGH")
    throttle_boundary.axis_value = 0.92
    Input.parse_input_event(throttle_boundary)
    await get_tree().process_frame
    runtime._refresh_controller_settings()
    assert_string_contains(monitor.text, "throttle: [-|---------------] raw +0.920 | normalized -0.898 | LOW")

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
    roll.axis = JOY_AXIS_RIGHT_X
    roll.axis_value = 0.5
    Input.parse_input_event(roll)
    await get_tree().process_frame
    runtime.show_controller_settings()

    assert_string_contains(runtime.controller_settings_monitor_label.text, "roll:     [-----------|-----] raw +0.500 | normalized +0.420")
    assert_false(runtime.takeoff_requested)
    assert_false(runtime.controller_safety_latched)


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
    throttle.axis = JOY_AXIS_LEFT_Y
    throttle.axis_value = -1.0
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


func test_pure_angle_collective_uses_the_left_mode_two_vertical_axis() -> void:
    var runtime := FlightRuntime.new()
    autofree(runtime)
    runtime.session_gamepad_device_id = 0
    runtime.session_gamepad_profile = InputProfiles.GamepadProfile.new()

    var down := InputEventJoypadMotion.new()
    down.device = 0
    down.axis = JOY_AXIS_LEFT_Y
    down.axis_value = 1.0
    Input.parse_input_event(down)
    await get_tree().process_frame
    assert_almost_eq(runtime._flight_throttle(), 0.0, 0.000001)

    var up := InputEventJoypadMotion.new()
    up.device = 0
    up.axis = JOY_AXIS_LEFT_Y
    up.axis_value = -1.0
    Input.parse_input_event(up)
    await get_tree().process_frame
    assert_almost_eq(runtime._flight_throttle(), 1.0, 0.000001)


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
    runtime.arm_and_takeoff()
    assert_true(runtime.controller_safety_latched)
    runtime.free()
