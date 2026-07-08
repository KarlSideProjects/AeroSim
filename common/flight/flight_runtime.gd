extends Node3D

const InputProfiles = preload("res://common/flight/input_profiles.gd")

@onready var fallback_status_label: Label3D = %FallbackStatus
@onready var drone_body = get_node_or_null("DroneBody")

var native: Object
var paused := false
var exit_requested := false
var takeoff_requested := false
var reset_count := 0
var last_profile_status := ""
var last_collision_authority := -1
var collision_handoff_count := 0

func _ready() -> void:
    native = ClassDB.instantiate("AeroSimNative")
    if native == null:
        push_error("AeroSimNative is not registered")
        return
    update_fallback_status()

func _unhandled_input(event: InputEvent) -> void:
    if event.is_action_pressed("flight_takeoff"):
        request_takeoff()
    elif event.is_action_pressed("flight_pause"):
        paused = not paused
    elif event.is_action_pressed("flight_respawn"):
        respawn()
    elif event.is_action_pressed("flight_exit"):
        exit_requested = true

func _physics_process(_delta: float) -> void:
    if native == null or paused or not takeoff_requested:
        return
    if not native.call("flight_control_armed"):
        native.call("arm_flight_control", 0.0)
    var row: PackedFloat64Array
    if drone_body != null:
        _sync_native_from_drone()
        var energy_limit := _kinetic(drone_body.linear_velocity, drone_body.angular_velocity)
        row = native.call(
            "step_collision_angle_mode",
            Engine.physics_ticks_per_second,
            1000,
            0.75,
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
        row = native.call("step_angle_mode", Engine.physics_ticks_per_second, 1000, 0.75, 0.0, 0.0, 0.0)
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
    takeoff_requested = true
    if drone_body != null:
        drone_body.reset_contact()
        drone_body.position = Vector3(-1.0, 0.0, 0.0)
        drone_body.linear_velocity = Vector3(30.0, 0.0, 0.0)
        drone_body.angular_velocity = Vector3.ZERO

func respawn() -> void:
    reset_count += 1
    takeoff_requested = false
    if native != null:
        native.call("reset_flight")
    if drone_body != null:
        drone_body.reset_contact()
        drone_body.linear_velocity = Vector3.ZERO
        drone_body.angular_velocity = Vector3.ZERO

func update_fallback_status() -> void:
    last_profile_status = InputProfiles.fallback_status(Input.get_connected_joypads())
    fallback_status_label.text = last_profile_status

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
