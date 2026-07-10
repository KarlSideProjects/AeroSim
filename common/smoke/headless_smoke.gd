extends SceneTree

const InputProfiles = preload("res://common/flight/input_profiles.gd")
const CollisionProbeBodyScript = preload("res://common/flight/collision_probe_body.gd")
const HardwareConfig = preload("res://common/flight/hardware_config.gd")
const SmokeScene = preload("res://levels/smoke/smoke.tscn")
const DEFAULT_HARDWARE_PRESET := "res://config/drones/5_inch_6s.json"

class InputProbe:
    extends Node

    var action := ""
    var pressed := false

    func _input(event: InputEvent) -> void:
        if event.is_action_pressed(action):
            pressed = true

var verified_jolt_collision_trials := 0

func _initialize() -> void:
    _run()

func _run() -> void:
    var output_path := _output_path()
    var csv_output_path := _csv_output_path()
    var requested_frames := _requested_frames()
    var requested_seconds := _requested_seconds(requested_frames)
    if not await _verify_keyboard_profile_actions():
        quit(1)
        return
    if not await _verify_gamepad_profile_actions():
        quit(1)
        return
    var input_fallback_status := _input_fallback_status()
    if not input_fallback_status.contains("KeyboardProfile") or not input_fallback_status.contains("non-sim"):
        push_error("No-controller fallback status must explicitly name KeyboardProfile and non-sim control")
        quit(1)
        return

    var native: Object = ClassDB.instantiate("AeroSimNative")
    if native == null:
        push_error("AeroSimNative is not registered")
        quit(1)
        return

    var probe_value: int = native.call("probe_value")

    if probe_value != 47:
        push_error("AeroSimNative.probe_value returned %d" % probe_value)
        quit(1)
        return
    if native.call("arm_flight_control", 0.25):
        push_error("AeroSimNative.arm_flight_control must reject high throttle")
        quit(1)
        return
    if native.call("flight_control_arm_reject_code") != "throttle_not_low":
        push_error("AeroSimNative must expose a high-throttle arm rejection reason")
        quit(1)
        return
    if not _configure_default_power_model(native):
        quit(1)
        return
    if _has_arg("--hardware-only"):
        quit(0 if await _verify_hardware_config_public_path() else 1)
        return
    if not _verify_flight_control_public_path(native):
        quit(1)
        return
    if not _verify_telemetry_snapshot_public_path(native):
        quit(1)
        return
    if _has_arg("--runtime-only"):
        quit(0 if await _verify_runtime_actions() else 1)
        return
    var a3_drag_public_verified := _verify_a3_drag_public_path(native)
    if not a3_drag_public_verified:
        quit(1)
        return
    var a4_a5_public_verified := _verify_a4_a5_public_path(native)
    if not a4_a5_public_verified:
        quit(1)
        return
    var imu_public_verified := _verify_imu_public_path(native)
    if not imu_public_verified:
        quit(1)
        return
    var collision_public_verified := _verify_collision_public_path(native)
    if not collision_public_verified:
        quit(1)
        return
    var jolt_collision_verified := await _verify_jolt_collision_scene(native)
    if not jolt_collision_verified:
        quit(1)
        return
    if not await _verify_runtime_actions():
        quit(1)
        return
    var hardware_config_public_verified := await _verify_hardware_config_public_path()
    if not hardware_config_public_verified:
        quit(1)
        return

    var trajectory := PackedFloat64Array()
    native.call("reset_simulation")
    for _frame in range(requested_frames):
        await physics_frame
        var row: PackedFloat64Array = native.call("step_simulation", Engine.physics_ticks_per_second, 1000, 0.0)
        trajectory.append_array(row)

    var mobile_trajectory: PackedFloat64Array = native.call("simulate_trajectory", 1.0, 120, 500, 0.0)
    var stride: int = native.call("trajectory_stride")

    if trajectory.is_empty() or mobile_trajectory.is_empty() or stride != 12:
        push_error("AeroSimNative.simulate_trajectory returned invalid data")
        quit(1)
        return

    if not _write_trajectory_csv(csv_output_path, trajectory, stride):
        quit(1)
        return

    var file := FileAccess.open(output_path, FileAccess.WRITE)
    if file == null:
        push_error("Cannot write smoke output: %s" % output_path)
        quit(1)
        return

    file.store_string(JSON.stringify({
        "schema_version": 1,
        "native_probe": probe_value,
        "physics_ticks_per_second": Engine.physics_ticks_per_second,
        "requested_seconds": float(requested_frames) / float(Engine.physics_ticks_per_second),
        "simulated_frames": requested_frames,
        "trajectory_csv": csv_output_path,
        "trajectory_stride": stride,
        "trajectory_samples": int(trajectory.size() / stride),
        "input_fallback_status": input_fallback_status,
        "a3_drag_public_path": a3_drag_public_verified,
        "a4_a5_public_path": a4_a5_public_verified,
        "imu_public_path": imu_public_verified,
        "collision_public_path": collision_public_verified,
        "jolt_collision_handoff": jolt_collision_verified,
        "jolt_collision_trials": verified_jolt_collision_trials,
        "hardware_config_public_path": hardware_config_public_verified,
        "desktop_substep_hz": 1000,
        "desktop_substeps": int(trajectory[trajectory.size() - 1]),
        "mobile_substep_hz": 500,
        "mobile_substeps_1s": int(mobile_trajectory[mobile_trajectory.size() - 1])
    }))
    file.close()
    quit(0)

func _input_fallback_status() -> String:
    return InputProfiles.fallback_status(Input.get_connected_joypads())

func _configure_default_power_model(native: Object) -> bool:
    var loader := HardwareConfig.new()
    var preset: Dictionary = loader.load_preset(DEFAULT_HARDWARE_PRESET)
    if not loader.last_ok:
        push_error("Default hardware preset must load for native public-path smoke: %s" % loader.last_error)
        return false
    var power_model: Dictionary = loader.derive_power_model(preset)
    if not power_model.ok:
        push_error("Default hardware preset must derive native public-path power: %s" % power_model.get("error", "unknown"))
        return false
    native.call("set_hardware_mass_kg", float(preset.aircraft.mass_kg))
    if not native.call(
            "set_hardware_power_model",
            float(power_model.max_total_thrust_n),
            float(power_model.hover_throttle),
            float(power_model.motor_tau_s),
            float(power_model.battery_nominal_voltage_v),
            float(power_model.battery_cells),
            float(power_model.battery_cell_resistance_ohm),
            float(power_model.max_total_current_a)
        ):
        push_error("Default hardware preset must apply to native public-path smoke")
        return false
    if native.has_method("set_hardware_telemetry_model") and not native.call(
            "set_hardware_telemetry_model",
            float(power_model.max_motor_rpm),
            float(power_model.battery_remaining_mah)
        ):
        push_error("Default hardware preset must apply native telemetry metadata")
        return false
    return true

