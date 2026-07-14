extends Node3D

const InputProfiles = preload("res://common/flight/input_profiles.gd")
const GamepadDeviceState = preload("res://common/flight/gamepad_device_state.gd")
const HardwareConfig = preload("res://common/flight/hardware_config.gd")
const StatusDiagramDebug = preload("res://common/flight/status_diagram_debug.gd")
const AirSimRpcServer = preload("res://common/rpc/airsim_rpc_server.gd")
const AirSimSession = preload("res://common/rpc/airsim_session.gd")
const AirSimCoordinateContract = preload("res://common/rpc/airsim_coordinate_contract.gd")
const DEFAULT_HARDWARE_PRESET := "res://config/drones/5_inch_6s.json"
const SPAWN_POSITION := Vector3(-1.0, 0.0, 0.0)
const TAKEOFF_VELOCITY := Vector3(0.0, 6.0, 0.0)
const KEYBOARD_FLIGHT_THROTTLE := 0.75
const ACRO_RC_RATE := 1.0
const ACRO_SUPER_RATE := 13.0 / 18
const ACRO_EXPO := 0.0
const ANGLE_MAX_TILT_DEGREES := 30.0
const ANGLE_MAX_YAW_RATE_DPS := 180.0
const GAMEPAD_BUTTON_DEBOUNCE_MS := 50
const CHASE_CAMERA_OFFSET := Vector3(-3.0, 1.4, 2.2)
const KEY_HINTS_TEXT := "T Arm/Takeoff   P Pause   R Reset   H Alt Hold   Esc Exit"

@onready var fallback_status_label: Label3D = %FallbackStatus
@onready var drone_body = get_node_or_null("DroneBody")
@onready var chase_camera := get_node_or_null("ChaseCamera") as Camera3D

var native: Object
var airsim_session: AirSimSession
var airsim_rpc_server: AirSimRpcServer
var airsim_stop_file := ""
var paused := false
var exit_requested := false
var quit_on_exit := true
var takeoff_requested := false
var reset_count := 0
var last_profile_status := ""
var main_menu_entries := ["Quick Fly", "Controller", "Drone", "Map", "Settings"]
var screen := "main_menu"
var last_error_message := ""
var last_collision_authority := -1
var collision_handoff_count := 0
var reset_hold_frames := 0
var flight_mode := "ANGLE"
var acro_roll_stick := 0.0
var acro_pitch_stick := 0.0
var acro_yaw_stick := 0.0
var status_diagram: CanvasLayer
var main_menu_layer: CanvasLayer
var main_menu_entries_container: VBoxContainer
var settings_panel: Control
var controller_settings_panel: Control
var flight_hud_layer: CanvasLayer
var key_hints_label: Label
var arm_status_label: Label
var arm_takeoff_button: Button
var session_gamepad_profile: InputProfiles.GamepadProfile
var session_gamepad_device_id := -1
var gamepad_device_state: GamepadDeviceState.DeviceState = GamepadDeviceState.DeviceState.new()
var controller_confirmation_panel: Control
var controller_confirmation_profile: InputProfiles.GamepadProfile
var controller_confirmation_device_id := -1
var confirmation_mapping_label: Label
var confirmation_axes_label: Label
var controller_settings_device_label: Label
var controller_settings_mapping_label: Label
var controller_settings_deadzone_label: Label
var controller_settings_button_status_label: Label
var last_arm_button_press_ms := -1000000
var last_mode_button_press_ms := -1000000
var gamepad_button_time_source: Callable
var _airsim_vehicle_name := ""
var _airsim_api_control := false
var _airsim_disarm_requested := false
var _airsim_command_state: Dictionary = {}
var _airsim_hold_controls: Dictionary = {}
var _airsim_command_remaining_frames := 0
var _airsim_last_velocity := Vector3.ZERO
var _airsim_linear_acceleration := Vector3.ZERO
var _airsim_last_body_angular_velocity := Vector3.ZERO
var _airsim_angular_acceleration := Vector3.ZERO
var _airsim_collision_seen := false
var _airsim_contact_this_frame := false
var _airsim_collision_normal := Vector3.ZERO
var _airsim_collision_point := Vector3.ZERO

func _ready() -> void:
    Input.joy_connection_changed.connect(_on_joy_connection_changed)
    _build_main_menu()
    _build_flight_hud()
    _build_status_diagram()
    native = ClassDB.instantiate("AeroSimNative")
    if native == null:
        push_error("AeroSimNative is not registered")
        return
    if drone_body != null:
        _reset_drone_body()
    airsim_session = AirSimSession.new(Engine.physics_ticks_per_second)
    airsim_rpc_server = AirSimRpcServer.new()
    airsim_rpc_server.set_session(airsim_session, Callable(self, "respawn"))
    add_child(airsim_rpc_server)
    airsim_stop_file = _cold_start_arg("--airsim-stop-file")
    var airsim_port := int(_cold_start_arg("--airsim-rpc-port", str(AirSimRpcServer.DEFAULT_PORT)))
    var startup_settings := {
        "SettingsVersion": 1.2,
        "SimMode": "Multirotor",
        "ApiServerPort": airsim_port,
        "RpcEnabled": true,
    }
    var settings_path := _cold_start_arg("--airsim-settings-file")
    if not settings_path.is_empty():
        var settings_file := FileAccess.open(settings_path, FileAccess.READ)
        if settings_file == null:
            push_error("AirSim settings file could not be opened: %s" % settings_path)
            get_tree().quit(1)
            return
        else:
            var parsed_settings = JSON.parse_string(settings_file.get_as_text())
            settings_file.close()
            if typeof(parsed_settings) != TYPE_DICTIONARY:
                push_error("AirSim settings file must contain a JSON object")
                get_tree().quit(1)
                return
            else:
                startup_settings = parsed_settings
    var configured_vehicles = startup_settings.get("Vehicles", {})
    if typeof(configured_vehicles) == TYPE_DICTIONARY and configured_vehicles.size() > 1:
        push_error("AirSim RPC currently exposes exactly one physical vehicle")
        get_tree().quit(1)
        return
    if typeof(configured_vehicles) == TYPE_DICTIONARY and configured_vehicles.size() == 1:
        _airsim_vehicle_name = String(configured_vehicles.keys()[0])
    airsim_rpc_server.set_vehicle_backend(
        Callable(self, "_airsim_state"),
        Callable(self, "_airsim_command"),
        Callable(self, "_airsim_enable_api_control"),
        Callable(self, "_airsim_arm_disarm"),
        Callable(self, "_airsim_cancel_task"),
        Callable(self, "_airsim_task_complete")
    )
    var rpc_result: Dictionary = airsim_rpc_server.start_with_settings(startup_settings)
    if not rpc_result.ok:
        push_error("AirSim RPC startup failed: %s" % rpc_result.error)
    else:
        _write_airsim_ready_marker(_cold_start_arg("--airsim-ready-file"))
    var hardware_config := HardwareConfig.new()
    if not hardware_config.apply_to_runtime(self, DEFAULT_HARDWARE_PRESET):
        last_error_message = hardware_config.last_error
        push_error("Default hardware preset failed: %s" % hardware_config.last_error)
    update_fallback_status()
    _update_chase_camera()
    _refresh_flight_hud()
    call_deferred("_run_cold_start_probe")

