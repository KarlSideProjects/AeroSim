extends Node3D

const InputProfiles = preload("res://common/flight/input_profiles.gd")

@onready var fallback_status_label: Label3D = %FallbackStatus

var native: Object
var paused := false
var exit_requested := false
var takeoff_requested := false
var reset_count := 0
var last_profile_status := ""

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
    native.call("step_angle_mode", Engine.physics_ticks_per_second, 1000, 0.75, 0.0, 0.0, 0.0)

func request_takeoff() -> void:
    takeoff_requested = true

func respawn() -> void:
    reset_count += 1
    takeoff_requested = false
    if native != null:
        native.call("reset_flight")

func update_fallback_status() -> void:
    last_profile_status = InputProfiles.fallback_status(Input.get_connected_joypads())
    fallback_status_label.text = last_profile_status