func _verify_imu_public_path(native: Object) -> bool:
    for method in ["configure_imu", "imu_configuration", "flight_control_diagnostics", "capture_altitude_hold", "step_altitude_hold_mode"]:
        if not native.has_method(method):
            push_error("AeroSimNative.%s must exist for IMU public configuration and attitude-source diagnostics" % method)
            return false

    var quiet_config := {
        "noise_enabled": false,
        "bias_enabled": false,
        "random_walk_enabled": false,
        "delay_enabled": false,
        "gyro_noise_density": 0.0,
        "accelerometer_noise_density": 0.0,
        "gyro_bias": Vector3.ZERO,
        "accelerometer_bias": Vector3.ZERO,
        "gyro_bias_drift": 0.0,
        "accelerometer_bias_drift": 0.0,
        "gyro_random_walk": 0.0,
        "accelerometer_random_walk": 0.0,
        "barometer_noise": 0.0,
        "barometer_bias_drift": 0.0,
        "barometer_random_walk": 0.0,
        "sample_delay_frames": 0
    }
    native.call("configure_imu", quiet_config)
    if not _same_imu_config(native.call("imu_configuration"), quiet_config):
        push_error("AeroSimNative must echo disabled IMU noise/bias/random-walk/delay configuration")
        return false

    var noisy_config := {
        "noise_enabled": true,
        "bias_enabled": true,
        "random_walk_enabled": true,
        "delay_enabled": true,
        "gyro_noise_density": 0.003,
        "accelerometer_noise_density": 0.08,
        "gyro_bias": Vector3(0.01, -0.02, 0.03),
        "accelerometer_bias": Vector3(0.1, -0.2, 0.3),
        "gyro_bias_drift": 0.0002,
        "accelerometer_bias_drift": 0.003,
        "gyro_random_walk": 0.0004,
        "accelerometer_random_walk": 0.005,
        "barometer_noise": 0.12,
        "barometer_bias_drift": 0.01,
        "barometer_random_walk": 0.02,
        "sample_delay_frames": 2
    }
    native.call("configure_imu", noisy_config)
    if not _same_imu_config(native.call("imu_configuration"), noisy_config):
        push_error("AeroSimNative must echo enabled IMU noise/bias/random-walk/delay configuration")
        return false
    var hover_throttle := float(native.call("hardware_power_diagnostics").get("hover_throttle", 0.5))

    native.call("reset_flight")
    if not native.call("arm_flight_control", 0.0):
        push_error("IMU public path should arm flight control from low throttle")
        return false
    native.call("step_angle_mode", Engine.physics_ticks_per_second, 1000, hover_throttle, 0.0, 0.0, 0.0)
    var diagnostics: Dictionary = native.call("flight_control_diagnostics")
    if diagnostics.get("uses_estimated_attitude", false) != true:
        push_error("Flight control diagnostics must prove attitude source is the IMU estimate, not truth")
        return false
    native.call("configure_imu", quiet_config)
    native.call("reset_flight")
    if not native.call("arm_flight_control", 0.0):
        push_error("Altitude Hold public path should arm from low throttle")
        return false
    for _frame in range(Engine.physics_ticks_per_second * 2):
        native.call("step_angle_mode", Engine.physics_ticks_per_second, 1000, hover_throttle, 0.0, 0.0, 0.0)
    var angle_diagnostics: Dictionary = native.call("flight_control_diagnostics")
    var angle_thrust := float(angle_diagnostics.get("motor_thrust_newtons", 0.0))
    native.call("capture_altitude_hold")
    native.call("step_altitude_hold_mode", Engine.physics_ticks_per_second, 1000, hover_throttle, 0.0, 0.0, 0.0)
    var hold_entry_diagnostics: Dictionary = native.call("flight_control_diagnostics")
    var hold_entry_thrust := float(hold_entry_diagnostics.get("motor_thrust_newtons", 0.0))
    if str(hold_entry_diagnostics.get("flight_mode", "")) != "ALTITUDE_HOLD":
        push_error("Altitude Hold diagnostics must report the active flight mode")
        return false
    if absf(hold_entry_thrust - angle_thrust) > 0.05 * 9.80665:
        push_error("Altitude Hold public path must enter without a thrust step")
        return false
    var altitude_noise_config := quiet_config.duplicate()
    altitude_noise_config.noise_enabled = true
    altitude_noise_config.barometer_noise = 0.10
    native.call("configure_imu", altitude_noise_config)
    native.call("reset_flight")
    if not native.call("arm_flight_control", 0.0):
        push_error("Altitude Hold drift public path should arm from low throttle")
        return false
    for _frame in range(Engine.physics_ticks_per_second * 2):
        native.call("step_angle_mode", Engine.physics_ticks_per_second, 1000, hover_throttle, 0.0, 0.0, 0.0)
    native.call("sync_flight_state", 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0)
    native.call("capture_altitude_hold")
    var altitude_hold_row := PackedFloat64Array()
    var max_altitude_drift := 0.0
    for _frame in range(Engine.physics_ticks_per_second * 60):
        altitude_hold_row = native.call("step_altitude_hold_mode", Engine.physics_ticks_per_second, 1000, hover_throttle, 0.0, 0.0, 0.0)
        max_altitude_drift = maxf(max_altitude_drift, absf(float(altitude_hold_row[2])))
    if max_altitude_drift > 0.15:
        push_error("G2.6 public Altitude Hold must keep 60 second drift within +/-15 cm with barometer noise; max drift=%.6f m" % max_altitude_drift)
        return false
    var hold_exit_diagnostics: Dictionary = native.call("flight_control_diagnostics")
    var hold_exit_thrust := float(hold_exit_diagnostics.get("motor_thrust_newtons", 0.0))
    native.call("step_angle_mode", Engine.physics_ticks_per_second, 1000, hover_throttle, 0.0, 0.0, 0.0)
    var angle_exit_diagnostics: Dictionary = native.call("flight_control_diagnostics")
    if str(angle_exit_diagnostics.get("flight_mode", "")) != "ANGLE":
        push_error("Angle diagnostics must report the active flight mode after leaving Altitude Hold")
        return false
    if absf(float(angle_exit_diagnostics.get("motor_thrust_newtons", 0.0)) - hold_exit_thrust) > 0.05 * 9.80665:
        push_error("Altitude Hold public path must exit without a thrust step")
        return false
    native.call("configure_imu", quiet_config)
    native.call("reset_flight")
    return true

func _same_imu_config(actual: Dictionary, expected: Dictionary) -> bool:
    for key in expected:
        if not actual.has(key) or not _same_imu_value(actual[key], expected[key]):
            return false
    return true

func _same_imu_value(actual: Variant, expected: Variant) -> bool:
    if expected is Vector3:
        return actual is Vector3 and actual.distance_to(expected) <= 1e-9
    if expected is bool:
        return actual == expected
    if expected is int:
        return int(actual) == expected
    return is_equal_approx(float(actual), float(expected))

func _verify_flight_control_public_path(native: Object) -> bool:
    if not native.has_method("step_acro_mode"):
        push_error("AeroSimNative.step_acro_mode must exist for Acro/rates public path")
        return false

    native.call("reset_flight")
    var disarmed_row: PackedFloat64Array = native.call("step_angle_mode", Engine.physics_ticks_per_second, 1000, 0.75, 0.0, 0.0, 0.0)
    if disarmed_row[2] > 0.0:
        push_error("Disarmed Angle Mode throttle must not produce lift")
        return false

    native.call("reset_flight")
    var bypass_row: PackedFloat64Array = native.call("step_simulation", Engine.physics_ticks_per_second, 1000, 1000.0)
    if bypass_row[2] > 0.0:
        push_error("Public step_simulation must not bypass arm safety with direct thrust")
        return false

    native.call("reset_flight")
    if not native.call("arm_flight_control", 0.0):
        push_error("Low throttle should arm flight control through Godot public path")
        return false
    var armed_row: PackedFloat64Array = native.call("step_angle_mode", Engine.physics_ticks_per_second, 1000, 0.75, 0.0, 0.0, 0.0)
    if armed_row[2] <= disarmed_row[2]:
        push_error("Armed Angle Mode throttle should produce lift")
        return false

    native.call("reset_flight")
    if not native.call("flight_control_armed"):
        push_error("reset_flight should keep armed state for immediate throttle follow")
        return false
    var reset_row: PackedFloat64Array = native.call("step_angle_mode", Engine.physics_ticks_per_second, 1000, 0.0, 0.0, 0.0, 0.0)
    if int(reset_row[11]) <= 0:
        push_error("reset_flight should clear the substep clock before the next step")
        return false

    native.call("reset_flight")
    native.call("arm_flight_control", 0.0)
    var hold_row := PackedFloat64Array()
    for _frame in range(Engine.physics_ticks_per_second * 60):
        hold_row = native.call("step_angle_mode", Engine.physics_ticks_per_second, 1000, 0.5, 0.0, 0.0, 0.0)
    if absf(_row_roll_degrees(hold_row)) > 1.0 or absf(_row_pitch_degrees(hold_row)) > 1.0:
        push_error("G2.3 public Angle Mode drift must stay within 1 degree over 60 seconds")
        return false
    var timing: Dictionary = native.call("flight_control_diagnostics")
    if float(timing.get("pid_target_hz", 0.0)) != 1000.0 or float(timing.get("pid_p99_jitter_fraction", 1.0)) > 0.10 or int(timing.get("pid_samples", 0)) <= 0:
        push_error("G2.1 public PID timing diagnostics must prove P99 jitter <= +/-10%")
        return false

    native.call("reset_flight")
    native.call("arm_flight_control", 0.0)
    var reached_90 := false
    var rise_time_s := 0.0
    var max_roll := 0.0
    var last_outside_2_percent_s := 0.0
    for _frame in range(Engine.physics_ticks_per_second):
        var step_row: PackedFloat64Array = native.call("step_angle_mode", Engine.physics_ticks_per_second, 1000, 0.5, 30.0, 0.0, 0.0)
        var roll := _row_roll_degrees(step_row)
        max_roll = maxf(max_roll, roll)
        if not reached_90 and roll >= 27.0:
            reached_90 = true
            rise_time_s = float(step_row[0])
        if absf(roll - 30.0) > 0.6:
            last_outside_2_percent_s = float(step_row[0])
    if not reached_90 or rise_time_s > 0.150:
        push_error("G2.4 public Angle Mode rise time must be <= 150 ms")
        return false
    if max_roll > 33.0:
        push_error("G2.4 public Angle Mode overshoot must be <= 10%%")
        return false
    if last_outside_2_percent_s > 0.500:
        push_error("G2.4 public Angle Mode must remain in the 2%% band after 500 ms")
        return false

    native.call("reset_flight")
    native.call("arm_flight_control", 0.0)
    native.call("step_acro_mode", Engine.physics_ticks_per_second, 1000, 0.5, 1.0, 0.0, 0.0, 1.0, 0.722222222222, 0.0)
    var acro: Dictionary = native.call("flight_control_diagnostics")
    var roll_rate_dps := rad_to_deg(float(acro.get("angular_velocity_z_rad_s", 0.0)))
    if absf(roll_rate_dps - 720.0) > 720.0 * 0.05:
        push_error("G2.5 public Acro full-stick roll must reach 720 deg/s within 5%%")
        return false
    return true

