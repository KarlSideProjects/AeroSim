extends SceneTree

const HardwareConfig = preload("res://common/flight/hardware_config.gd")


class RuntimeFixture:
    extends RefCounted

    var native: Object


func _init() -> void:
    var scenario := ""
    var args := OS.get_cmdline_user_args()
    for index in range(args.size() - 1):
        if args[index] == "--scenario":
            scenario = args[index + 1]
    var ok := false
    match scenario:
        "sparse_px4":
            ok = _verify_sparse_px4()
        "negative":
            ok = _verify_negative_step()
        "legacy_atomic":
            ok = _verify_legacy_atomic()
        "collision_px4_rollback":
            ok = _verify_collision_px4_rollback()
        "huge_angle":
            ok = _verify_huge_angle_step()
        "trajectory_contract":
            ok = _verify_trajectory_contract()
        "hardware_mass":
            ok = _verify_hardware_mass()
        "imu_rollback":
            ok = _verify_imu_rollback()
        _:
            push_error("--scenario sparse_px4, negative, legacy_atomic, collision_px4_rollback, huge_angle, trajectory_contract, hardware_mass, or imu_rollback is required")
    quit(0 if ok else 1)


func _native() -> Object:
    if not ClassDB.class_exists("AeroSimNative"):
        push_error("AeroSimNative is not registered")
        return null
    var native: Object = ClassDB.instantiate("AeroSimNative")
    if native == null:
        push_error("AeroSimNative could not be instantiated")
    return native


func _verify_sparse_px4() -> bool:
    var native := _native()
    if native == null:
        return false
    if not _configure_airframe(native):
        return false
    native.call("step_px4_actuator_mode", 0, 240, 0.0, 0.0, 0.0, 0.0)
    if String(native.call("last_step_error")).is_empty():
        push_error("invalid PX4 call did not establish a retained error")
        return false
    var row: PackedFloat64Array = native.call("step_px4_actuator_mode", 1000, 240, 0.0, 0.0, 0.0, 0.0)
    if not row.is_empty() or String(native.call("last_step_error")) != "AeroSimNative.step_px4_actuator_mode: InvalidConfig: timing":
        push_error("unschedulable PX4 timing must be rejected transactionally")
        return false
    return true


func _verify_negative_step() -> bool:
    var native := _native()
    if native == null:
        return false
    var row: PackedFloat64Array = native.call("step_angle_mode", 240, 1000, NAN, 0.0, 0.0, 0.0)
    var expected := "AeroSimNative.step_angle_mode: InvalidCommand: command/config/state"
    if not row.is_empty() or String(native.call("last_step_error")) != expected:
        push_error("invalid public step did not expose the exact native error")
        return false
    return true


func _verify_legacy_atomic() -> bool:
    for method in ["step_simulation", "step_dual_aircraft_simulation"]:
        var failed := _native()
        var untouched := _native()
        var disarmed := _native()
        if failed == null or untouched == null or disarmed == null:
            return false
        for native in [failed, untouched, disarmed]:
            if not _configure_airframe(native):
                return false
            if method == "step_dual_aircraft_simulation" and not native.call("set_dual_aircraft_positions", 0.0, 1.0, 0.0, 0.0, 0.0, 0.0):
                push_error("legacy dual setup failed")
                return false
        var disarmed_row: PackedFloat64Array = disarmed.callv(method, [240, 1000, 1.0])
        var expected_size := 11 if method == "step_dual_aircraft_simulation" else 12
        if disarmed_row.size() != expected_size or not String(disarmed.call("last_step_error")).is_empty():
            push_error("disarmed legacy step must remain legal")
            return false
        if not failed.call("arm_flight_control", 0.0) or not untouched.call("arm_flight_control", 0.0):
            push_error("legacy atomic setup could not arm")
            return false
        var first_failed: PackedFloat64Array = failed.callv(method, [240, 1000, 1.0])
        var first_untouched: PackedFloat64Array = untouched.callv(method, [240, 1000, 1.0])
        if first_failed.is_empty() or first_failed != first_untouched:
            push_error("legacy atomic setup did not produce matching armed steps")
            return false
        for thrust in [NAN, -1.0, 5.0]:
            var rejected: PackedFloat64Array = failed.callv(method, [240, 1000, thrust])
            var expected_error := "AeroSimNative.%s: InvalidCommand: thrust" % method
            if not rejected.is_empty() or String(failed.call("last_step_error")) != expected_error:
                push_error("legacy invalid thrust must report exactly one native error")
                return false
            var continued: PackedFloat64Array = failed.callv(method, [240, 1000, 1.0])
            var expected: PackedFloat64Array = untouched.callv(method, [240, 1000, 1.0])
            if continued.is_empty() or continued != expected or not String(failed.call("last_step_error")).is_empty():
                push_error("legacy rejected thrust must preserve the next legal continuation")
                return false
    return true