func _run_cold_start_probe() -> void:
    var report_path := _cold_start_report_path()
    if report_path.is_empty():
        return
    quick_fly()
    accept_fallback()
    await RenderingServer.frame_post_draw
    var screenshot_path := _cold_start_arg("--aerosim-cold-start-screenshot")
    var screenshot := get_viewport().get_texture().get_image()
    var screenshot_written := not screenshot_path.is_empty() and screenshot.save_png(screenshot_path) == OK
    var result := {
        "display_driver": DisplayServer.get_name(),
        "flyable": native != null and screen == "preflight" and not takeoff_requested and not paused and screenshot_written and _cold_start_frame_is_observable(screenshot),
        "frame_post_draw": true,
        "screen": screen,
        "screenshot": screenshot_path,
        "screenshot_written": screenshot_written,
    }
    var report := FileAccess.open(report_path, FileAccess.WRITE)
    if report == null:
        push_error("Cannot write cold-start report: %s" % report_path)
        get_tree().quit(1)
        return
    report.store_string(JSON.stringify(result))
    report.close()
    if bool(result["flyable"]):
        await get_tree().create_timer(float(_cold_start_arg("--aerosim-cold-start-visible-seconds", "3"))).timeout
    get_tree().quit(0 if bool(result["flyable"]) else 1)

func _cold_start_report_path() -> String:
    return _cold_start_arg("--aerosim-cold-start-report")

func _cold_start_arg(name: String, default_value := "") -> String:
    var args := OS.get_cmdline_user_args()
    for index in range(args.size() - 1):
        if args[index] == name:
            return args[index + 1]
    return default_value

func _cold_start_frame_is_observable(image: Image) -> bool:
    if image.is_empty():
        return false
    image.convert(Image.FORMAT_RGBA8)
    var counts := {}
    var max_count := 0
    var data := image.get_data()
    for offset in range(0, data.size(), 4):
        var color := (int(data[offset]) << 16) | (int(data[offset + 1]) << 8) | int(data[offset + 2])
        counts[color] = int(counts.get(color, 0)) + 1
        max_count = maxi(max_count, int(counts[color]))
    return float(max_count) / float(image.get_width() * image.get_height()) < 0.99

func _write_airsim_ready_marker(path: String) -> void:
    if path.is_empty():
        return
    var marker := FileAccess.open(path, FileAccess.WRITE)
    if marker == null:
        push_error("Cannot write AirSim readiness marker: %s" % path)
        return
    marker.store_string("ready")
    marker.close()

func _unhandled_input(event: InputEvent) -> void:
    if event is InputEventJoypadButton and _handle_gamepad_button(event):
        return
    if event.is_action_pressed("flight_takeoff") and screen in ["preflight", "flight"]:
        arm_and_takeoff()
    elif event.is_action_pressed("flight_pause"):
        set_paused(not paused)
    elif event.is_action_pressed("flight_respawn"):
        respawn()
    elif event.is_action_pressed("flight_altitude_hold"):
        toggle_altitude_hold()
    elif event.is_action_pressed("flight_exit"):
        request_exit()

func _process(_delta: float) -> void:
    if not airsim_stop_file.is_empty() and FileAccess.file_exists(airsim_stop_file):
        get_tree().quit()
        return
    if airsim_session != null and paused != airsim_session.is_paused():
        set_paused(airsim_session.is_paused(), false)
    _update_chase_camera()
    _refresh_controller_confirmation()
    _refresh_controller_settings()
    _refresh_flight_hud()

func _physics_process(_delta: float) -> void:
    if reset_hold_frames > 0:
        reset_hold_frames -= 1
        if reset_hold_frames == 0 and drone_body != null and not paused:
            drone_body.freeze = false
            drone_body.sleeping = false
        return
    if paused:
        if airsim_session != null and not airsim_session.is_paused():
            set_paused(false, false)
        if paused:
            return
    var session_advanced := true
    if airsim_session != null:
        session_advanced = airsim_session.advance_frame()
        if not session_advanced and airsim_session.is_paused():
            set_paused(true, false)
            return
    if native == null or paused or not takeoff_requested:
        return
    _airsim_contact_this_frame = false
    if not native.call("flight_control_armed") and not _airsim_disarm_requested:
        native.call("arm_flight_control", 0.0)
    var throttle := _flight_throttle()
    var angle_roll := _angle_roll_degrees()
    var angle_pitch := _angle_pitch_degrees()
    var angle_yaw := _angle_yaw_rate_degrees_per_second()
    var acro_roll := _profile_axis("roll") if _has_active_gamepad_profile() else _acro_roll_stick()
    var acro_pitch := _profile_axis("pitch") if _has_active_gamepad_profile() else _acro_pitch_stick()
    var acro_yaw := _profile_axis("yaw") if _has_active_gamepad_profile() else _acro_yaw_stick()
    var airsim_controls := _airsim_controls_for_frame()
    if not airsim_controls.is_empty():
        throttle = float(airsim_controls.get("throttle", throttle))
        angle_roll = float(airsim_controls.get("roll", angle_roll))
        angle_pitch = float(airsim_controls.get("pitch", angle_pitch))
        angle_yaw = float(airsim_controls.get("yaw_rate", angle_yaw))
        acro_roll = float(airsim_controls.get("acro_roll", acro_roll))
        acro_pitch = float(airsim_controls.get("acro_pitch", acro_pitch))
        acro_yaw = float(airsim_controls.get("acro_yaw", acro_yaw))
        if airsim_controls.has("mode"):
            flight_mode = String(airsim_controls["mode"])
    var row: PackedFloat64Array
    if drone_body != null:
        _sync_native_from_drone()
        var energy_limit := _kinetic(drone_body.linear_velocity, drone_body.angular_velocity)
        if flight_mode == "ACRO":
            row = native.call(
                "step_collision_acro_mode",
                Engine.physics_ticks_per_second,
                1000,
                throttle,
                acro_roll,
                acro_pitch,
                acro_yaw,
                ACRO_RC_RATE,
                ACRO_SUPER_RATE,
                ACRO_EXPO,
                drone_body.contact_seen,
                drone_body.contact_normal.x,
                drone_body.contact_normal.y,
                drone_body.contact_normal.z,
                drone_body.contact_impulse.x,
                drone_body.contact_impulse.y,
                drone_body.contact_impulse.z,
                0.0,
                drone_body.linear_velocity.x,
                drone_body.linear_velocity.y,
                drone_body.linear_velocity.z,
                drone_body.angular_velocity.x,
                drone_body.angular_velocity.y,
                drone_body.angular_velocity.z,
                energy_limit
            )
        else:
            var step_method := "step_collision_altitude_hold_mode" if flight_mode == "ALTITUDE_HOLD" else "step_collision_angle_mode"
            row = native.call(
                step_method,
                Engine.physics_ticks_per_second,
                1000,
                throttle,
                angle_roll,
                angle_pitch,
                angle_yaw,
                drone_body.contact_seen,
                drone_body.contact_normal.x,
                drone_body.contact_normal.y,
                drone_body.contact_normal.z,
                drone_body.contact_impulse.x,
                drone_body.contact_impulse.y,
                drone_body.contact_impulse.z,
                0.0,
                drone_body.linear_velocity.x,
                drone_body.linear_velocity.y,
                drone_body.linear_velocity.z,
                drone_body.angular_velocity.x,
                drone_body.angular_velocity.y,
                drone_body.angular_velocity.z,
                energy_limit
            )
        if drone_body.contact_seen:
            collision_handoff_count += 1
            _airsim_contact_this_frame = true
            _airsim_collision_seen = true
            _airsim_collision_normal = drone_body.contact_normal
            _airsim_collision_point = drone_body.global_position
        drone_body.reset_contact()
    else:
        if flight_mode == "ACRO":
            row = native.call("step_acro_mode", Engine.physics_ticks_per_second, 1000, throttle, acro_roll, acro_pitch, acro_yaw, ACRO_RC_RATE, ACRO_SUPER_RATE, ACRO_EXPO)
        else:
            var free_flight_method := "step_altitude_hold_mode" if flight_mode == "ALTITUDE_HOLD" else "step_angle_mode"
            row = native.call(free_flight_method, Engine.physics_ticks_per_second, 1000, throttle, angle_roll, angle_pitch, angle_yaw)
    if row.size() >= 13:
        last_collision_authority = int(row[12])
    if drone_body != null and row.size() >= 17:
        drone_body.apply_native_state(
            Vector3(row[1], row[2], row[3]),
            Quaternion(row[4], row[5], row[6], row[7]),
            Vector3(row[8], row[9], row[10]),
            Vector3(row[14], row[15], row[16])
        )
    if airsim_session != null and airsim_session.is_paused():
        set_paused(true, false)
    if not _airsim_command_state.is_empty() and _airsim_command_remaining_frames > 0:
        _airsim_command_remaining_frames -= 1
        if _airsim_command_remaining_frames == 0 and String(_airsim_command_state.get("method", "")) in ["moveByVelocity", "moveByVelocityZ", "moveByVelocityBodyFrame", "moveByVelocityZBodyFrame", "rotateByYawRate", "moveByAngleRatesThrottle"]:
            _airsim_hold_controls = _airsim_neutral_controls()
            _airsim_command_state.clear()
    if drone_body != null:
        _airsim_linear_acceleration = (drone_body.linear_velocity - _airsim_last_velocity) * float(Engine.physics_ticks_per_second)
        var body_angular_velocity: Vector3 = drone_body.global_transform.basis.inverse() * drone_body.angular_velocity
        _airsim_angular_acceleration = (body_angular_velocity - _airsim_last_body_angular_velocity) * float(Engine.physics_ticks_per_second)
        _airsim_last_body_angular_velocity = body_angular_velocity
    else:
        _airsim_linear_acceleration = Vector3.ZERO
        _airsim_angular_acceleration = Vector3.ZERO
    _airsim_last_velocity = drone_body.linear_velocity if drone_body != null else Vector3.ZERO
    _update_status_diagram()