func _verify_telemetry_snapshot_public_path(native: Object) -> bool:
    for method in ["telemetry_snapshot", "set_hardware_telemetry_model"]:
        if not native.has_method(method):
            push_error("AeroSimNative.%s must exist for status diagram telemetry" % method)
            return false

    native.call("reset_flight")
    native.call("set_hardware_telemetry_model", 15000.0, 1040.0)
    if not native.call("arm_flight_control", 0.0):
        push_error("Telemetry public path should arm from low throttle")
        return false
    var hover_throttle := float(native.call("hardware_power_diagnostics").get("hover_throttle", 0.5))
    var last_row := PackedFloat64Array()
    for _frame in range(Engine.physics_ticks_per_second):
        last_row = native.call("step_angle_mode", Engine.physics_ticks_per_second, 1000, hover_throttle, 0.0, 0.0, 0.0)
    var snapshot: Dictionary = native.call("telemetry_snapshot")
    var required_keys := [
        "schema_version",
        "timestamp_us",
        "snapshot_hz",
        "publish_count",
        "coordinate_frame",
        "motor_order",
        "motors",
        "wind_world_mps",
        "wind_body_mps",
        "turbulence_intensity",
        "ground_effect_gain",
        "downwash_force_n",
        "propwash_disturbance_rad_s2",
        "drag_body_n",
        "battery",
        "pid",
        "armed",
        "mode",
        "source"
    ]
    for key in required_keys:
        if not snapshot.has(key):
            push_error("TelemetrySnapshot missing schema key: %s" % key)
            return false
    if int(snapshot.schema_version) != 1 or str(snapshot.coordinate_frame) != "FRD" or str(snapshot.source) != "native_double_buffer":
        push_error("TelemetrySnapshot must expose schema version, FRD frame, and native double-buffer source")
        return false
    if int(snapshot.timestamp_us) <= 0 or int(snapshot.publish_count) < 30 or float(snapshot.snapshot_hz) != 30.0:
        push_error("TelemetrySnapshot must publish at least 30 Hz")
        return false
    if int(last_row[0] * 1000000.0) - int(snapshot.timestamp_us) > 100000:
        push_error("TelemetrySnapshot latency must be <= 100 ms")
        return false
    var motors: Array = snapshot.motors
    if motors.size() != 4 or snapshot.motor_order != ["rear_right", "front_right", "rear_left", "front_left"]:
        push_error("TelemetrySnapshot must freeze Betaflight quad-X motor order")
        return false
    var diagnostics: Dictionary = native.call("flight_control_diagnostics")
    var total_thrust := 0.0
    for motor_value in motors:
        var motor: Dictionary = motor_value
        total_thrust += float(motor.thrust_newtons)
        if float(motor.speed_rad_s) <= 0.0 or float(motor.current_a) <= 0.0:
            push_error("TelemetrySnapshot motors must expose live thrust/rad_s/current")
            return false
    if absf(total_thrust - float(diagnostics.motor_thrust_newtons)) > 1e-6:
        push_error("TelemetrySnapshot motor thrust must match native flight-control diagnostics")
        return false
    var battery: Dictionary = snapshot.battery
    if float(battery.sag_v) <= 0.0 or float(battery.voltage_v) <= 0.0 or float(battery.remaining_mah) <= 0.0:
        push_error("TelemetrySnapshot battery must expose voltage, sag, and remaining mAh")
        return false
    if snapshot.wind_world_mps != Vector3.ZERO or snapshot.wind_body_mps != Vector3.ZERO:
        push_error("TelemetrySnapshot wind indicators must stay zero until a wind model feeds them")
        return false
    if float(snapshot.turbulence_intensity) != 0.0 or float(snapshot.ground_effect_gain) != 0.0 or float(snapshot.downwash_force_n) != 0.0:
        push_error("TelemetrySnapshot scalar effect indicators must stay zero until runtime models feed them")
        return false
    if snapshot.propwash_disturbance_rad_s2 != Vector3.ZERO or snapshot.drag_body_n != Vector3.ZERO:
        push_error("TelemetrySnapshot vector effect indicators must stay zero until runtime models feed them")
        return false

    for _frame in range(12):
        native.call("step_angle_mode", Engine.physics_ticks_per_second, 1000, 1.0, 0.0, 90.0, 0.0)
    snapshot = native.call("telemetry_snapshot")
    motors = snapshot.motors
    var pid: Array = snapshot.pid
    var first_motor: Dictionary = motors[0]
    var first_pid: Dictionary = pid[0]
    if not bool(first_motor.saturated) or not bool(first_pid.saturated):
        push_error("TelemetrySnapshot must expose motor and PID saturation")
        return false

    if not _verify_status_diagram_no_direct_polling():
        return false
    return true

func _verify_status_diagram_no_direct_polling() -> bool:
    var ui_script := _read_text("res://common/flight/status_diagram_debug.gd")
    if ui_script == "":
        return false
    for forbidden in ["ClassDB", "AeroSimNative", "telemetry_snapshot", "step_angle_mode", "step_simulation", "sync_flight_state"]:
        if ui_script.contains(forbidden):
            push_error("Status diagram UI must consume snapshots only, found forbidden token: %s" % forbidden)
            return false
    for source_path in ["res://src/native/aerosim_flight_control.hpp", "res://src/native/aerosim_flight_control.cpp"]:
        var source := _read_text(source_path)
        if source == "":
            return false
        for forbidden in ["std::mutex", "lock_guard", "unique_lock", "shared_mutex"]:
            if source.contains(forbidden):
                push_error("TelemetrySnapshot exchange must stay double-buffered without mutex-wrapping physics state")
                return false
    return true

func _read_text(path: String) -> String:
    var file := FileAccess.open(path, FileAccess.READ)
    if file == null:
        push_error("Cannot read required verification source: %s" % path)
        return ""
    return file.get_as_text()

func _verify_a3_drag_public_path(native: Object) -> bool:
    for method in ["set_a3_drag_model", "a3_drag_configuration", "sync_flight_state"]:
        if not native.has_method(method):
            push_error("AeroSimNative.%s must exist for A3 drag public configuration" % method)
            return false

    if not native.call("set_a3_drag_model", false, 0.0001, 0.0001, 0.00012, 10000.0, 10000.0, 10000.0, 10000.0):
        push_error("A3 drag public path must accept a disabled valid configuration")
        return false
    var disabled: Dictionary = native.call("a3_drag_configuration")
    if bool(disabled.get("enabled", true)) != false:
        push_error("A3 drag configuration must echo the disabled switch")
        return false

    native.call("reset_simulation")
    native.call("sync_flight_state", 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0, 10.0, 0.0, 0.0, 0.0, 0.0, 0.0)
    var off_row: PackedFloat64Array = native.call("step_simulation", Engine.physics_ticks_per_second, 1000, 0.0)
    if absf(float(off_row[8]) - 10.0) > 1e-9:
        push_error("A3 disabled must not decelerate the public coasting path")
        return false

    if not native.call("set_a3_drag_model", true, 0.0001, 0.0001, 0.00012, 10000.0, 10000.0, 10000.0, 10000.0):
        push_error("A3 drag public path must accept an enabled valid configuration")
        return false
    var enabled: Dictionary = native.call("a3_drag_configuration")
    if bool(enabled.get("enabled", false)) != true:
        push_error("A3 drag configuration must echo the enabled switch")
        return false

    native.call("reset_simulation")
    native.call("sync_flight_state", 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0, 10.0, 0.0, 0.0, 0.0, 0.0, 0.0)
    var on_row: PackedFloat64Array = native.call("step_simulation", Engine.physics_ticks_per_second, 1000, 0.0)
    if float(on_row[8]) >= float(off_row[8]):
        push_error("A3 enabled must decelerate the public coasting path")
        return false
    return true