func _verify_collision_px4_rollback() -> bool:
    var native := _native()
    if native == null or not _configure_airframe(native):
        return false
    var args := [240, 1000, 0.5, 0.5, 0.5, 0.5, false,
        0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
        0.0, 0.0, 0.0, 0.0, 0.0, 0.0, -1.0]
    var initial: PackedFloat64Array = native.callv("step_collision_px4_actuator_mode", args)
    if initial.is_empty():
        push_error("collision PX4 rollback setup did not produce a legal frame")
        return false
    var snapshot: Dictionary = native.call("telemetry_snapshot")
    native.call("set_external_force_world", 1.0e308, 0.0, 0.0)
    args[0] = 1
    args[1] = 1
    var priming: PackedFloat64Array = native.callv("step_collision_px4_actuator_mode", args)
    if priming.is_empty():
        push_error("collision PX4 overflow setup did not produce a finite first frame")
        return false
    snapshot = native.call("telemetry_snapshot")
    var rejected: PackedFloat64Array = native.callv("step_collision_px4_actuator_mode", args)
    var expected_error := "AeroSimNative.step_collision_px4_actuator_mode: InvalidControlOutput: command/contact/config/state"
    var after: Dictionary = native.call("telemetry_snapshot")
    if not rejected.is_empty() or String(native.call("last_step_error")) != expected_error or \
            int(after.get("publish_count", -1)) != int(snapshot.get("publish_count", -2)) or \
            int(after.get("timestamp_us", -1)) != int(snapshot.get("timestamp_us", -2)):
        push_error("overflowed collision PX4 frame must roll back without publishing telemetry")
        return false
    return true


func _verify_huge_angle_step() -> bool:
    var native := _native()
    if native == null or not _configure_airframe(native) or not native.call("arm_flight_control", 0.0):
        return false
    var row: PackedFloat64Array = native.call("step_angle_mode", 240, 1000, 0.5, 1.0e300, 0.0, 0.0)
    if row.size() != 12 or not String(native.call("last_step_error")).is_empty():
        push_error("huge finite public angle command must complete without an error")
        return false
    return true


func _verify_trajectory_contract() -> bool:
    var native := _native()
    if native == null or not _configure_airframe(native):
        return false
    for thrust in [NAN, -1.0, 5.0]:
        var result: Dictionary = native.call("simulate_trajectory", 1.0, 240, 1000, thrust)
        if String(result.get("status", "")) != "InvalidCommand" or not PackedFloat64Array(result.get("rows", PackedFloat64Array())).is_empty() or int(result.get("failed_frame", -2)) != -1:
            push_error("trajectory must reject invalid public thrust commands without rows")
            return false
    return true