func request_takeoff() -> void:
    screen = "flight"
    flight_mode = "ANGLE"
    set_paused(false)
    takeoff_requested = true
    update_fallback_status()
    if drone_body != null:
        drone_body.reset_contact()
        drone_body.freeze = false
        drone_body.sleeping = false
        drone_body.apply_native_state(SPAWN_POSITION, Quaternion.IDENTITY, TAKEOFF_VELOCITY, Vector3.ZERO)
    _refresh_flight_hud()

func arm_and_takeoff() -> void:
    if native == null:
        last_error_message = "Quick Fly cannot arm: native runtime unavailable"
        screen = "error"
        _refresh_flight_hud()
        return
    if _has_active_gamepad_profile() and not _profile_throttle_is_low():
        last_error_message = "Arm blocked: throttle_not_low"
        _refresh_flight_hud()
        return
    if not native.call("flight_control_armed") and not native.call("arm_flight_control", 0.0):
        last_error_message = "Quick Fly cannot arm: %s" % native.call("flight_control_arm_reject_code")
        screen = "error"
        _refresh_flight_hud()
        return
    request_takeoff()

func request_exit() -> void:
    exit_requested = true
    screen = "exit"
    _refresh_flight_hud()
    if quit_on_exit:
        get_tree().quit()

func quick_fly() -> void:
    var device_id := _first_connected_device()
    var current_profile := InputProfiles.GamepadProfile.xbox_default(device_id, gamepad_device_state)
    if current_profile == null:
        session_gamepad_profile = null
        session_gamepad_device_id = -1
        if device_id < 0:
            _show_keyboard_fallback(InputProfiles.fallback_status([]))
        else:
            _show_keyboard_fallback("Unsupported controller; Xbox default profile is unavailable. KeyboardProfile fallback active (non-sim control)")
        return
    if session_gamepad_profile == null or session_gamepad_device_id != device_id:
        begin_controller_confirmation(device_id)
        return
    enter_preflight()

func begin_controller_confirmation(device_id: int = _first_connected_device()) -> void:
    var profile := InputProfiles.GamepadProfile.xbox_default(device_id, gamepad_device_state)
    if profile == null:
        session_gamepad_profile = null
        session_gamepad_device_id = -1
        _show_keyboard_fallback("Unsupported controller; Xbox default profile is unavailable. KeyboardProfile fallback active (non-sim control)")
        return
    controller_confirmation_device_id = device_id
    controller_confirmation_profile = profile
    screen = "controller_confirmation"
    if controller_confirmation_panel == null:
        _build_controller_confirmation()
    controller_confirmation_panel.show()
    _refresh_controller_confirmation()
    _refresh_flight_hud()

func accept_controller_confirmation() -> void:
    var profile := InputProfiles.GamepadProfile.xbox_default(controller_confirmation_device_id, gamepad_device_state)
    if profile == null:
        session_gamepad_profile = null
        session_gamepad_device_id = -1
        _show_keyboard_fallback("Unsupported controller; Xbox default profile is unavailable. KeyboardProfile fallback active (non-sim control)")
        return
    session_gamepad_profile = profile
    session_gamepad_device_id = controller_confirmation_device_id
    controller_confirmation_panel.hide()
    enter_preflight()

func use_keyboard_fallback() -> void:
    session_gamepad_profile = null
    session_gamepad_device_id = -1
    if controller_confirmation_panel != null:
        controller_confirmation_panel.hide()
    _show_keyboard_fallback("KeyboardProfile fallback selected (non-sim control)")

func _show_keyboard_fallback(message: String) -> void:
    last_error_message = message
    screen = "fallback_prompt"
    _refresh_flight_hud()

func accept_fallback() -> void:
    if screen == "fallback_prompt":
        enter_preflight()
        return
    last_error_message = "No fallback prompt is active"
    screen = "error"
    _refresh_flight_hud()

func enter_preflight() -> void:
    screen = "preflight"
    flight_mode = "ANGLE"
    takeoff_requested = false
    set_paused(false)
    if drone_body != null:
        _reset_drone_body()
    update_fallback_status()
    _refresh_flight_hud()

func respawn() -> void:
    reset_count += 1
    _airsim_api_control = false
    _airsim_disarm_requested = false
    _airsim_command_state.clear()
    _airsim_hold_controls.clear()
    _airsim_command_remaining_frames = 0
    _airsim_collision_seen = false
    _airsim_contact_this_frame = false
    _airsim_collision_normal = Vector3.ZERO
    _airsim_collision_point = Vector3.ZERO
    _airsim_last_velocity = Vector3.ZERO
    _airsim_last_body_angular_velocity = Vector3.ZERO
    _airsim_linear_acceleration = Vector3.ZERO
    _airsim_angular_acceleration = Vector3.ZERO
    screen = "flight"
    flight_mode = "ANGLE"
    takeoff_requested = true
    set_paused(false)
    if native != null:
        native.call("reset_flight")
        if native.has_method("disarm_flight_control"):
            native.call("disarm_flight_control")
    update_fallback_status()
    if drone_body != null:
        _reset_drone_body()
        # ponytail: short reset hold; replace with real throttle input state when controller profiles land.
        reset_hold_frames = 30
    _refresh_flight_hud()