func _verify_a4_a5_public_path(native: Object) -> bool:
    for method in ["set_a4_ground_effect_model", "a4_ground_effect_configuration", "set_a5_downwash_model", "a5_downwash_configuration", "a5_downwash_force_y", "sync_flight_state"]:
        if not native.has_method(method):
            push_error("AeroSimNative.%s must exist for A4/A5 public configuration" % method)
            return false

    var prop_radius := 0.0231348
    if not native.call("set_hardware_mass_kg", 0.72):
        push_error("A4 public path must accept the 5 inch test mass")
        return false
    if not native.call("set_a4_ground_effect_model", false, 3.16e-10, 11.36859, prop_radius, prop_radius, 12000.0, 12000.0, 12000.0, 12000.0):
        push_error("A4 public path must accept a disabled valid configuration")
        return false
    var a4_disabled: Dictionary = native.call("a4_ground_effect_configuration")
    if bool(a4_disabled.get("enabled", true)) != false:
        push_error("A4 configuration must echo the disabled switch")
        return false

    native.call("reset_flight")
    if not native.call("arm_flight_control", 0.0):
        push_error("A4 public path must arm from low throttle")
        return false
    native.call("sync_flight_state", 0.0, prop_radius, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0)
    var off_y := prop_radius
    for _frame in range(120):
        var off_row: PackedFloat64Array = native.call("step_simulation", Engine.physics_ticks_per_second, 1000, 0.72 * 9.80665)
        off_y = float(off_row[2])

    if not native.call("set_a4_ground_effect_model", true, 3.16e-10, 11.36859, prop_radius, prop_radius, 12000.0, 12000.0, 12000.0, 12000.0):
        push_error("A4 public path must accept an enabled valid configuration")
        return false
    var a4_enabled: Dictionary = native.call("a4_ground_effect_configuration")
    if bool(a4_enabled.get("enabled", false)) != true:
        push_error("A4 configuration must echo the enabled switch")
        return false

    native.call("reset_flight")
    if not native.call("arm_flight_control", 0.0):
        push_error("A4 public path must re-arm from low throttle")
        return false
    native.call("sync_flight_state", 0.0, prop_radius, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0)
    var on_y := prop_radius
    for _frame in range(120):
        var on_row: PackedFloat64Array = native.call("step_simulation", Engine.physics_ticks_per_second, 1000, 0.72 * 9.80665)
        on_y = float(on_row[2])
    if on_y <= off_y + 0.005:
        push_error("A4 enabled public hover must show an observable ground cushion")
        return false

    if not native.call("set_a5_downwash_model", false, prop_radius, 2267.18, 0.16, -0.11):
        push_error("A5 public path must accept a disabled valid configuration")
        return false
    var a5_disabled: Dictionary = native.call("a5_downwash_configuration")
    if bool(a5_disabled.get("enabled", true)) != false:
        push_error("A5 configuration must echo the disabled switch")
        return false
    if absf(float(native.call("a5_downwash_force_y", 0.1, 2.0, 0.0, 0.0, 0.0, 0.0))) > 1e-12:
        push_error("A5 disabled public path must not reduce lift")
        return false
    if not native.call("set_a5_downwash_model", true, prop_radius, 2267.18, 0.16, -0.11):
        push_error("A5 public path must accept an enabled valid configuration")
        return false
    var a5_enabled: Dictionary = native.call("a5_downwash_configuration")
    if bool(a5_enabled.get("enabled", false)) != true:
        push_error("A5 configuration must echo the enabled switch")
        return false
    if float(native.call("a5_downwash_force_y", 0.1, 2.0, 0.0, 0.0, 0.0, 0.0)) >= 0.0:
        push_error("A5 enabled public path must reduce the lower aircraft lift")
        return false
    return true

func _verify_collision_public_path(native: Object) -> bool:
    if not native.has_method("step_collision_acro_mode"):
        push_error("AeroSimNative.step_collision_acro_mode must exist for ACRO collision authority")
        return false
    native.call("reset_flight")
    native.call("set_collision_release_frames", 5)
    if not native.call("arm_flight_control", 0.0):
        push_error("Collision public path should arm from low throttle")
        return false

    var impact: PackedFloat64Array = _step_native_collision(
        native,
        0.5,
        true,
        Vector3.LEFT,
        Vector3.ZERO,
        Vector3.ZERO,
        Vector3.ZERO,
        -1.0
    )
    if impact.size() < 14 or int(impact[12]) != 1 or int(impact[13]) < 1:
        push_error("Collision public path must expose Jolt authority and integrator reset")
        return false

    var clear := PackedFloat64Array()
    for _frame in range(4):
        clear = _step_native_collision(
            native,
            0.8,
            false,
            Vector3.ZERO,
            Vector3.ZERO,
            Vector3.ZERO,
            Vector3.ZERO,
            -1.0
        )
    if clear.size() < 14 or int(clear[12]) != 1:
        push_error("Collision public path must respect configured no-contact release frames")
        return false
    clear = _step_native_collision(
        native,
        0.8,
        false,
        Vector3.ZERO,
        Vector3.ZERO,
        Vector3.ZERO,
        Vector3.ZERO,
        -1.0
    )
    if clear.size() < 14 or int(clear[12]) != 0:
        push_error("Collision public path must return to flight authority after configured clear frames")
        return false
    native.call("reset_flight")
    return true

func _verify_jolt_collision_scene(native: Object) -> bool:
    if ProjectSettings.get_setting("physics/3d/physics_engine", "") != "Jolt Physics":
        push_error("Project must lock physics/3d/physics_engine to Jolt Physics")
        return false

    var diagnostics: Dictionary = native.call("hardware_power_diagnostics")
    var mass_kg := float(diagnostics.get("mass_kg", 0.0))
    if mass_kg <= 0.0:
        push_error("Jolt collision smoke requires a positive configured hardware mass")
        return false

    verified_jolt_collision_trials = 0
    for mode in ["ANGLE", "ACRO"]:
        for scenario in ["wall", "glancing_ground", "pole", "tumble_ground"]:
            for seed in range(100):
                var first: Dictionary = await _run_jolt_collision_trial(native, scenario, seed, mass_kg, mode)
                var second: Dictionary = await _run_jolt_collision_trial(native, scenario, seed, mass_kg, mode)
                if not first.ok or not second.ok or not _same_collision_row(first.row, second.row):
                    push_error("Headless Jolt G0.8 trial failed: %s %s seed %d first=%s second=%s" % [mode, scenario, seed, first.get("reason", ""), second.get("reason", "")])
                    return false
                verified_jolt_collision_trials += 1
    return true

func _run_jolt_collision_trial(native: Object, scenario: String, seed: int, mass_kg: float, mode: String) -> Dictionary:
    var trial_root := Node3D.new()
    trial_root.name = "JoltCollisionTrial"
    root.add_child(trial_root)

    var drone = CollisionProbeBodyScript.new()
    drone.contact_monitor = true
    drone.max_contacts_reported = 4
    drone.gravity_scale = 0.0
    drone.set("continuous_cd", true)
    _add_shape(drone, _drone_shape(scenario))
    trial_root.add_child(drone)

    _setup_jolt_trial_geometry(trial_root, drone, scenario, seed)
    var energy_before := _kinetic(drone.linear_velocity, drone.angular_velocity, mass_kg)

    if drone.get("continuous_cd") != true:
        trial_root.queue_free()
        return {"ok": false, "row": PackedFloat64Array(), "reason": "ccd_off"}

    native.call("reset_flight")
    native.call("arm_flight_control", 0.0)
    var impact_row := PackedFloat64Array()
    var reason := "no_contact"
    for _frame in range(45):
        await physics_frame
        if drone.contact_seen:
            if not _vector_finite(drone.contact_normal) or drone.contact_normal.length() <= 0.0:
                reason = "bad_contact_normal"
                break
            if not _vector_finite(drone.contact_impulse) or drone.contact_impulse.length() <= 0.0:
                reason = "bad_contact_impulse"
                break
            _sync_native_from_body(native, drone)
            var solved_linear: Vector3 = drone.linear_velocity
            var solved_angular: Vector3 = drone.angular_velocity
            impact_row = _step_native_collision(
                native,
                0.5,
                true,
                drone.contact_normal,
                drone.contact_impulse,
                solved_linear,
                solved_angular,
                energy_before,
                mode
            )
            reason = "impact"
            break

    var ok := impact_row.size() >= 24 and int(impact_row[12]) == 1 and int(impact_row[13]) >= 1
    if not ok and reason == "impact":
        reason = "handoff_row"
    ok = ok and _collision_row_finite(impact_row)
    if not ok and reason == "impact":
        reason = "impact_finite"
    ok = ok and _row_normal(impact_row).distance_to(drone.contact_normal) <= 1e-6
    if not ok and reason == "impact":
        reason = "normal_missing"
    ok = ok and _row_impulse(impact_row).length() > 0.0
    ok = ok and _row_impulse(impact_row).distance_to(drone.contact_impulse) <= 1e-6
    if not ok and reason == "impact":
        reason = "impulse_missing"
    ok = ok and float(impact_row[17]) <= energy_before * 1.01 + 1e-9
    if not ok and reason == "impact":
        reason = "energy row=%f limit=%f" % [float(impact_row[17]), energy_before * 1.01]
    if ok:
        _apply_collision_row_to_body(drone, impact_row)
        var body_energy := _kinetic(drone.linear_velocity, drone.angular_velocity, mass_kg)
        ok = _body_state_finite(drone) and body_energy <= energy_before * 1.01 + 1e-4
        if not ok:
            reason = "body_impact_state body=%f limit=%f finite=%s" % [body_energy, energy_before * 1.01, str(_body_state_finite(drone))]
    ok = ok and not (scenario == "wall" and drone.global_position.x > 0.3)
    if not ok and reason == "impact":
        reason = "tunneled"
    if ok:
        var clear := PackedFloat64Array()
        for _frame in range(3):
            await physics_frame
            _sync_native_from_body(native, drone)
            clear = _step_native_clear_collision(native, 0.8, mode)
            _apply_collision_row_to_body(drone, clear)
        ok = clear.size() >= 24 and int(clear[12]) == 0
        if not ok:
            reason = "handoff_clear"
        var vertical_velocity_before_response := float(clear[9])
        for _frame in range(Engine.physics_ticks_per_second / 2):
            await physics_frame
            _sync_native_from_body(native, drone)
            clear = _step_native_clear_collision(native, 0.8, mode)
            _apply_collision_row_to_body(drone, clear)
        ok = ok and clear.size() >= 18 and float(clear[9]) > vertical_velocity_before_response and _collision_row_finite(clear)
        if not ok and reason == "impact":
            reason = "response"
        if ok:
            _apply_collision_row_to_body(drone, clear)
            ok = _body_state_finite(drone) and drone.linear_velocity.y > vertical_velocity_before_response
            if not ok:
                reason = "body_response"
        impact_row = clear
    if ok:
        reason = "ok"

    trial_root.queue_free()
    await process_frame
    return {"ok": ok, "row": impact_row, "reason": reason}

