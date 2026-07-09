extends Node3D

const InputProfiles = preload("res://common/flight/input_profiles.gd")
const HardwareConfig = preload("res://common/flight/hardware_config.gd")
const DEFAULT_HARDWARE_PRESET := "res://config/drones/5_inch_6s.json"
const SPAWN_POSITION := Vector3(-1.0, 0.0, 0.0)
const TAKEOFF_VELOCITY := Vector3(30.0, 0.0, 0.0)
const FLIGHT_THROTTLE := 0.75

@onready var fallback_status_label: Label3D = %FallbackStatus
@onready var drone_body = get_node_or_null("DroneBody")

var native: Object
var paused := false
var exit_requested := false
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

func _ready() -> void:
    _build_main_menu()
    native = ClassDB.instantiate("AeroSimNative")
    if native == null:
        push_error("AeroSimNative is not registered")
        return
    var hardware_config := HardwareConfig.new()
    if not hardware_config.apply_to_runtime(self, DEFAULT_HARDWARE_PRESET):
        last_error_message = hardware_config.last_error
        push_error("Default hardware preset failed: %s" % hardware_config.last_error)
    update_fallback_status()

func _unhandled_input(event: InputEvent) -> void:
    if event.is_action_pressed("flight_takeoff"):
        request_takeoff()
    elif event.is_action_pressed("flight_pause"):
        set_paused(not paused)
    elif event.is_action_pressed("flight_respawn"):
        respawn()
    elif event.is_action_pressed("flight_altitude_hold"):
        toggle_altitude_hold()
    elif event.is_action_pressed("flight_exit"):
        exit_requested = true

func _physics_process(_delta: float) -> void:
    if reset_hold_frames > 0:
        reset_hold_frames -= 1
        if reset_hold_frames == 0 and drone_body != null and not paused:
            drone_body.freeze = false
        return
    if native == null or paused or not takeoff_requested:
        return
    if not native.call("flight_control_armed"):
        native.call("arm_flight_control", 0.0)
    var row: PackedFloat64Array
    if drone_body != null:
        _sync_native_from_drone()
        var energy_limit := _kinetic(drone_body.linear_velocity, drone_body.angular_velocity)
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

func request_takeoff() -> void:
    screen = "flight"
    flight_mode = "ANGLE"
    set_paused(false)
    takeoff_requested = true
    update_fallback_status()
    if drone_body != null:
        drone_body.reset_contact()
        drone_body.global_position = SPAWN_POSITION
        drone_body.linear_velocity = TAKEOFF_VELOCITY
        drone_body.angular_velocity = Vector3.ZERO

func quick_fly(entry_state: String = "calibrated") -> void:
    if entry_state == "no_controller":
        last_error_message = InputProfiles.fallback_status([])
        screen = "fallback_prompt"
        return
    if entry_state == "uncalibrated":
        last_error_message = ""
        screen = "controller_setup"
        return
    if entry_state != "calibrated":
        last_error_message = "Quick Fly cannot continue: %s" % entry_state
        screen = "error"
        return
    request_takeoff()

func accept_fallback() -> void:
    if screen == "fallback_prompt":
        request_takeoff()
        return
    last_error_message = "No fallback prompt is active"
    screen = "error"

func respawn() -> void:
    reset_count += 1
    screen = "flight"
    flight_mode = "ANGLE"
    takeoff_requested = true
    if native != null:
        native.call("reset_flight")
    update_fallback_status()
    if drone_body != null:
        _reset_drone_body()
        # ponytail: short reset hold; replace with real throttle input state when controller profiles land.
        reset_hold_frames = 30

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

func _build_main_menu() -> void:
    var layer := CanvasLayer.new()
    layer.name = "MainMenu"
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
            button.pressed.connect(quick_fly.bind("calibrated"))

func _reset_drone_body() -> void:
    drone_body.reset_contact()
    drone_body.apply_native_state(SPAWN_POSITION, Quaternion.IDENTITY, Vector3.ZERO, Vector3.ZERO)
    drone_body.freeze = true

func _kinetic(linear_velocity: Vector3, angular_velocity: Vector3) -> float:
    return 0.5 * linear_velocity.length_squared() + 0.5 * angular_velocity.length_squared()

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
