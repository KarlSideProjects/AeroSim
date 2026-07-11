extends Node3D

const InputProfiles = preload("res://common/flight/input_profiles.gd")
const GamepadSetupPanel = preload("res://common/flight/gamepad_setup_panel.gd")
const HardwareConfig = preload("res://common/flight/hardware_config.gd")
const StatusDiagramDebug = preload("res://common/flight/status_diagram_debug.gd")
const DEFAULT_HARDWARE_PRESET := "res://config/drones/5_inch_6s.json"
const SPAWN_POSITION := Vector3(-1.0, 0.0, 0.0)
const TAKEOFF_VELOCITY := Vector3(0.0, 6.0, 0.0)
const FLIGHT_THROTTLE := 0.75
const ACRO_RC_RATE := 1.0
const ACRO_SUPER_RATE := 13.0 / 18
const ACRO_EXPO := 0.0
const CHASE_CAMERA_OFFSET := Vector3(-3.0, 1.4, 2.2)
const KEY_HINTS_TEXT := "T Arm/Takeoff   P Pause   R Reset   H Alt Hold   Esc Exit"

@onready var fallback_status_label: Label3D = %FallbackStatus
@onready var drone_body = get_node_or_null("DroneBody")
@onready var chase_camera := get_node_or_null("ChaseCamera") as Camera3D

var native: Object
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
var flight_hud_layer: CanvasLayer
var key_hints_label: Label
var arm_status_label: Label
var arm_takeoff_button: Button
var gamepad_setup_panel: Control
var session_gamepad_profile: InputProfiles.GamepadProfile

func _ready() -> void:
    _build_main_menu()
    _build_flight_hud()
    _build_status_diagram()
    native = ClassDB.instantiate("AeroSimNative")
    if native == null:
        push_error("AeroSimNative is not registered")
        return
    var hardware_config := HardwareConfig.new()
    if not hardware_config.apply_to_runtime(self, DEFAULT_HARDWARE_PRESET):
        last_error_message = hardware_config.last_error
        push_error("Default hardware preset failed: %s" % hardware_config.last_error)
    update_fallback_status()
    _update_chase_camera()
    _refresh_flight_hud()

func _unhandled_input(event: InputEvent) -> void:
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
    _update_chase_camera()
    _refresh_flight_hud()

func _physics_process(_delta: float) -> void:
    if reset_hold_frames > 0:
        reset_hold_frames -= 1
        if reset_hold_frames == 0 and drone_body != null and not paused:
            drone_body.freeze = false
            drone_body.sleeping = false
        return
    if native == null or paused or not takeoff_requested:
        return
    if not native.call("flight_control_armed"):
        native.call("arm_flight_control", 0.0)
    var row: PackedFloat64Array
    if drone_body != null:
        _sync_native_from_drone()
        var energy_limit := _kinetic(drone_body.linear_velocity, drone_body.angular_velocity)
        if flight_mode == "ACRO":
            row = native.call(
                "step_collision_acro_mode",
                Engine.physics_ticks_per_second,
                1000,
                FLIGHT_THROTTLE,
                _acro_roll_stick(),
                _acro_pitch_stick(),
                _acro_yaw_stick(),
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
                FLIGHT_THROTTLE,
                0.0,
                0.0,
                0.0,
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
        drone_body.reset_contact()
    else:
        if flight_mode == "ACRO":
            row = native.call("step_acro_mode", Engine.physics_ticks_per_second, 1000, FLIGHT_THROTTLE, _acro_roll_stick(), _acro_pitch_stick(), _acro_yaw_stick(), ACRO_RC_RATE, ACRO_SUPER_RATE, ACRO_EXPO)
        else:
            var free_flight_method := "step_altitude_hold_mode" if flight_mode == "ALTITUDE_HOLD" else "step_angle_mode"
            row = native.call(free_flight_method, Engine.physics_ticks_per_second, 1000, FLIGHT_THROTTLE, 0.0, 0.0, 0.0)
    if row.size() >= 13:
        last_collision_authority = int(row[12])
    if drone_body != null and row.size() >= 17:
        drone_body.apply_native_state(
            Vector3(row[1], row[2], row[3]),
            Quaternion(row[4], row[5], row[6], row[7]),
            Vector3(row[8], row[9], row[10]),
            Vector3(row[14], row[15], row[16])
        )
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

func quick_fly(entry_state: String = "calibrated") -> void:
    if entry_state == "no_controller":
        last_error_message = InputProfiles.fallback_status([])
        screen = "fallback_prompt"
        _refresh_flight_hud()
        return
    if entry_state == "uncalibrated":
        last_error_message = "Controller setup is required before Quick Fly"
        begin_controller_setup()
        return
    if entry_state != "calibrated":
        last_error_message = "Quick Fly cannot continue: %s" % entry_state
        screen = "error"
        _refresh_flight_hud()
        return
    enter_preflight()

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
    screen = "flight"
    flight_mode = "ANGLE"
    takeoff_requested = true
    set_paused(false)
    if native != null:
        native.call("reset_flight")
    update_fallback_status()
    if drone_body != null:
        _reset_drone_body()
        # ponytail: short reset hold; replace with real throttle input state when controller profiles land.
        reset_hold_frames = 30
    _refresh_flight_hud()

func update_fallback_status() -> void:
    last_profile_status = InputProfiles.fallback_status(Input.get_connected_joypads())
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

func set_paused(value: bool) -> void:
    paused = value
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
    layer.add_child(entries)

    for entry in main_menu_entries:
        var button := Button.new()
        button.name = entry.replace(" ", "")
        button.text = entry
        entries.add_child(button)
        if entry == "Quick Fly":
            button.pressed.connect(quick_fly.bind(_quick_fly_entry_state()))
        elif entry == "Controller":
            button.pressed.connect(begin_controller_setup)

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
        main_menu_layer.visible = screen == "main_menu"
    if flight_hud_layer != null:
        flight_hud_layer.visible = screen != "main_menu"
    key_hints_label.text = KEY_HINTS_TEXT
    arm_takeoff_button.disabled = screen == "main_menu"
    if screen == "preflight":
        var armed := _flight_control_armed()
        arm_status_label.text = "Throttle LOW -> %s -> press T or ARM" % ["ARMED" if armed else "DISARMED"]
        arm_takeoff_button.text = "ARM / TAKEOFF (T)"
    elif screen == "flight":
        var armed := _flight_control_armed()
        arm_status_label.text = "%s | %s" % ["ARMED" if armed else "DISARMED", "PAUSED" if paused else "TAKEOFF"]
        arm_takeoff_button.text = "ARM / TAKEOFF (T)"
    elif screen == "fallback_prompt":
        arm_status_label.text = last_error_message
        arm_takeoff_button.text = "USE KEYBOARD FALLBACK"
    elif screen == "controller_setup":
        arm_status_label.text = last_error_message
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

func _quick_fly_entry_state() -> String:
    return "no_controller" if Input.get_connected_joypads().is_empty() else "calibrated"

func _handle_primary_action() -> void:
    if screen == "fallback_prompt":
        accept_fallback()
    elif screen in ["preflight", "flight"]:
        arm_and_takeoff()
    elif screen in ["controller_setup", "error"]:
        screen = "main_menu"
        last_error_message = ""
        _refresh_flight_hud()

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