func _step_native_clear_collision(native: Object, throttle: float, mode := "ANGLE") -> PackedFloat64Array:
    return _step_native_collision(
        native,
        throttle,
        false,
        Vector3.ZERO,
        Vector3.ZERO,
        Vector3.ZERO,
        Vector3.ZERO,
        -1.0,
        mode
    )

func _step_native_collision(
    native: Object,
    throttle: float,
    touching: bool,
    normal: Vector3,
    impulse: Vector3,
    resolved_linear: Vector3,
    resolved_angular: Vector3,
    energy_limit: float,
    mode := "ANGLE"
) -> PackedFloat64Array:
    if mode == "ACRO":
        return native.call(
            "step_collision_acro_mode",
            Engine.physics_ticks_per_second,
            1000,
            throttle,
            0.0,
            0.0,
            0.0,
            1.0,
            0.722222222222,
            0.0,
            touching,
            normal.x,
            normal.y,
            normal.z,
            impulse.x,
            impulse.y,
            impulse.z,
            0.0,
            resolved_linear.x,
            resolved_linear.y,
            resolved_linear.z,
            resolved_angular.x,
            resolved_angular.y,
            resolved_angular.z,
            energy_limit
        )
    return native.call(
        "step_collision_angle_mode",
        Engine.physics_ticks_per_second,
        1000,
        throttle,
        0.0,
        0.0,
        0.0,
        touching,
        normal.x,
        normal.y,
        normal.z,
        impulse.x,
        impulse.y,
        impulse.z,
        0.0,
        resolved_linear.x,
        resolved_linear.y,
        resolved_linear.z,
        resolved_angular.x,
        resolved_angular.y,
        resolved_angular.z,
        energy_limit
    )

func _setup_jolt_trial_geometry(parent: Node3D, drone: RigidBody3D, scenario: String, seed: int) -> void:
    if scenario == "wall":
        var wall := StaticBody3D.new()
        wall.position = Vector3.ZERO
        var wall_box := BoxShape3D.new()
        wall_box.size = Vector3(0.2, 2.0, 2.0)
        _add_shape(wall, wall_box)
        parent.add_child(wall)
        drone.position = Vector3(-1.0, _jitter(seed, 1, -0.05, 0.05), _jitter(seed, 2, -0.05, 0.05))
        drone.linear_velocity = Vector3(30.0 + _jitter(seed, 3, -0.25, 0.25), 0.0, 0.0)
    elif scenario == "glancing_ground":
        var ground := StaticBody3D.new()
        ground.position = Vector3.ZERO
        var ground_box := BoxShape3D.new()
        ground_box.size = Vector3(4.0, 0.1, 4.0)
        _add_shape(ground, ground_box)
        parent.add_child(ground)
        var speed := 20.0 + _jitter(seed, 4, -0.5, 0.5)
        var angle := deg_to_rad(5.0)
        drone.position = Vector3(-0.8, 0.16, _jitter(seed, 5, -0.05, 0.05))
        drone.linear_velocity = Vector3(speed * cos(angle), -speed * sin(angle), 0.0)
    elif scenario == "pole":
        var pole := StaticBody3D.new()
        pole.position = Vector3.ZERO
        var pole_shape := CylinderShape3D.new()
        pole_shape.radius = 0.08
        pole_shape.height = 2.0
        _add_shape(pole, pole_shape)
        parent.add_child(pole)
        var z_offset := _jitter(seed, 6, -0.12, 0.12)
        drone.position = Vector3(-1.0, 0.0, z_offset)
        drone.linear_velocity = Vector3(14.0, 0.0, -z_offset * 3.0)
    else:
        var tumble_ground := StaticBody3D.new()
        tumble_ground.position = Vector3.ZERO
        var tumble_box := BoxShape3D.new()
        tumble_box.size = Vector3(4.0, 0.1, 4.0)
        _add_shape(tumble_ground, tumble_box)
        parent.add_child(tumble_ground)
        drone.position = Vector3(_jitter(seed, 7, -0.2, 0.2), 0.8, _jitter(seed, 8, -0.2, 0.2))
        drone.linear_velocity = Vector3(_jitter(seed, 9, -2.0, 2.0), -8.0, _jitter(seed, 10, -2.0, 2.0))
        drone.angular_velocity = Vector3(_jitter(seed, 11, -9.0, 9.0), _jitter(seed, 12, -9.0, 9.0), _jitter(seed, 13, -9.0, 9.0))

func _drone_shape(scenario: String) -> Shape3D:
    if scenario == "tumble_ground":
        var box := BoxShape3D.new()
        box.size = Vector3(0.24, 0.08, 0.24)
        return box
    var sphere := SphereShape3D.new()
    sphere.radius = 0.1
    return sphere

func _add_shape(body: CollisionObject3D, shape: Shape3D) -> void:
    var collision_shape := CollisionShape3D.new()
    collision_shape.shape = shape
    body.add_child(collision_shape)

func _collision_row_finite(row: PackedFloat64Array) -> bool:
    if row.size() < 24:
        return false
    for index in [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23]:
        if not is_finite(row[index]):
            return false
    return true

func _apply_collision_row_to_body(body: Object, row: PackedFloat64Array) -> void:
    body.apply_native_state(
        Vector3(row[1], row[2], row[3]),
        Quaternion(row[4], row[5], row[6], row[7]),
        Vector3(row[8], row[9], row[10]),
        Vector3(row[14], row[15], row[16])
    )

func _sync_native_from_body(native: Object, body: RigidBody3D) -> void:
    var q := body.global_transform.basis.get_rotation_quaternion()
    native.call(
        "sync_flight_state",
        body.global_position.x,
        body.global_position.y,
        body.global_position.z,
        q.x,
        q.y,
        q.z,
        q.w,
        body.linear_velocity.x,
        body.linear_velocity.y,
        body.linear_velocity.z,
        body.angular_velocity.x,
        body.angular_velocity.y,
        body.angular_velocity.z
    )

func _row_impulse(row: PackedFloat64Array) -> Vector3:
    return Vector3(row[21], row[22], row[23])

func _row_normal(row: PackedFloat64Array) -> Vector3:
    return Vector3(row[18], row[19], row[20])

func _row_roll_degrees(row: PackedFloat64Array) -> float:
    return rad_to_deg(2.0 * atan2(float(row[6]), float(row[7])))

func _row_pitch_degrees(row: PackedFloat64Array) -> float:
    return rad_to_deg(2.0 * atan2(float(row[4]), float(row[7])))

func _body_state_finite(body: RigidBody3D) -> bool:
    var q := body.global_transform.basis.get_rotation_quaternion()
    return _vector_finite(body.global_position) and _vector_finite(body.linear_velocity) and _vector_finite(body.angular_velocity) and is_finite(q.x) and is_finite(q.y) and is_finite(q.z) and is_finite(q.w)

func _same_collision_row(a: PackedFloat64Array, b: PackedFloat64Array) -> bool:
    if a.size() != b.size():
        return false
    for index in range(a.size()):
        if index == 13:
            continue
        if abs(a[index] - b[index]) > 1e-6:
            return false
    return true

func _same_motor_debug_values(a: Array, b: Array) -> bool:
    if a.size() != b.size():
        return false
    for index in range(a.size()):
        var left: Dictionary = a[index]
        var right: Dictionary = b[index]
        if absf(float(left.thrust_newtons) - float(right.thrust_newtons)) > 1e-9:
            return false
        if absf(float(left.speed_rad_s) - float(right.speed_rad_s)) > 1e-9:
            return false
        if absf(float(left.current_a) - float(right.current_a)) > 1e-9:
            return false
        if bool(left.saturated) != bool(right.saturated):
            return false
    return true

func _kinetic(linear_velocity: Vector3, angular_velocity: Vector3, mass_kg: float) -> float:
    return 0.5 * mass_kg * linear_velocity.length_squared() + 0.5 * angular_velocity.length_squared()

func _vector_finite(value: Vector3) -> bool:
    return is_finite(value.x) and is_finite(value.y) and is_finite(value.z)

