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

    func apply_native_state(position: Vector3, orientation: Quaternion, velocity: Vector3, angular: Vector3) -> void:
        global_position = position
        global_transform = Transform3D(Basis(orientation), position)
        linear_velocity = velocity
        angular_velocity = angular

    func reset_contact() -> void:
        contact_seen = false
        contact_normal = Vector3.ZERO
        contact_impulse = Vector3.ZERO


class FakeSecondaryNative extends RefCounted:
    var last_step_method := ""
    var last_acro_controls := {}
    var rate_stick_value := 0.5
    var rate_stick_calls := 0
    var a5_config := {"enabled": false, "prop_radius_m": 0.0, "coeff_1": 0.0, "coeff_2": 0.0, "coeff_3": 0.0}
    var last_a5_source_position := Vector3.ZERO

    func a5_downwash_configuration() -> Dictionary:
        return a5_config.duplicate(true)

    func refresh_imu_sample() -> void:
        pass

    func betaflight_stick_for_rate(_rate: float, _rc_rate: float, _super_rate: float, _expo: float) -> float:
        rate_stick_calls += 1
        return rate_stick_value

    func set_a5_downwash_model(enabled: bool, radius: float, coeff_1: float, coeff_2: float, coeff_3: float) -> bool:
        a5_config = {"enabled": enabled, "prop_radius_m": radius, "coeff_1": coeff_1, "coeff_2": coeff_2, "coeff_3": coeff_3}
        return true

    func set_a5_downwash_source_position(x: float, y: float, z: float) -> void:
        last_a5_source_position = Vector3(x, y, z)

    func sync_flight_state(..._args) -> void:
        pass

    func step_collision_angle_mode(..._args) -> PackedFloat64Array:
        last_step_method = "step_collision_angle_mode"
        return PackedFloat64Array([0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.1, 2.2, 3.3])

    func step_collision_acro_mode(...args) -> PackedFloat64Array:
        last_step_method = "step_collision_acro_mode"
        last_acro_controls = {
            "throttle": args[2],
            "roll": args[3],
            "pitch": args[4],
            "yaw": args[5],
        }
        return PackedFloat64Array([0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.1, 2.2, 3.3])


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


func test_named_land_completion_accepts_the_resting_body_clearance() -> void:
    var runtime := FlightRuntime.new()
    autofree(runtime)
    var body := _body(Vector3.ZERO, 0.0)
    body.global_position = runtime._spawn_position() + Vector3(0.0, 0.16, 0.0)
    runtime.secondary_drone_body = body
    runtime._airsim_vehicle_names = ["DroneA", "DroneB"]
    runtime._airsim_vehicle_contexts["DroneB"] = {
        "command_state": {"method": "land", "args": []},
        "hold_controls": {},
        "command_remaining_frames": 0,
        "contact_this_frame": false,
    }

    assert_true(runtime._airsim_task_complete("DroneB"))


func test_named_state_reports_landed_for_the_resting_body_clearance() -> void:
    var runtime := FlightRuntime.new()
    autofree(runtime)
    var body := _body(Vector3.ZERO, 0.0)
    body.global_position = runtime._spawn_position() + Vector3(0.0, 0.16, 0.0)
    runtime.secondary_drone_body = body
    runtime._airsim_secondary_native = FakeSecondaryNative.new()
    runtime._airsim_vehicle_names = ["DroneA", "DroneB"]
    runtime.airsim_session = AirSimSession.new(Engine.physics_ticks_per_second)

    var state_result: Dictionary = runtime._airsim_state("DroneB")

    assert_true(state_result.ok)
    assert_eq(state_result.state.landed_state, 0)


func test_secondary_rotate_by_yaw_rate_uses_secondary_body_and_primary_sign() -> void:
    var runtime := FlightRuntime.new()
    autofree(runtime)
    runtime.drone_body = _body(Vector3(4.0, 0.0, 0.0), 0.0)
    var secondary_body := _body(Vector3.ZERO, 0.0)

    var controls: Dictionary = runtime._airsim_secondary_controls(
        {"command_state": {"method": "rotateByYawRate", "args": [30.0, 1.0]}},
        secondary_body)

    assert_eq(String(controls.get("mode", "")), "ANGLE")
    assert_eq(float(controls.get("yaw_rate", 0.0)), -30.0)
    assert_eq(float(controls.get("roll", 0.0)), 0.0)
    assert_eq(float(controls.get("pitch", 0.0)), 0.0)


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
    assert_almost_eq(secondary_body.angular_velocity.x, 1.1, 0.000001)
    assert_almost_eq(secondary_body.angular_velocity.y, 2.2, 0.000001)
    assert_almost_eq(secondary_body.angular_velocity.z, 3.3, 0.000001)
    var completed_context: Dictionary = runtime._airsim_vehicle_contexts["DroneB"]
    assert_true(completed_context.command_state.is_empty())
    assert_eq(completed_context.command_remaining_frames, 0)