func update_fallback_status() -> void:
    last_profile_status = InputProfiles.fallback_status(gamepad_device_state.connected_joypads())
    fallback_status_label.text = "%s | Mode: %s" % [last_profile_status, flight_mode]

func toggle_altitude_hold() -> void:
    if native == null or not takeoff_requested:
        return
    if flight_mode == "ALTITUDE_HOLD":
        flight_mode = "ANGLE"
    else:
        native.call("capture_altitude_hold")
        flight_mode = "ALTITUDE_HOLD"
    update_fallback_status()

func set_paused(value: bool, sync_session: bool = true) -> void:
    paused = value
    if sync_session and airsim_session != null:
        airsim_session.set_paused(value)
    if drone_body != null:
        drone_body.freeze = value
        if not value:
            drone_body.sleeping = false

func _build_main_menu() -> void:
    var layer := CanvasLayer.new()
    layer.name = "MainMenu"
    main_menu_layer = layer
    add_child(layer)

    var entries := VBoxContainer.new()
    entries.name = "Entries"
    main_menu_entries_container = entries
    layer.add_child(entries)

    for entry in main_menu_entries:
        var button := Button.new()
        button.name = entry.replace(" ", "")
        button.text = entry
        entries.add_child(button)
        if entry == "Quick Fly":
            button.pressed.connect(quick_fly)
        elif entry == "Controller":
            button.pressed.connect(begin_controller_confirmation)
        elif entry == "Settings":
            button.pressed.connect(show_settings)
    _build_settings_panel()
    _build_controller_settings_panel()

func _build_settings_panel() -> void:
    var panel := PanelContainer.new()
    panel.name = "SettingsPanel"
    panel.set_anchors_preset(Control.PRESET_TOP_LEFT)
    panel.offset_left = 20.0
    panel.offset_top = 20.0
    panel.offset_right = 360.0
    panel.offset_bottom = 180.0
    settings_panel = panel
    main_menu_layer.add_child(panel)

    var rows := VBoxContainer.new()
    rows.name = "Rows"
    rows.add_theme_constant_override("separation", 6)
    panel.add_child(rows)

    var title := Label.new()
    title.text = "SETTINGS"
    rows.add_child(title)

    var controller_button := Button.new()
    controller_button.name = "Controller"
    controller_button.text = "CONTROLLER"
    controller_button.pressed.connect(show_controller_settings)
    rows.add_child(controller_button)

    var back_button := Button.new()
    back_button.name = "Back"
    back_button.text = "BACK"
    back_button.pressed.connect(show_main_menu)
    rows.add_child(back_button)

func _build_controller_settings_panel() -> void:
    var panel := PanelContainer.new()
    panel.name = "ControllerSettingsPanel"
    panel.set_anchors_preset(Control.PRESET_TOP_LEFT)
    panel.offset_left = 20.0
    panel.offset_top = 20.0
    panel.offset_right = 460.0
    panel.offset_bottom = 360.0
    controller_settings_panel = panel
    main_menu_layer.add_child(panel)

    var rows := VBoxContainer.new()
    rows.name = "Rows"
    rows.add_theme_constant_override("separation", 6)
    panel.add_child(rows)

    var title := Label.new()
    title.text = "CONTROLLER"
    rows.add_child(title)

    controller_settings_device_label = Label.new()
    controller_settings_device_label.name = "CurrentDevice"
    rows.add_child(controller_settings_device_label)

    controller_settings_mapping_label = Label.new()
    controller_settings_mapping_label.name = "FixedMapping"
    rows.add_child(controller_settings_mapping_label)

    controller_settings_deadzone_label = Label.new()
    controller_settings_deadzone_label.name = "Deadzone"
    rows.add_child(controller_settings_deadzone_label)

    controller_settings_button_status_label = Label.new()
    controller_settings_button_status_label.name = "ButtonStatus"
    rows.add_child(controller_settings_button_status_label)

    var reset_button := Button.new()
    reset_button.name = "ResetXboxDefault"
    reset_button.text = "RESET TO XBOX DEFAULT"
    reset_button.pressed.connect(reset_to_xbox_default)
    rows.add_child(reset_button)

    var back_button := Button.new()
    back_button.name = "Back"
    back_button.text = "BACK"
    back_button.pressed.connect(show_settings)
    rows.add_child(back_button)

func show_main_menu() -> void:
    screen = "main_menu"
    _refresh_flight_hud()

func show_settings() -> void:
    screen = "settings"
    _refresh_flight_hud()

func show_controller_settings() -> void:
    screen = "controller_settings"
    _refresh_controller_settings()
    _refresh_flight_hud()

func reset_to_xbox_default() -> void:
    begin_controller_confirmation(_first_connected_device())

func _build_controller_confirmation() -> void:
    var panel := PanelContainer.new()
    panel.name = "ControllerConfirmation"
    panel.set_anchors_preset(Control.PRESET_TOP_LEFT)
    panel.offset_left = 380.0
    panel.offset_top = 20.0
    panel.offset_right = 780.0
    panel.offset_bottom = 310.0
    controller_confirmation_panel = panel
    flight_hud_layer.add_child(panel)

    var rows := VBoxContainer.new()
    rows.name = "Rows"
    rows.add_theme_constant_override("separation", 6)
    panel.add_child(rows)

    var title := Label.new()
    title.name = "Title"
    title.text = "CONFIRM XBOX DEFAULT PROFILE"
    rows.add_child(title)

    confirmation_mapping_label = Label.new()
    confirmation_mapping_label.name = "FixedMapping"
    rows.add_child(confirmation_mapping_label)

    confirmation_axes_label = Label.new()
    confirmation_axes_label.name = "LiveAxes"
    rows.add_child(confirmation_axes_label)

    var confirm_button := Button.new()
    confirm_button.name = "UseXboxDefaultProfile"
    confirm_button.text = "USE XBOX DEFAULT PROFILE"
    confirm_button.pressed.connect(accept_controller_confirmation)
    rows.add_child(confirm_button)

    var fallback_button := Button.new()
    fallback_button.name = "UseKeyboardFallback"
    fallback_button.text = "USE KEYBOARD FALLBACK"
    fallback_button.pressed.connect(use_keyboard_fallback)
    rows.add_child(fallback_button)

func _build_flight_hud() -> void:
    var layer := CanvasLayer.new()
    layer.name = "FlightHud"
    layer.layer = 30
    flight_hud_layer = layer
    add_child(layer)

    var margin := MarginContainer.new()
    margin.set_anchors_preset(Control.PRESET_TOP_LEFT)
    margin.offset_right = 360.0
    margin.offset_bottom = 128.0
    margin.add_theme_constant_override("margin_left", 10)
    margin.add_theme_constant_override("margin_top", 10)
    margin.add_theme_constant_override("margin_right", 10)
    margin.add_theme_constant_override("margin_bottom", 10)
    layer.add_child(margin)

    var panel := PanelContainer.new()
    margin.add_child(panel)

    var rows := VBoxContainer.new()
    rows.add_theme_constant_override("separation", 4)
    panel.add_child(rows)

    key_hints_label = Label.new()
    key_hints_label.name = "KeyHints"
    key_hints_label.text = KEY_HINTS_TEXT
    rows.add_child(key_hints_label)

    arm_status_label = Label.new()
    arm_status_label.name = "ArmStatus"
    rows.add_child(arm_status_label)

    arm_takeoff_button = Button.new()
    arm_takeoff_button.name = "ArmTakeoff"
    arm_takeoff_button.pressed.connect(_handle_primary_action)
    rows.add_child(arm_takeoff_button)