func _jitter(seed: int, salt: int, low: float, high: float) -> float:
    var unit := fposmod(sin(float(seed * 31 + salt * 17)) * 43758.5453123, 1.0)
    return low + (high - low) * unit

func _verify_runtime_actions() -> bool:
    var scene := SmokeScene.instantiate()
    root.add_child(scene)
    await process_frame
    if scene.native == null:
        push_error("Smoke runtime must instantiate AeroSimNative")
        scene.queue_free()
        return false
    if not scene.last_profile_status.contains("KeyboardProfile"):
        push_error("Smoke runtime must expose no-controller KeyboardProfile fallback UI")
        scene.queue_free()
        return false
    if scene.get_viewport().get_camera_3d() == null or scene.get_viewport().get_camera_3d().name != "ChaseCamera":
        push_error("Playable GUI smoke scene must have a current ChaseCamera Camera3D")
        scene.queue_free()
        return false
    if (scene.get_node_or_null("DroneBody/DroneMesh") as MeshInstance3D) == null:
        push_error("Playable GUI smoke scene must expose a visible drone mesh")
        scene.queue_free()
        return false
    if (scene.get_node_or_null("GroundPlane") as MeshInstance3D) == null and (scene.get_node_or_null("GridLineX") as MeshInstance3D) == null:
        push_error("Playable GUI smoke scene must expose a visible ground or grid reference")
        scene.queue_free()
        return false
    if scene.flight_hud_layer == null or scene.flight_hud_layer.visible:
        push_error("Cold-start main menu must not be covered by the flight HUD")
        scene.queue_free()
        return false
    if scene.arm_status_label == null or scene.arm_takeoff_button == null:
        push_error("Playable GUI smoke scene must expose an observable arm status and arm/takeoff control")
        scene.queue_free()
        return false
    if not scene.has_method("quick_fly"):
        push_error("Smoke runtime must expose Quick Fly from the cold-start main menu")
        scene.queue_free()
        return false
    if scene.main_menu_entries != ["Quick Fly", "Controller", "Drone", "Map", "Settings"]:
        push_error("Cold-start main menu must expose the fixed 3.5.4 first-layer entries")
        scene.queue_free()
        return false
    var quick_fly_button := scene.get_node_or_null("MainMenu/Entries/QuickFly") as Button
    if quick_fly_button == null or quick_fly_button.text != "Quick Fly":
        push_error("Cold-start main menu must expose an interactive Quick Fly button")
        scene.queue_free()
        return false
    await _press_key(KEY_T)
    await process_frame
    if scene.screen != "main_menu" or scene.takeoff_requested or scene.native.call("flight_control_armed"):
        push_error("flight_takeoff must not bypass the Quick Fly state machine from the main menu")
        scene.queue_free()
        return false
    quick_fly_button.pressed.emit()
    await process_frame
    if scene.screen != "fallback_prompt" or not scene.arm_status_label.text.contains("KeyboardProfile") or scene.arm_takeoff_button.text != "USE KEYBOARD FALLBACK":
        push_error("Quick Fly without a controller must show an actionable KeyboardProfile fallback prompt")
        scene.queue_free()
        return false
    scene.arm_takeoff_button.pressed.emit()
    await process_frame
    if scene.screen != "preflight" or scene.takeoff_requested or scene.native.call("flight_control_armed"):
        push_error("Keyboard fallback confirmation must enter the low-throttle preflight state before arming")
        scene.queue_free()
        return false
    if scene.key_hints_label == null or not scene.key_hints_label.is_visible_in_tree():
        push_error("Playable GUI smoke scene must expose visible key hints after Quick Fly")
        scene.queue_free()
        return false
    for hint in ["T", "P", "R", "H", "Esc"]:
        if not scene.key_hints_label.text.contains(hint):
            push_error("Playable GUI key hints must name %s" % hint)
            scene.queue_free()
            return false
    if not scene.arm_status_label.text.contains("Throttle LOW") or scene.arm_takeoff_button.disabled:
        push_error("Quick Fly preflight must make throttle-low arm/takeoff state observable")
        scene.queue_free()
        return false
    scene.quick_fly("uncalibrated")
    if scene.screen != "controller_setup" or not scene.arm_status_label.text.contains("Controller setup") or scene.arm_takeoff_button.text != "BACK TO MAIN MENU":
        push_error("Quick Fly with an uncalibrated controller must show an explicit Controller Setup screen")
        scene.queue_free()
        return false
    scene.arm_takeoff_button.pressed.emit()
    scene.quick_fly("drone_load_failed")
    if scene.screen != "error" or scene.last_error_message.is_empty() or not scene.arm_status_label.text.contains("drone_load_failed") or scene.arm_takeoff_button.text != "BACK TO MAIN MENU":
        push_error("Quick Fly load failures must show an explicit error screen")
        scene.queue_free()
        return false
    scene.arm_takeoff_button.pressed.emit()
    scene.quick_fly("no_controller")
    scene.arm_takeoff_button.pressed.emit()
    if scene.screen != "preflight" or scene.takeoff_requested:
        push_error("Quick Fly fallback must enter the low-throttle preflight state")
        scene.queue_free()
        return false

    var takeoff_position: Vector3 = scene.drone_body.global_position
    await _press_key(KEY_T)
    var moved_after_takeoff := false
    var climbed_after_takeoff := false
    for _frame in range(60):
        await physics_frame
        var takeoff_delta: Vector3 = scene.drone_body.global_position - takeoff_position
        moved_after_takeoff = moved_after_takeoff or takeoff_delta.length() > 0.05
        climbed_after_takeoff = climbed_after_takeoff or takeoff_delta.y > 0.02
    if not scene.takeoff_requested or not scene.native.call("flight_control_armed"):
        push_error("flight_takeoff action must request takeoff and arm through runtime")
        scene.queue_free()
        return false
    if scene.paused or scene.drone_body.freeze:
        push_error("flight_takeoff action must immediately unfreeze the playable drone")
        scene.queue_free()
        return false
    if not moved_after_takeoff or not climbed_after_takeoff or scene.drone_body.global_position.y < takeoff_position.y + 1.0:
        push_error("flight_takeoff action must keep the drone climbing without pressing pause")
        scene.queue_free()
        return false
    if not scene.arm_status_label.text.contains("ARMED"):
        push_error("flight_takeoff action must make armed state visible in the GUI")
        scene.queue_free()
        return false
    var runtime_mass := float(scene.native.call("hardware_power_diagnostics").get("mass_kg", 0.0))
    if absf(scene._kinetic(Vector3(10.0, 0.0, 0.0), Vector3.ZERO) - 0.5 * runtime_mass * 100.0) > 1e-9:
        push_error("flight runtime collision energy limit must use configured hardware mass")
        scene.queue_free()
        return false
    if scene.status_diagram == null:
        push_error("flight runtime must attach the status diagram debug CanvasLayer")
        scene.queue_free()
        return false
    var ui_values: Dictionary = scene.status_diagram.debug_values
    var native_snapshot: Dictionary = scene.native.call("telemetry_snapshot")
    if ui_values.is_empty() or int(ui_values.timestamp_us) != int(native_snapshot.timestamp_us) or str(ui_values.source) != "native_double_buffer":
        push_error("status diagram UI must render the latest native double-buffer telemetry snapshot")
        scene.queue_free()
        return false
    if not _same_motor_debug_values(ui_values.motors, native_snapshot.motors):
        push_error("status diagram motor values must match TelemetrySnapshot truth")
        scene.queue_free()
        return false
    var ui_battery: Dictionary = ui_values.battery
    var native_battery: Dictionary = native_snapshot.battery
    if float(ui_battery.sag_v) != float(native_battery.sag_v):
        push_error("status diagram battery sag must match TelemetrySnapshot truth")
        scene.queue_free()
        return false
    if not scene.fallback_status_label.text.contains("Mode: ANGLE"):
        push_error("flight runtime must show Angle mode on the existing status line")
        scene.queue_free()
        return false

    await _press_key(KEY_H)
    if scene.flight_mode != "ALTITUDE_HOLD" or not scene.fallback_status_label.text.contains("Mode: ALTITUDE_HOLD"):
        push_error("flight_altitude_hold action must switch the existing status line to Altitude Hold")
        scene.queue_free()
        return false
    await _press_key(KEY_H)
    if scene.flight_mode != "ANGLE" or not scene.fallback_status_label.text.contains("Mode: ANGLE"):
        push_error("flight_altitude_hold action must return the existing status line to Angle mode")
        scene.queue_free()
        return false

    scene.flight_mode = "ACRO"
    scene.update_fallback_status()
    scene.native.call("reset_flight")
    scene.native.call("set_collision_release_frames", 3)
    scene.native.call("arm_flight_control", 0.0)
    scene.drone_body.apply_native_state(Vector3(100.0, 100.0, 100.0), Quaternion.IDENTITY, Vector3(30.0, 0.0, 0.0), Vector3.ZERO)
    scene.drone_body.contact_seen = true
    scene.drone_body.contact_normal = Vector3.LEFT
    scene.drone_body.contact_impulse = Vector3.ZERO
    scene.acro_roll_stick = 1.0
    var acro_handoffs_before: int = scene.collision_handoff_count
    var acro_rate_observed := false
    for _frame in range(Engine.physics_ticks_per_second / 2):
        await physics_frame
        if absf(scene.drone_body.angular_velocity.z) > 1.0:
            acro_rate_observed = true
            break
    scene.acro_roll_stick = 0.0
    if scene.collision_handoff_count <= acro_handoffs_before:
        push_error("flight runtime ACRO path must feed DroneBody contact into native collision authority")
        scene.queue_free()
        return false
    if scene.last_collision_authority != 0 or not acro_rate_observed:
        push_error("flight runtime ACRO path must hand back and respond to rates input within 0.5 seconds; authority=%d angular_z=%f" % [scene.last_collision_authority, scene.drone_body.angular_velocity.z])
        scene.queue_free()
        return false
    scene.flight_mode = "ANGLE"
    scene.update_fallback_status()

    await _press_key(KEY_P)
    if not scene.paused:
        push_error("flight_pause action must pause runtime")
        scene.queue_free()
        return false
    var paused_position: Vector3 = scene.drone_body.global_position
    for _frame in range(5):
        await physics_frame
    if scene.drone_body.global_position.distance_to(paused_position) > 1e-6:
        push_error("flight_pause action must freeze runtime physics")
        scene.queue_free()
        return false
    await _press_key(KEY_R)
    if scene.reset_count != 1 or not scene.takeoff_requested or scene.paused:
        push_error("flight_respawn action must resume from pause and keep flight active")
        scene.queue_free()
        return false
    if scene.drone_body.position.distance_to(Vector3(-1.0, 0.0, 0.0)) > 1e-6 or scene.drone_body.linear_velocity.length() > 1e-6 or scene.drone_body.angular_velocity.length() > 1e-6:
        push_error("flight_respawn action must return to spawn and clear body velocity; position=%s linear=%s angular=%s" % [scene.drone_body.position, scene.drone_body.linear_velocity, scene.drone_body.angular_velocity])
        scene.queue_free()
        return false
    for _frame in range(31):
        await physics_frame
    if scene.drone_body.freeze or not scene.native.call("flight_control_armed"):
        push_error("flight_respawn action must release reset hold and re-arm after pausing")
        scene.queue_free()
        return false

    scene.quit_on_exit = false
    await _press_key(KEY_ESCAPE)
    if not scene.exit_requested or scene.screen != "exit":
        push_error("flight_exit action must request a GUI exit through the runtime exit hook")
        scene.queue_free()
        return false

    scene.queue_free()
    return true

