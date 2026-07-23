extends SceneTree


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
        "imu_rollback":
            ok = _verify_imu_rollback()
        _:
            push_error("--scenario sparse_px4, negative, or imu_rollback is required")
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
    if row.size() < 12 or int(row[11]) != 0:
        push_error("first 1000/240 PX4 frame must succeed with zero substeps")
        return false
    if not String(native.call("last_step_error")).is_empty():
        push_error("successful sparse PX4 frame must clear the retained error")
        return false
    for _frame in range(4):
        row = native.call("step_px4_actuator_mode", 1000, 240, 0.0, 0.0, 0.0, 0.0)
    if int(row[11]) != 1:
        push_error("sparse PX4 frames must retain fractional scheduler progress (got %s)" % row[11])
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