func _build_status_diagram() -> void:
    status_diagram = StatusDiagramDebug.new()
    add_child(status_diagram)

func _update_status_diagram() -> void:
    if status_diagram == null or native == null or not native.has_method("telemetry_snapshot"):
        return
    status_diagram.update_from_snapshot(native.call("telemetry_snapshot"))

func _reset_drone_body() -> void:
    drone_body.reset_contact()
    drone_body.apply_native_state(SPAWN_POSITION, Quaternion.IDENTITY, Vector3.ZERO, Vector3.ZERO)
    drone_body.freeze = true

func _refresh_flight_hud() -> void:
    if key_hints_label == null or arm_status_label == null or arm_takeoff_button == null:
        return
    if main_menu_layer != null:
        main_menu_layer.visible = screen in ["main_menu", "settings", "controller_settings"]
    if main_menu_entries_container != null:
        main_menu_entries_container.visible = screen == "main_menu"
    if settings_panel != null:
        settings_panel.visible = screen == "settings"
    if controller_settings_panel != null:
        controller_settings_panel.visible = screen == "controller_settings"
    if flight_hud_layer != null:
        flight_hud_layer.visible = screen not in ["main_menu", "settings", "controller_settings"]
    key_hints_label.text = KEY_HINTS_TEXT
    arm_takeoff_button.disabled = screen == "main_menu"
    if screen == "preflight":
        var armed := _flight_control_armed()
        arm_status_label.text = "%s -> %s -> press T or ARM" % [_profile_input_status(), "ARMED" if armed else "DISARMED"]
        arm_takeoff_button.text = "ARM / TAKEOFF (T)"
    elif screen == "flight":
        var armed := _flight_control_armed()
        arm_status_label.text = "%s | %s | %s" % [_profile_input_status(), "ARMED" if armed else "DISARMED", "PAUSED" if paused else "TAKEOFF"]
        arm_takeoff_button.text = "ARM / TAKEOFF (T)"
    elif screen == "fallback_prompt":
        arm_status_label.text = last_error_message
        arm_takeoff_button.text = "USE KEYBOARD FALLBACK"
    elif screen == "controller_confirmation":
        arm_status_label.text = "Confirm the fixed Xbox mapping or use KeyboardProfile fallback"
        arm_takeoff_button.text = "BACK TO MAIN MENU"
    elif screen == "error":
        arm_status_label.text = last_error_message
        arm_takeoff_button.text = "BACK TO MAIN MENU"
    elif screen == "exit":
        arm_status_label.text = "EXIT requested"
        arm_takeoff_button.text = "EXIT"
    else:
        arm_status_label.text = "Quick Fly: choose Quick Fly, then arm at low throttle"
        arm_takeoff_button.text = "ARM / TAKEOFF (T)"

func _handle_primary_action() -> void:
    if screen == "fallback_prompt":
        accept_fallback()
    elif screen in ["preflight", "flight"]:
        arm_and_takeoff()
    elif screen in ["controller_confirmation", "error"]:
        if controller_confirmation_panel != null:
            controller_confirmation_panel.hide()
        screen = "main_menu"
        last_error_message = ""
        _refresh_flight_hud()

func _first_connected_device() -> int:
    var devices := gamepad_device_state.connected_joypads()
    for device_id in devices:
        if InputProfiles.GamepadProfile.is_supported_device(device_id, gamepad_device_state):
            return device_id
    return devices[0] if not devices.is_empty() else -1

func _on_joy_connection_changed(_device_id: int, _connected: bool) -> void:
    update_fallback_status()

func _refresh_controller_confirmation() -> void:
    if controller_confirmation_panel == null or not controller_confirmation_panel.visible or controller_confirmation_profile == null:
        return
    var mapping_lines := ["FIXED XBOX MAPPING"]
    var live_axis_lines := ["LIVE AXES"]
    for role in ["roll", "pitch", "yaw", "throttle"]:
        var axis := int(controller_confirmation_profile.axis_for_role[role])
        var raw := Input.get_joy_axis(controller_confirmation_device_id, axis)
        var normalized := _normalize_gamepad_axis(raw, controller_confirmation_profile.deadzone)
        mapping_lines.append("%s -> Axis %d%s" % [role, axis, " (reversed)" if controller_confirmation_profile.reversed_for_role[role] else ""])
        live_axis_lines.append("%s: Raw %+.3f | Normalized %+.3f" % [role, raw, normalized])
    confirmation_mapping_label.text = "\n".join(mapping_lines)
    confirmation_axes_label.text = "\n".join(live_axis_lines)

func _refresh_controller_settings() -> void:
    if controller_settings_panel == null or not controller_settings_panel.visible:
        return
    var device_id := _first_connected_device()
    var profile := session_gamepad_profile if _has_active_gamepad_profile() and session_gamepad_device_id == device_id else InputProfiles.GamepadProfile.new()
    if device_id < 0:
        controller_settings_device_label.text = "CURRENT DEVICE: none"
    else:
        var support := "SDL mapped" if InputProfiles.GamepadProfile.is_supported_device(device_id, gamepad_device_state) else "unknown"
        controller_settings_device_label.text = "CURRENT DEVICE: %d %s (%s)" % [device_id, gamepad_device_state.joy_name(device_id), support]
    var mapping_lines := ["FIXED XBOX MAPPING"]
    for role in ["roll", "pitch", "yaw", "throttle"]:
        var axis := int(profile.axis_for_role[role])
        mapping_lines.append("%s -> Axis %d%s" % [role, axis, " (reversed)" if profile.reversed_for_role[role] else ""])
    controller_settings_mapping_label.text = "\n".join(mapping_lines)
    controller_settings_deadzone_label.text = "DEADZONE: %.3f" % profile.deadzone
    controller_settings_button_status_label.text = "Arm %s | Mode %s" % ["PRESSED" if profile.arm_pressed else "RELEASED", "PRESSED" if profile.mode_pressed else "RELEASED"]

func _normalize_gamepad_axis(raw: float, deadzone: float) -> float:
    if absf(raw) <= deadzone:
        return 0.0
    return sign(raw) * (absf(raw) - deadzone) / (1.0 - deadzone)

func _handle_gamepad_button(event: InputEventJoypadButton) -> bool:
    if not _has_active_gamepad_profile() or event.device != session_gamepad_device_id:
        return false
    var profile := session_gamepad_profile
    var is_arm := event.button_index == profile.arm_button
    var is_mode := event.button_index == profile.mode_button
    if not is_arm and not is_mode:
        return false
    if is_arm:
        profile.arm_pressed = event.pressed
    else:
        profile.mode_pressed = event.pressed
    if not event.pressed:
        _refresh_flight_hud()
        return true
    var now_ms := _gamepad_button_now_ms()
    var last_press_ms := last_arm_button_press_ms if is_arm else last_mode_button_press_ms
    if now_ms - last_press_ms < GAMEPAD_BUTTON_DEBOUNCE_MS:
        _refresh_flight_hud()
        return true
    if is_arm:
        last_arm_button_press_ms = now_ms
        if screen in ["preflight", "flight"]:
            arm_and_takeoff()
    else:
        last_mode_button_press_ms = now_ms
        toggle_altitude_hold()
    _refresh_flight_hud()
    return true