func _verify_hardware_config_public_path() -> bool:
    var loader := HardwareConfig.new()
    var factory_default: Dictionary = loader.current
    var preset: Dictionary = loader.load_preset("res://config/drones/5_inch_6s.json")
    if not loader.last_ok:
        push_error("5 inch hardware preset must load: %s" % loader.last_error)
        return false
    var race_preset: Dictionary = loader.load_preset("res://config/drones/5_inch_6s_race.json")
    if not loader.last_ok or race_preset.version == preset.version:
        push_error("5 inch race hardware preset must load as a distinct built-in preset")
        return false
    for key in ["frame", "motor", "propeller", "battery", "esc", "aircraft", "sensors", "fpv"]:
        if not preset.has(key):
            push_error("5 inch hardware preset missing 3.6.1 category: %s" % key)
            return false
    for key in ["version", "units", "coordinate_frame", "motor_order", "spin_direction", "prop_table_interpolation"]:
        if not preset.has(key):
            push_error("5 inch hardware preset missing required metadata: %s" % key)
            return false
    if loader.prop_sample_at_rpm(preset, 1000.0).ok:
        push_error("Prop table must reject rpm requests below the measured table")
        return false
    if loader.prop_sample_at_rpm(preset, 20000.0).ok:
        push_error("Prop table must reject rpm requests above the measured table")
        return false
    var prop_mid: Dictionary = loader.prop_sample_at_rpm(preset, 10000.0)
    if not prop_mid.ok or abs(float(prop_mid.thrust_n) - 7.2) > 1e-9:
        push_error("Prop table must linearly interpolate in-range thrust")
        return false
    var power_model: Dictionary = loader.derive_power_model(preset)
    if not power_model.ok:
        push_error("Hardware preset must derive a motor/battery power model: %s" % power_model.get("error", "unknown"))
        return false
    if float(power_model.max_fit_residual_pct) > 3.0:
        push_error("k_t/k_q least-squares residual must stay within 3%% at bench RPM points")
        return false
    var hover_torque_per_motor := float(power_model.k_q_nm_per_rpm2) * float(power_model.hover_rpm) * float(power_model.hover_rpm)
    if hover_torque_per_motor <= 0.0 or abs(float(power_model.net_hover_yaw_torque_nm)) > hover_torque_per_motor * 0.02:
        push_error("Counter-rotating motor order must cancel hover yaw torque within 2%%")
        return false
    if float(power_model.hover_throttle) < 0.22 or float(power_model.hover_throttle) > 0.35:
        push_error("5 inch 6S preset hover throttle must be 22-35%%")
        return false
    if float(power_model.twr) < 8.0:
        push_error("5 inch 6S preset thrust-to-weight ratio must be at least 8")
        return false
    if float(power_model.hover_endurance_minutes) < 3.0 or float(power_model.hover_endurance_minutes) > 6.0:
        push_error("5 inch 6S preset hover endurance must be 3-6 minutes")
        return false
    if float(power_model.sag_model_r2) < 0.99:
        push_error("Battery sag model fit must have R^2 >= 0.99")
        return false
    var previous_loaded_voltage := INF
    for sag_row in power_model.sag_curve:
        if float(sag_row.loaded_voltage_v) >= previous_loaded_voltage:
            push_error("Battery sag loaded voltage must fall as remaining charge falls")
            return false
        previous_loaded_voltage = float(sag_row.loaded_voltage_v)
    if not _hardware_schema_rejects(loader, preset, "units.mass", "lb"):
        push_error("Hardware schema must reject unexpected units")
        return false
    if not _hardware_schema_rejects(loader, preset, "coordinate_frame.body", "NED"):
        push_error("Hardware schema must reject unexpected coordinate frames")
        return false
    if not _hardware_schema_rejects(loader, preset, "motor_order", ["front_right", "rear_right", "rear_left", "front_left"]):
        push_error("Hardware schema must reject unexpected motor order")
        return false
    if not _hardware_schema_rejects(loader, preset, "spin_direction", ["left", "right", "left", "right"]):
        push_error("Hardware schema must reject unexpected spin direction")
        return false
    var schema_doc := _hardware_schema_doc()
    for spec_value in schema_doc.numeric_ranges:
        var spec: Dictionary = spec_value
        if not _hardware_schema_rejects(loader, preset, spec.path, float(spec.max) + 1.0):
            push_error("Hardware schema must reject out-of-range value at %s" % spec.path)
            return false
        if not _hardware_schema_rejects(loader, preset, spec.path, float(spec.min) - 1.0):
            push_error("Hardware schema must reject out-of-range value at %s" % spec.path)
            return false
    var bad_prop := preset.duplicate(true)
    bad_prop.propeller.table[0].current_a = -1.0
    if loader.validate_config(bad_prop) == "":
        push_error("Hardware schema must reject out-of-range propeller table rows")
        return false
    var bad_curve := preset.duplicate(true)
    bad_curve.battery.discharge_curve[0].remaining = 2.0
    if loader.validate_config(bad_curve) == "":
        push_error("Hardware schema must reject out-of-range battery discharge rows")
        return false
    bad_curve = preset.duplicate(true)
    bad_curve.battery.discharge_curve[0].voltage_v = 1000.0
    if loader.validate_config(bad_curve) == "":
        push_error("Hardware schema must reject impossible battery discharge voltage")
        return false
    bad_curve = preset.duplicate(true)
    bad_curve.battery.discharge_curve[0].voltage_v = "25.2"
    if loader.validate_config(bad_curve) == "":
        push_error("Hardware schema must reject non-numeric battery discharge voltage")
        return false
    var bad_layout := preset.duplicate(true)
    bad_layout.aircraft.motor_layout[0].x = 2.0
    if loader.validate_config(bad_layout) == "":
        push_error("Hardware schema must reject out-of-range motor layout rows")
        return false
    if loader.load_preset("res://config/drones/invalid_out_of_range.json") != factory_default or loader.last_ok:
        push_error("Out-of-range hardware JSON load must fail loud and fall back to factory default")
        return false

    var scene := SmokeScene.instantiate()
    root.add_child(scene)
    await process_frame
    if scene.get_meta("hardware_config_version", "") != preset.version:
        push_error("Runtime must apply the built-in 5 inch hardware preset on startup")
        scene.queue_free()
        return false
    if not scene.native.has_method("hardware_power_diagnostics"):
        push_error("AeroSimNative must expose hardware power diagnostics for runtime preset verification")
        scene.queue_free()
        return false
    var startup_power: Dictionary = scene.native.call("hardware_power_diagnostics")
    if abs(float(startup_power.mass_kg) - float(preset.aircraft.mass_kg)) > 1e-9:
        push_error("Runtime startup preset must apply aircraft mass to native")
        scene.queue_free()
        return false
    if abs(float(startup_power.hover_throttle) - float(power_model.hover_throttle)) > 1e-9:
        push_error("Runtime startup preset must apply derived hover throttle to native")
        scene.queue_free()
        return false
    if float(startup_power.full_throttle_cap_newtons) >= float(power_model.max_total_thrust_n):
        push_error("Runtime startup preset must apply battery sag to the native thrust cap")
        scene.queue_free()
        return false
    var native_before: Object = scene.native
    var reset_count_before: int = scene.reset_count
    if not loader.apply_to_runtime(scene, "res://config/drones/5_inch_6s.json"):
        push_error("Runtime must hot-switch the built-in 5 inch hardware preset")
        scene.queue_free()
        return false
    if scene.native != native_before or scene.reset_count != reset_count_before or scene.get_meta("hardware_config_version", "") != preset.version:
        push_error("Runtime hardware preset hot-switch must not reload scene/native state")
        scene.queue_free()
        return false
    if not _native_hovers_at_mass(scene.native, float(preset.aircraft.mass_kg)):
        push_error("Runtime hardware preset mass must affect native simulation")
        scene.queue_free()
        return false
    if loader.apply_to_runtime(scene, "res://config/drones/invalid_out_of_range.json"):
        push_error("Invalid runtime hardware preset must report failure")
        scene.queue_free()
        return false
    if scene.get_meta("hardware_config_version", "") != factory_default.version:
        push_error("Invalid runtime hardware preset must mark factory-default fallback")
        scene.queue_free()
        return false
    if not _native_hovers_at_mass(scene.native, float(factory_default.aircraft.mass_kg)):
        push_error("Invalid runtime hardware preset must apply factory-default mass to native")
        scene.queue_free()
        return false
    scene.queue_free()
    return true

