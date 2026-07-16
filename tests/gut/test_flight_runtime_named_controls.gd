extends GutTest

const FlightRuntime = preload("res://common/flight/flight_runtime.gd")

class FakeBody extends RefCounted:
    var angular_velocity := Vector3.ZERO
    var contact_seen := false
    var contact_normal := Vector3.ZERO
    var contact_impulse := Vector3.ZERO
    var freeze := false
    var sleeping := false
    var global_position := Vector3.ZERO
    var linear_velocity := Vector3.ZERO
    var rotation := Vector3.ZERO
    var global_transform := Transform3D.IDENTITY

    func apply_native_state(position: Vector3, orientation: Quaternion, velocity: Vector3, _angular: Vector3) -> void:
        global_position = position
        global_transform = Transform3D(Basis(orientation), position)
        linear_velocity = velocity

    func reset_contact() -> void:
        contact_seen = false
        contact_normal = Vector3.ZERO
        contact_impulse = Vector3.ZERO


class FakeSecondaryNative extends RefCounted:
    var last_step_method := ""
    var last_acro_controls := {}

    func a5_downwash_configuration() -> Dictionary:
        return {"enabled": false, "prop_radius_m": 0.0, "coeff_1": 0.0, "coeff_2": 0.0, "coeff_3": 0.0}

    func refresh_imu_sample() -> void:
        pass

    func set_a5_downwash_model(_enabled: bool, _radius: float, _coeff_1: float, _coeff_2: float, _coeff_3: float) -> bool:
        return true

    func set_a5_downwash_source_position(_x: float, _y: float, _z: float) -> void:
        pass

    func sync_flight_state(..._args) -> void:
        pass

    func step_collision_angle_mode(..._args) -> PackedFloat64Array:
        last_step_method = "step_collision_angle_mode"
        return PackedFloat64Array([0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0])

    func step_collision_acro_mode(...args) -> PackedFloat64Array:
        last_step_method = "step_collision_acro_mode"
        last_acro_controls = {
            "throttle": args[2],
            "roll": args[3],
            "pitch": args[4],
            "yaw": args[5],
        }
        return PackedFloat64Array([0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0])


func _body(velocity: Vector3, yaw: float) -> FakeBody:
    var result := FakeBody.new()
    result.linear_velocity = velocity
    result.rotation.y = yaw
    return result


func test_named_velocity_controller_uses_the_selected_body_for_measurement_and_yaw() -> void:
    var runtime := FlightRuntime.new()
    autofree(runtime)
    var primary := _body(Vector3.ZERO, 0.0)
    var secondary := _body(Vector3(4.0, 0.0, 0.0), PI * 0.5)
    var yaw_mode := {"yaw_or_rate": 0.0, "is_rate": false}

    var primary_controls: Dictionary = runtime._airsim_velocity_controls(Vector3.ZERO, 0.0, yaw_mode, primary)
    var secondary_controls: Dictionary = runtime._airsim_velocity_controls(Vector3.ZERO, 0.0, yaw_mode, secondary)

    assert_eq(primary_controls.roll, 0.0)
    assert_gt(secondary_controls.roll, 1.0)
    assert_eq(primary_controls.yaw_rate, 0.0)
    assert_lt(secondary_controls.yaw_rate, -1.0)


func test_secondary_position_commands_use_secondary_body_and_clear_on_completion() -> void:
    var runtime := FlightRuntime.new()
    autofree(runtime)
    var body := _body(Vector3.ZERO, 0.0)
    body.global_position = Vector3(2.0, 1.0, 3.0)
    var cases := [
        {"method": "goHome", "args": []},
        {"method": "moveToPosition", "args": [3.0, 0.0, -2.0, 2.0, 30.0, 0, {"is_rate": true, "yaw_or_rate": 0.0}]},
        {"method": "moveOnPath", "args": [[{"x_val": 3.0, "y_val": 0.0, "z_val": -2.0}], 2.0, 30.0, {"is_rate": true, "yaw_or_rate": 0.0}, -1.0, 1]},
        {"method": "rotateToYaw", "args": [90.0, 30.0, 1.0]},
    ]
    for command in cases:
        var controls: Dictionary = runtime._airsim_secondary_controls({"command_state": command}, body)
        assert_eq(String(controls.get("mode", "")), "ANGLE")
        assert_gt(absf(float(controls.get("roll", 0.0))) + absf(float(controls.get("pitch", 0.0))) + absf(float(controls.get("yaw_rate", 0.0))), 0.0)

    body.global_position = runtime._spawn_position()
    runtime._airsim_vehicle_names = ["DroneA", "DroneB"]
    runtime.secondary_drone_body = body
    runtime._airsim_vehicle_contexts["DroneB"] = {
        "command_state": {"method": "goHome", "args": []},
        "hold_controls": {},
        "command_remaining_frames": 0,
    }
    assert_true(runtime._airsim_task_complete("DroneB"))
    var completed_context: Dictionary = runtime._airsim_vehicle_contexts["DroneB"]
    assert_true(completed_context.command_state.is_empty())
    assert_eq(completed_context.command_remaining_frames, 0)


func test_secondary_angle_rates_use_acro_collision_step_and_clear_command() -> void:
    var runtime := FlightRuntime.new()
    autofree(runtime)
    var primary_body := _body(Vector3.ZERO, 0.0)
    var secondary_body := _body(Vector3.ZERO, 0.0)
    var primary_native := FakeSecondaryNative.new()
    var secondary_native := FakeSecondaryNative.new()
    runtime.drone_body = primary_body
    runtime.secondary_drone_body = secondary_body
    runtime.native = primary_native
    runtime._airsim_secondary_native = secondary_native
    runtime._airsim_vehicle_names = ["DroneA", "DroneB"]
    runtime._airsim_secondary_a5_configuration = primary_native.a5_downwash_configuration()
    runtime._airsim_vehicle_contexts["DroneB"] = {
        "api_control": true,
        "armed": true,
        "command_state": {"method": "moveByAngleRatesThrottle", "args": [0.1, -0.2, 0.3, 0.6, 1.0]},
        "hold_controls": {},
        "command_remaining_frames": 1,
        "last_velocity": Vector3.ZERO,
    }

    runtime._step_secondary_airsim_vehicle("DroneB")

    assert_eq(secondary_native.last_step_method, "step_collision_acro_mode")
    assert_eq(float(secondary_native.last_acro_controls.throttle), 0.6)
    assert_ne(float(secondary_native.last_acro_controls.roll), 0.0)
    assert_ne(float(secondary_native.last_acro_controls.pitch), 0.0)
    assert_ne(float(secondary_native.last_acro_controls.yaw), 0.0)
    var completed_context: Dictionary = runtime._airsim_vehicle_contexts["DroneB"]
    assert_true(completed_context.command_state.is_empty())
    assert_eq(completed_context.command_remaining_frames, 0)