func set_gamepad_button_time_source(time_source: Callable) -> void:
    gamepad_button_time_source = time_source

func _gamepad_button_now_ms() -> int:
    if gamepad_button_time_source.is_valid():
        return int(gamepad_button_time_source.call())
    return Time.get_ticks_msec()

func _has_active_gamepad_profile() -> bool:
    return session_gamepad_profile != null and session_gamepad_device_id >= 0

func _profile_axis(role: String) -> float:
    if not _has_active_gamepad_profile():
        return 0.0
    var axis := int(session_gamepad_profile.axis_for_role[role])
    var raw := Input.get_joy_axis(session_gamepad_device_id, axis)
    var normalized := _normalize_gamepad_axis(raw, session_gamepad_profile.deadzone)
    if session_gamepad_profile.reversed_for_role[role]:
        normalized = -normalized
    return normalized

func _profile_throttle_raw() -> float:
    if not _has_active_gamepad_profile():
        return 0.0
    var axis := int(session_gamepad_profile.axis_for_role["throttle"])
    return Input.get_joy_axis(session_gamepad_device_id, axis)

func _flight_throttle() -> float:
    if not _has_active_gamepad_profile():
        return KEYBOARD_FLIGHT_THROTTLE
    session_gamepad_profile.apply_throttle_axis(_profile_throttle_raw())
    return session_gamepad_profile.throttle

func _profile_throttle_is_low() -> bool:
    return _has_active_gamepad_profile() and session_gamepad_profile.throttle_axis_is_low(_profile_throttle_raw())

func _angle_roll_degrees() -> float:
    return _profile_axis("roll") * ANGLE_MAX_TILT_DEGREES

func _angle_pitch_degrees() -> float:
    return _profile_axis("pitch") * ANGLE_MAX_TILT_DEGREES

func _angle_yaw_rate_degrees_per_second() -> float:
    return _profile_axis("yaw") * ANGLE_MAX_YAW_RATE_DPS

func _profile_input_status() -> String:
    if not _has_active_gamepad_profile():
        return "Throttle LOW | KeyboardProfile"
    var throttle := _flight_throttle()
    var is_low := _profile_throttle_is_low()
    return "Throttle %d%% %s | Arm %s | Mode %s" % [roundi(throttle * 100.0), "LOW" if is_low else "HIGH", "PRESSED" if session_gamepad_profile.arm_pressed else "RELEASED", "PRESSED" if session_gamepad_profile.mode_pressed else "RELEASED"]

func _update_chase_camera() -> void:
    if chase_camera == null or drone_body == null:
        return
    chase_camera.current = true
    chase_camera.global_position = drone_body.global_position + CHASE_CAMERA_OFFSET
    chase_camera.look_at(drone_body.global_position, Vector3.UP)

func _flight_control_armed() -> bool:
    return native != null and bool(native.call("flight_control_armed"))

func _kinetic(linear_velocity: Vector3, angular_velocity: Vector3) -> float:
    return 0.5 * _mass_kg() * linear_velocity.length_squared() + 0.5 * angular_velocity.length_squared()

func _mass_kg() -> float:
    if native == null or not native.has_method("hardware_power_diagnostics"):
        return 1.0
    var diagnostics: Dictionary = native.call("hardware_power_diagnostics")
    return maxf(float(diagnostics.get("mass_kg", 1.0)), 0.000001)


func _airsim_name_matches(name: String) -> bool:
    return name == _airsim_vehicle_name or (_airsim_vehicle_name.is_empty() and name.is_empty())


func _airsim_enable_api_control(enabled: bool, name: String) -> Dictionary:
    if not _airsim_name_matches(name):
        return {"ok": false, "error": "vehicle backend only exposes the configured single vehicle"}
    _airsim_api_control = enabled
    _airsim_disarm_requested = true
    _airsim_hold_controls = _airsim_neutral_controls() if enabled else {}
    if not enabled:
        _airsim_command_state.clear()
        _airsim_command_remaining_frames = 0
        if native != null and native.has_method("disarm_flight_control"):
            native.call("disarm_flight_control")
    return {"ok": true}


func _airsim_arm_disarm(armed: bool, name: String) -> Dictionary:
    if not _airsim_name_matches(name):
        return {"ok": false, "error": "vehicle backend only exposes the configured single vehicle"}
    if native == null:
        return {"ok": false, "error": "native runtime unavailable"}
    if armed:
        _airsim_disarm_requested = false
        return {"ok": true, "armed": bool(native.call("arm_flight_control", 0.0))}
    _airsim_disarm_requested = true
    if native.has_method("disarm_flight_control"):
        native.call("disarm_flight_control")
    _airsim_command_state.clear()
    _airsim_hold_controls = _airsim_neutral_controls()
    _airsim_command_remaining_frames = 0
    return {"ok": true, "armed": false}


func _airsim_cancel_task(name: String) -> void:
    if _airsim_name_matches(name):
        _airsim_command_state.clear()
        _airsim_hold_controls = _airsim_neutral_controls()
        _airsim_command_remaining_frames = 0


func _airsim_task_complete(name: String) -> bool:
    if not _airsim_name_matches(name):
        return false
    if _airsim_command_state.is_empty():
        return true
    if drone_body == null:
        return false
    var method := String(_airsim_command_state["method"])
    var args: Array = _airsim_command_state["args"]
    var position_ned := AirSimCoordinateContract.godot_world_to_ned(drone_body.global_position, SPAWN_POSITION)
    match method:
        "takeoff":
            return position_ned.z <= -2.75 and drone_body.linear_velocity.length() < 1.0
        "land":
            var landed_on_ground: bool = drone_body.global_position.y <= SPAWN_POSITION.y + 0.05 and drone_body.linear_velocity.length() < 0.25
            return position_ned.z >= -0.5 and (_airsim_contact_this_frame or landed_on_ground)
        "hover":
            return drone_body.linear_velocity.length() < 2.0 and drone_body.angular_velocity.length() < 1.0
        "goHome":
            return position_ned.length() < 1.0 and drone_body.linear_velocity.length() < 3.0
        "moveToPosition":
            return position_ned.distance_to(Vector3(float(args[0]), float(args[1]), float(args[2]))) < 0.25 and drone_body.linear_velocity.length() < 0.75
        "moveOnPath":
            var path: Array = args[0]
            var index := int(_airsim_command_state.get("waypoint_index", 0))
            if index >= path.size():
                return true
            var point: Dictionary = path[index]
            return position_ned.distance_to(Vector3(float(point["x_val"]), float(point["y_val"]), float(point["z_val"]))) < 0.25 and index == path.size() - 1 and drone_body.linear_velocity.length() < 0.75
        "rotateToYaw":
            return absf(wrapf(AirSimCoordinateContract.ned_yaw_degrees_to_godot_radians(float(args[0])) - drone_body.rotation.y, -PI, PI)) <= deg_to_rad(maxf(float(args[2]), 1.0)) and drone_body.angular_velocity.length() < 0.75
        "moveByVelocity", "moveByVelocityZ", "moveByVelocityBodyFrame", "moveByVelocityZBodyFrame", "rotateByYawRate", "moveByAngleRatesThrottle":
            return _airsim_command_remaining_frames <= 0
    return false