func _verify_hardware_mass() -> bool:
    var native := _native()
    if native == null:
        return false
    var runtime := RuntimeFixture.new()
    runtime.native = native
    var hardware_config := HardwareConfig.new()
    if not hardware_config.apply_to_runtime(runtime, "res://config/drones/5_inch_6s.json"):
        push_error("runtime hardware preset could not configure native mass: %s" % hardware_config.last_error)
        return false
    var mass_kg := float(hardware_config.current.aircraft.mass_kg)
    if absf(float(native.call("hardware_power_diagnostics").get("mass_kg", 0.0)) - mass_kg) > 1e-9:
        push_error("runtime hardware preset did not reach native mass diagnostics")
        return false
    if not native.call("arm_flight_control", 0.0):
        push_error("runtime hardware mass check could not arm native flight control")
        return false
    var row: PackedFloat64Array = native.call("step_simulation", 240, 1000, mass_kg * 9.80665)
    if row.size() != 12 or absf(float(row[2])) > 1e-6:
        push_error("runtime hardware preset mass must produce a native hover trajectory")
        return false
    return true


func _configure_airframe(native: Object) -> bool:
    var per_motor := {
        "inertia_frd": Vector3(0.01, 0.01, 0.02),
        "position_frd": [Vector3(-0.1, 0.1, 0.0), Vector3(0.1, 0.1, 0.0), Vector3(-0.1, -0.1, 0.0), Vector3(0.1, -0.1, 0.0)],
        "spin_direction": [1.0, -1.0, -1.0, 1.0],
        "max_thrust_per_motor_newtons": 1.0,
        "max_current_per_motor_a": 1.0,
        "yaw_torque_per_newton": 0.01,
    }
    if not native.call("set_hardware_mass_kg", 1.0) or not native.call("set_hardware_power_model", 4.0, 0.5, 0.03, 22.2, 6.0, 0.003, 4.0) or not native.call("set_hardware_telemetry_model", 10000.0, 1000.0) or not native.call("set_hardware_per_motor_model", per_motor):
        push_error("public hardware setup failed")
        return false
    return true


func _configure_noisy_imu(native: Object) -> bool:
    if not _configure_airframe(native):
        return false
    native.call("configure_imu", {
        "noise_enabled": true,
        "bias_enabled": true,
        "random_walk_enabled": true,
        "delay_enabled": true,
        "gyro_noise_density": 0.01,
        "accelerometer_noise_density": 0.2,
        "gyro_bias": Vector3(0.01, -0.02, 0.03),
        "accelerometer_bias": Vector3(0.1, 0.2, 0.3),
        "gyro_bias_drift": 0.003,
        "accelerometer_bias_drift": 0.004,
        "gyro_random_walk": 0.005,
        "accelerometer_random_walk": 0.006,
        "barometer_noise": 0.1,
        "barometer_bias_drift": 0.007,
        "barometer_random_walk": 0.008,
        "sample_delay_frames": 2,
    })
    native.call("reset_flight")
    return bool(native.call("arm_flight_control", 0.0))


func _verify_imu_rollback() -> bool:
    var failed := _native()
    var untouched := _native()
    if failed == null or untouched == null:
        return false
    if not _configure_noisy_imu(failed) or not _configure_noisy_imu(untouched):
        push_error("public IMU rollback setup failed")
        return false
    for _frame in range(3):
        var failed_row: PackedFloat64Array = failed.call("step_angle_mode", 240, 1000, 0.5, 0.0, 0.0, 0.0)
        var untouched_row: PackedFloat64Array = untouched.call("step_angle_mode", 240, 1000, 0.5, 0.0, 0.0, 0.0)
        if failed_row.is_empty() or failed_row != untouched_row:
            push_error("public IMU rollback setup did not produce matching legal steps")
            return false
    failed.call("step_angle_mode", 240, 1000, NAN, 0.0, 0.0, 0.0)
    var continued: PackedFloat64Array = failed.call("step_angle_mode", 240, 1000, 0.5, 0.0, 0.0, 0.0)
    var expected: PackedFloat64Array = untouched.call("step_angle_mode", 240, 1000, 0.5, 0.0, 0.0, 0.0)
    if continued.is_empty() or expected.is_empty() or continued != expected or failed.call("imu_sample") != untouched.call("imu_sample"):
        push_error("failed public IMU step must preserve the next legal continuation")
        return false
    return true