func test_secondary_angle_rates_use_secondary_native_stick_mapping() -> void:
    var runtime := FlightRuntime.new()
    autofree(runtime)
    var primary_native := FakeSecondaryNative.new()
    primary_native.rate_stick_value = 0.1
    var secondary_native := FakeSecondaryNative.new()
    secondary_native.rate_stick_value = 0.7
    runtime.native = primary_native
    runtime._airsim_secondary_native = secondary_native

    var controls: Dictionary = runtime._airsim_secondary_controls(
        {"command_state": {"method": "moveByAngleRatesThrottle", "args": [0.1, -0.2, 0.3, 0.6, 1.0]}},
        _body(Vector3.ZERO, 0.0))

    assert_eq(float(controls.acro_roll), 0.7)
    assert_eq(float(controls.acro_pitch), 0.7)
    assert_eq(float(controls.acro_yaw), 0.7)
    assert_eq(primary_native.rate_stick_calls, 0)
    assert_eq(secondary_native.rate_stick_calls, 3)


func test_secondary_runtime_applies_configured_a5_and_primary_source_each_substep() -> void:
    var runtime := FlightRuntime.new()
    autofree(runtime)
    var primary_body := _body(Vector3.ZERO, 0.0)
    primary_body.global_position = Vector3(2.0, 3.0, 4.0)
    var secondary_body := _body(Vector3.ZERO, 0.0)
    var primary_native := FakeSecondaryNative.new()
    primary_native.a5_config = {"enabled": true, "prop_radius_m": 0.0231348, "coeff_1": 2267.18, "coeff_2": 0.16, "coeff_3": -0.11}
    var secondary_native := FakeSecondaryNative.new()
    runtime.drone_body = primary_body
    runtime.secondary_drone_body = secondary_body
    runtime.native = primary_native
    runtime._airsim_secondary_native = secondary_native
    runtime._airsim_vehicle_names = ["DroneA", "DroneB"]
    runtime._airsim_vehicle_contexts["DroneB"] = {
        "api_control": true,
        "armed": true,
        "command_state": {"method": "hover", "args": []},
        "hold_controls": {},
        "command_remaining_frames": 1,
        "last_velocity": Vector3.ZERO,
    }

    runtime._step_secondary_airsim_vehicle("DroneB")

    assert_true(bool(secondary_native.a5_config.enabled))
    assert_almost_eq(float(secondary_native.a5_config.prop_radius_m), 0.0231348, 0.0000001)
    assert_eq(secondary_native.last_a5_source_position, primary_body.global_position)


func test_secondary_angular_state_tracks_body_acceleration_and_publishes_it() -> void:
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
    runtime.airsim_session = AirSimSession.new(Engine.physics_ticks_per_second)
    runtime._airsim_vehicle_contexts["DroneB"] = {
        "api_control": true,
        "armed": true,
        "command_state": {"method": "hover", "args": []},
        "hold_controls": {},
        "command_remaining_frames": 1,
        "last_velocity": Vector3.ZERO,
        "last_body_angular_velocity": Vector3.ZERO,
        "angular_acceleration": Vector3.ZERO,
    }

    runtime._step_secondary_airsim_vehicle("DroneB")

    var context: Dictionary = runtime._airsim_vehicle_contexts["DroneB"]
    assert_eq(context.last_body_angular_velocity, Vector3(1.1, 2.2, 3.3))
    assert_eq(
        context.angular_acceleration,
        Vector3(1.1, 2.2, 3.3) * float(Engine.physics_ticks_per_second))
    var state_result: Dictionary = runtime._airsim_state("DroneB")
    assert_true(state_result.ok)
    var angular_acceleration: Dictionary = state_result.state.kinematics_estimated.angular_acceleration
    assert_almost_eq(float(angular_acceleration.x_val), 1.1 * Engine.physics_ticks_per_second, 0.000001)
    assert_almost_eq(float(angular_acceleration.y_val), 3.3 * Engine.physics_ticks_per_second, 0.000001)
    assert_almost_eq(float(angular_acceleration.z_val), -2.2 * Engine.physics_ticks_per_second, 0.000001)


func test_secondary_kinematic_context_resets_without_an_acceleration_spike() -> void:
    var runtime := FlightRuntime.new()
    autofree(runtime)
    runtime._airsim_vehicle_contexts["DroneB"] = {
        "last_velocity": Vector3(4.0, 5.0, 6.0),
        "linear_acceleration": Vector3(7.0, 8.0, 9.0),
        "last_body_angular_velocity": Vector3(1.0, 2.0, 3.0),
        "angular_acceleration": Vector3(4.0, 5.0, 6.0),
    }

    runtime._reset_airsim_flight_state()

    var context: Dictionary = runtime._airsim_vehicle_contexts["DroneB"]
    assert_eq(context.last_velocity, Vector3.ZERO)
    assert_eq(context.linear_acceleration, Vector3.ZERO)
    assert_eq(context.last_body_angular_velocity, Vector3.ZERO)
    assert_eq(context.angular_acceleration, Vector3.ZERO)