func _airsim_command(method: String, params: Array, name: String) -> Dictionary:
    if not _airsim_name_matches(name):
        return {"ok": false, "error": "vehicle backend only exposes the configured single vehicle"}
    var args: Array = params.slice(0, params.size() - 1)
    var duration_frames := 1
    match method:
        "moveByVelocity", "moveByVelocityZ", "moveByVelocityBodyFrame", "moveByVelocityZBodyFrame":
            duration_frames = maxi(1, ceili(float(args[3]) * float(Engine.physics_ticks_per_second)))
        "rotateByYawRate":
            duration_frames = maxi(1, ceili(float(args[1]) * float(Engine.physics_ticks_per_second)))
        "moveByAngleRatesThrottle":
            duration_frames = maxi(1, ceili(float(args[4]) * float(Engine.physics_ticks_per_second)))
        "takeoff", "land", "hover", "goHome", "moveToPosition", "moveOnPath", "rotateToYaw":
            duration_frames = maxi(1, int(30.0 * float(Engine.physics_ticks_per_second)))
    _airsim_command_state = {"method": method, "args": args, "waypoint_index": 0}
    _airsim_hold_controls = _airsim_neutral_controls()
    _airsim_command_remaining_frames = duration_frames
    takeoff_requested = true
    if method == "takeoff":
        takeoff_requested = true
        screen = "flight"
        if drone_body != null:
            drone_body.reset_contact()
            drone_body.freeze = false
            drone_body.sleeping = false
            drone_body.apply_native_state(drone_body.global_position, drone_body.global_transform.basis.get_rotation_quaternion(), Vector3(0.0, 0.5, 0.0), Vector3.ZERO)
    elif method == "land":
        takeoff_requested = true
    elif method == "goHome":
        takeoff_requested = true
    return {"ok": true, "duration_frames": duration_frames}


func _airsim_controls_for_frame() -> Dictionary:
    if not _airsim_api_control:
        return {}
    if _airsim_command_state.is_empty():
        return _airsim_hold_controls.duplicate(true)
    var method := String(_airsim_command_state["method"])
    var args: Array = _airsim_command_state["args"]
    if drone_body != null:
        drone_body.freeze = false
        drone_body.sleeping = false
    else:
        return {}
    match method:
        "takeoff":
            var takeoff_velocity := clampf((3.0 - drone_body.global_position.y) * 1.5, -3.0, 3.0)
            return _airsim_velocity_controls(Vector3(0.0, takeoff_velocity, 0.0), 0.0)
        "land":
            var landing_velocity := clampf((0.0 - drone_body.global_position.y) * 1.5, -3.0, 3.0)
            return _airsim_velocity_controls(Vector3(0.0, landing_velocity, 0.0), 0.0)
        "hover":
            return _airsim_velocity_controls(Vector3.ZERO, 0.0)
        "goHome":
            var home_delta: Vector3 = SPAWN_POSITION - drone_body.global_position
            var home_horizontal := Vector3(home_delta.x, 0.0, home_delta.z)
            var home_velocity := home_horizontal.normalized() * minf(home_horizontal.length() * 1.5, 4.0)
            home_velocity.y = clampf(home_delta.y * 4.0 - drone_body.linear_velocity.y * 3.0, -8.0, 8.0)
            return _airsim_velocity_controls(home_velocity, 0.0)
        "moveByVelocity":
            return _airsim_velocity_controls(AirSimCoordinateContract.ned_direction_to_godot(Vector3(float(args[0]), float(args[1]), float(args[2]))), 0.0, args[5])
        "moveByVelocityZ":
            var horizontal := AirSimCoordinateContract.ned_direction_to_godot(Vector3(float(args[0]), float(args[1]), 0.0))
            return _airsim_velocity_controls(horizontal, (-float(args[2]) - drone_body.global_position.y) * 4.0, args[5])
        "moveByVelocityBodyFrame":
            var body_frd := Vector3(float(args[0]), float(args[1]), float(args[2]))
            var local_godot := AirSimCoordinateContract.frd_to_godot_body(body_frd)
            return _airsim_velocity_controls(drone_body.global_transform.basis * local_godot, 0.0, args[5])
        "moveByVelocityZBodyFrame":
            # AirSim rotates only the horizontal body velocity into the world
            # frame and passes z unchanged to commandVelocityZ; z is NED
            # altitude, not a pitch/roll-rotated body coordinate.
            var position_ned := AirSimCoordinateContract.godot_world_to_ned(drone_body.global_position, SPAWN_POSITION)
            var body_target_velocity := Vector3(float(args[0]), float(args[1]), (float(args[2]) - position_ned.z) * 2.0)
            var body_velocity_local := AirSimCoordinateContract.frd_to_godot_body(body_target_velocity)
            return _airsim_velocity_controls(drone_body.global_transform.basis * body_velocity_local, 0.0, args[5])
        "moveToPosition", "moveOnPath":
            var target_ned: Vector3
            if method == "moveToPosition":
                target_ned = Vector3(float(args[0]), float(args[1]), float(args[2]))
            else:
                var path: Array = args[0]
                var waypoint_index := int(_airsim_command_state.get("waypoint_index", 0))
                if waypoint_index >= path.size():
                    _airsim_hold_controls = _airsim_neutral_controls()
                    _airsim_command_state.clear()
                    return _airsim_hold_controls.duplicate(true)
                var waypoint: Dictionary = path[waypoint_index]
                target_ned = Vector3(float(waypoint["x_val"]), float(waypoint["y_val"]), float(waypoint["z_val"]))
            var delta_world: Vector3 = AirSimCoordinateContract.ned_to_godot_world(target_ned, SPAWN_POSITION) - drone_body.global_position
            var command_speed := float(args[3]) if method == "moveToPosition" else float(args[1])
            if method == "moveOnPath" and delta_world.length() < 0.25:
                _airsim_command_state["waypoint_index"] = int(_airsim_command_state.get("waypoint_index", 0)) + 1
            var yaw_mode: Variant = args[6] if method == "moveToPosition" else args[4]
            return _airsim_velocity_controls(delta_world.normalized() * minf(delta_world.length() * 2.0, command_speed), delta_world.y * 4.0, yaw_mode)
        "rotateToYaw":
            var target_yaw := AirSimCoordinateContract.ned_yaw_degrees_to_godot_radians(float(args[0]))
            var delta_yaw := wrapf(target_yaw - drone_body.rotation.y, -PI, PI)
            var rotate_to_controls := _airsim_velocity_controls(Vector3.ZERO, 0.0)
            rotate_to_controls["yaw_rate"] = clampf(rad_to_deg(delta_yaw) * 3.0, -ANGLE_MAX_YAW_RATE_DPS, ANGLE_MAX_YAW_RATE_DPS)
            return rotate_to_controls
        "rotateByYawRate":
            var rotate_rate_controls := _airsim_velocity_controls(Vector3.ZERO, 0.0)
            rotate_rate_controls["yaw_rate"] = clampf(-float(args[0]), -ANGLE_MAX_YAW_RATE_DPS, ANGLE_MAX_YAW_RATE_DPS)
            return rotate_rate_controls
        "moveByAngleRatesThrottle":
            return {"mode": "ACRO", "throttle": float(args[3]), "acro_roll": _airsim_rate_stick(rad_to_deg(float(args[0]))), "acro_pitch": _airsim_rate_stick(rad_to_deg(float(args[1]))), "acro_yaw": _airsim_rate_stick(rad_to_deg(float(args[2])))}
    return {}