func _hardware_schema_doc() -> Dictionary:
    var file := FileAccess.open("res://config/drone_schema.json", FileAccess.READ)
    if file == null:
        return {}
    var json := JSON.new()
    if json.parse(file.get_as_text()) != OK or not (json.data is Dictionary):
        return {}
    return json.data

func _hardware_schema_rejects(loader: RefCounted, base: Dictionary, path: String, value: Variant) -> bool:
    var mutated := base.duplicate(true)
    _set_hardware_path(mutated, path, value)
    return loader.validate_config(mutated) != ""

func _set_hardware_path(config: Dictionary, path: String, value: Variant) -> void:
    var parts := path.split(".")
    var cursor: Dictionary = config
    for index in range(parts.size() - 1):
        cursor = cursor[parts[index]]
    cursor[parts[parts.size() - 1]] = value

func _native_hovers_at_mass(native: Object, mass_kg: float) -> bool:
    native.call("reset_flight")
    native.call("arm_flight_control", 0.0)
    var hover: PackedFloat64Array = native.call(
        "simulate_trajectory",
        1.0,
        Engine.physics_ticks_per_second,
        1000,
        mass_kg * 9.80665
    )
    return not hover.is_empty() and abs(float(hover[hover.size() - int(native.call("trajectory_stride")) + 2])) <= 1e-6

func _press_key(keycode: int) -> void:
    var event := InputEventKey.new()
    event.keycode = keycode
    event.physical_keycode = keycode
    event.pressed = true
    Input.parse_input_event(event)
    await process_frame
    event = InputEventKey.new()
    event.keycode = keycode
    event.physical_keycode = keycode
    event.pressed = false
    Input.parse_input_event(event)
    await process_frame

func _verify_keyboard_profile_actions() -> bool:
    var actions := {
        "flight_takeoff": KEY_T,
        "flight_pause": KEY_P,
        "flight_respawn": KEY_R,
        "flight_altitude_hold": KEY_H,
        "flight_exit": KEY_ESCAPE
    }
    for action in actions:
        if not InputMap.has_action(action):
            push_error("KeyboardProfile missing InputMap action: %s" % action)
            return false

        var probe := InputProbe.new()
        probe.action = action
        probe.set_process_input(true)
        root.add_child(probe)
        await process_frame

        var event := InputEventKey.new()
        event.keycode = actions[action]
        event.physical_keycode = actions[action]
        event.pressed = true
        Input.parse_input_event(event)
        await process_frame
        if not probe.pressed:
            push_error("KeyboardProfile action did not trigger via Input.parse_input_event: %s" % action)
            probe.queue_free()
            return false

        event = InputEventKey.new()
        event.keycode = actions[action]
        event.physical_keycode = actions[action]
        event.pressed = false
        Input.parse_input_event(event)
        await process_frame
        probe.queue_free()
    return true

func _verify_gamepad_profile_actions() -> bool:
    var profile := InputProfiles.GamepadProfile.new()
    profile.apply_throttle_axis(0.7)
    profile.apply_throttle_axis(0.0)
    if not is_equal_approx(profile.throttle, 0.7):
        push_error("GamepadProfile throttle must be sticky when the stick returns to center")
        return false

    profile.apply_throttle_axis(0.02)
    if not is_equal_approx(profile.throttle, 0.7):
        push_error("GamepadProfile throttle deadzone must ignore small drift")
        return false

    var actions := {
        "flight_takeoff": JOY_BUTTON_A,
        "flight_pause": JOY_BUTTON_START,
        "flight_respawn": JOY_BUTTON_X,
        "flight_altitude_hold": JOY_BUTTON_Y,
        "flight_exit": JOY_BUTTON_B
    }
    for action in actions:
        if not InputMap.has_action(action):
            push_error("GamepadProfile missing InputMap action: %s" % action)
            return false

        var has_joypad_button := false
        for mapped_event in InputMap.action_get_events(action):
            if mapped_event is InputEventJoypadButton:
                has_joypad_button = true
                break
        if not has_joypad_button:
            push_error("GamepadProfile action lacks joypad binding: %s" % action)
            return false

        var probe := InputProbe.new()
        probe.action = action
        probe.set_process_input(true)
        root.add_child(probe)
        await process_frame

        var event := InputEventJoypadButton.new()
        event.button_index = actions[action]
        event.pressed = true
        Input.parse_input_event(event)
        await process_frame
        if not probe.pressed:
            push_error("GamepadProfile action did not trigger via Input.parse_input_event: %s" % action)
            probe.queue_free()
            return false

        event = InputEventJoypadButton.new()
        event.button_index = actions[action]
        event.pressed = false
        Input.parse_input_event(event)
        await process_frame
        probe.queue_free()
    return true

func _output_path() -> String:
    var args := OS.get_cmdline_user_args()
    for index in range(args.size() - 1):
        if args[index] == "--output":
            return _project_path(args[index + 1])
    return _project_path("build/headless_smoke.json")

func _csv_output_path() -> String:
    var args := OS.get_cmdline_user_args()
    for index in range(args.size() - 1):
        if args[index] == "--csv-output":
            return _project_path(args[index + 1])
    return _project_path("build/headless_trajectory.csv")

func _requested_frames() -> int:
    var frames := _int_arg("--frames", 3)
    var seconds := _float_arg("--seconds", 0.0)
    if seconds > 0.0:
        frames = ceili(seconds * float(Engine.physics_ticks_per_second))
    return maxi(frames, 1)

func _requested_seconds(requested_frames: int) -> float:
    var seconds := _float_arg("--seconds", 0.0)
    if seconds > 0.0:
        return seconds
    return float(requested_frames) / float(Engine.physics_ticks_per_second)

func _write_trajectory_csv(path: String, trajectory: PackedFloat64Array, stride: int) -> bool:
    var file := FileAccess.open(path, FileAccess.WRITE)
    if file == null:
        push_error("Cannot write trajectory CSV: %s" % path)
        return false

    file.store_line("time_s,position_x_m,position_y_m,position_z_m,orientation_x,orientation_y,orientation_z,orientation_w,velocity_x_mps,velocity_y_mps,velocity_z_mps,substeps")
    for row in range(int(trajectory.size() / stride)):
        var offset := row * stride
        var values: Array[String] = []
        for column in range(stride):
            values.append("%.10f" % trajectory[offset + column])
        file.store_line(",".join(values))
    return true

func _int_arg(name: String, default_value: int) -> int:
    var args := OS.get_cmdline_user_args()
    for index in range(args.size() - 1):
        if args[index] == name:
            return args[index + 1].to_int()
    return default_value

func _float_arg(name: String, default_value: float) -> float:
    var args := OS.get_cmdline_user_args()
    for index in range(args.size() - 1):
        if args[index] == name:
            return args[index + 1].to_float()
    return default_value

func _has_arg(name: String) -> bool:
    return OS.get_cmdline_user_args().has(name)

func _project_path(path: String) -> String:
    if path.is_absolute_path():
        return path
    return ProjectSettings.globalize_path("res://").path_join(path)