func _airsim_velocity_controls(velocity_world: Vector3, vertical_correction: float, yaw_mode: Variant = null) -> Dictionary:
    var desired := velocity_world
    var measured_velocity: Vector3 = drone_body.linear_velocity if drone_body != null else Vector3.ZERO
    var horizontal_velocity_error := Vector3(desired.x - measured_velocity.x, 0.0, desired.z - measured_velocity.z)
    var measured_vertical_velocity: float = drone_body.linear_velocity.y if drone_body != null else 0.0
    var vertical_velocity_error: float = desired.y - measured_vertical_velocity
    var throttle := clampf(0.50 + vertical_velocity_error * 0.15 + clampf(vertical_correction, -0.5, 0.5), 0.0, 1.0)
    return {
        "mode": "ANGLE",
        "throttle": throttle,
        "roll": clampf(-horizontal_velocity_error.x * 4.0, -ANGLE_MAX_TILT_DEGREES, ANGLE_MAX_TILT_DEGREES),
        "pitch": clampf(horizontal_velocity_error.z * 4.0, -ANGLE_MAX_TILT_DEGREES, ANGLE_MAX_TILT_DEGREES),
        "yaw_rate": _airsim_yaw_rate_from_mode(yaw_mode),
    }


func _airsim_yaw_rate_from_mode(yaw_mode: Variant) -> float:
    if typeof(yaw_mode) != TYPE_DICTIONARY:
        return 0.0
    var requested := float(yaw_mode.get("yaw_or_rate", 0.0))
    if bool(yaw_mode.get("is_rate", true)):
        return clampf(-requested, -ANGLE_MAX_YAW_RATE_DPS, ANGLE_MAX_YAW_RATE_DPS)
    if drone_body == null:
        return 0.0
    var delta_yaw := wrapf(AirSimCoordinateContract.ned_yaw_degrees_to_godot_radians(requested) - drone_body.rotation.y, -PI, PI)
    return clampf(rad_to_deg(delta_yaw) * 3.0, -ANGLE_MAX_YAW_RATE_DPS, ANGLE_MAX_YAW_RATE_DPS)


func _airsim_rate_stick(rate_degrees_per_second: float) -> float:
    if native != null and native.has_method("betaflight_stick_for_rate"):
        return float(native.call("betaflight_stick_for_rate", rate_degrees_per_second, ACRO_RC_RATE, ACRO_SUPER_RATE, ACRO_EXPO))
    return clampf(rate_degrees_per_second / 720.0, -1.0, 1.0)


func _airsim_neutral_controls() -> Dictionary:
    return {"mode": "ANGLE", "throttle": 0.50, "roll": 0.0, "pitch": 0.0, "yaw_rate": 0.0}


func _airsim_state(name: String) -> Dictionary:
    if not _airsim_name_matches(name):
        return {"ok": false, "error": "vehicle backend only exposes the configured single vehicle"}
    var position: Vector3 = drone_body.global_position if drone_body != null else SPAWN_POSITION
    var orientation: Quaternion = drone_body.global_transform.basis.get_rotation_quaternion() if drone_body != null else Quaternion.IDENTITY
    var linear_velocity: Vector3 = drone_body.linear_velocity if drone_body != null else Vector3.ZERO
    var angular_velocity: Vector3 = drone_body.angular_velocity if drone_body != null else Vector3.ZERO
    var body_basis_inverse: Basis = drone_body.global_transform.basis.inverse() if drone_body != null else Basis.IDENTITY
    var origin: Dictionary = airsim_rpc_server.settings.get("OriginGeopoint", {}) if airsim_rpc_server != null else {}
    var gps_location := {
        "latitude": float(origin.get("Latitude", 0.0)),
        "longitude": float(origin.get("Longitude", 0.0)),
        "altitude": float(origin.get("Altitude", 0.0)),
    }
    var collision := {
        "has_collided": _airsim_collision_seen,
        "normal": _airsim_vector3(AirSimCoordinateContract.godot_direction_to_ned(_airsim_collision_normal)),
        "impact_point": _airsim_vector3(AirSimCoordinateContract.godot_world_to_ned(_airsim_collision_point, SPAWN_POSITION)),
        "position": _airsim_vector3(AirSimCoordinateContract.godot_world_to_ned(position, SPAWN_POSITION)),
        "penetration_depth": 0.0,
        "time_stamp": int(round(airsim_session.simulation_time_seconds * 1_000_000_000.0)),
        "object_name": "",
        "object_id": -1,
    }
    var state := {
        "collision": collision,
        "kinematics_estimated": {
            "position": _airsim_vector3(AirSimCoordinateContract.godot_world_to_ned(position, SPAWN_POSITION)),
            "orientation": _airsim_quaternion(AirSimCoordinateContract.godot_orientation_to_ned(orientation)),
            "linear_velocity": _airsim_vector3(AirSimCoordinateContract.godot_direction_to_ned(linear_velocity)),
            "angular_velocity": _airsim_vector3(AirSimCoordinateContract.godot_body_to_frd(body_basis_inverse * angular_velocity)),
            "linear_acceleration": _airsim_vector3(AirSimCoordinateContract.godot_body_to_frd(body_basis_inverse * _airsim_linear_acceleration)),
            "angular_acceleration": _airsim_vector3(AirSimCoordinateContract.godot_body_to_frd(_airsim_angular_acceleration)),
        },
        "gps_location": gps_location,
        "timestamp": int(round(airsim_session.simulation_time_seconds * 1_000_000_000.0)),
        "landed_state": 0 if position.y <= SPAWN_POSITION.y + 0.05 and linear_velocity.length() < 0.25 else 1,
        "rc_data": {"timestamp": 0, "pitch": 0.0, "roll": 0.0, "throttle": _flight_throttle(), "yaw": 0.0, "is_initialized": false, "is_valid": false},
        "ready": native != null,
        "ready_message": "" if native != null else "native runtime unavailable",
        "can_arm": native != null,
    }
    return {"ok": true, "state": state}


func _airsim_vector3(value: Vector3) -> Dictionary:
    return {"x_val": value.x, "y_val": value.y, "z_val": value.z}


func _airsim_quaternion(value: Quaternion) -> Dictionary:
    return {"w_val": value.w, "x_val": value.x, "y_val": value.y, "z_val": value.z}

func _acro_roll_stick() -> float:
    if acro_roll_stick != 0.0:
        return acro_roll_stick
    return Input.get_axis("ui_left", "ui_right")

func _acro_pitch_stick() -> float:
    if acro_pitch_stick != 0.0:
        return acro_pitch_stick
    return Input.get_axis("ui_down", "ui_up")

func _acro_yaw_stick() -> float:
    return acro_yaw_stick

func _sync_native_from_drone() -> void:
    var q: Quaternion = drone_body.global_transform.basis.get_rotation_quaternion()
    native.call(
        "sync_flight_state",
        drone_body.global_position.x,
        drone_body.global_position.y,
        drone_body.global_position.z,
        q.x,
        q.y,
        q.z,
        q.w,
        drone_body.linear_velocity.x,
        drone_body.linear_velocity.y,
        drone_body.linear_velocity.z,
        drone_body.angular_velocity.x,
        drone_body.angular_velocity.y,
        drone_body.angular_velocity.z
    )
