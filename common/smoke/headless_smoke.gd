extends SceneTree

const InputProfiles = preload("res://common/flight/input_profiles.gd")
const AirSimCoordinateContract = preload("res://common/rpc/airsim_coordinate_contract.gd")
const GamepadDeviceState = preload("res://common/flight/gamepad_device_state.gd")
const CollisionProbeBodyScript = preload("res://common/flight/collision_probe_body.gd")
const HardwareConfig = preload("res://common/flight/hardware_config.gd")
const FreeFlightMap = preload("res://common/maps/free_flight_map.gd")
const IndustrialYardScene = preload("res://levels/free_flight/industrial_yard.tscn")
const SmokeScene = preload("res://levels/smoke/smoke.tscn")
const FlightRuntime = preload("res://common/flight/flight_runtime.gd")
const LicenseProviderScript = preload("res://common/license/license_provider.gd")
const DEFAULT_HARDWARE_PRESET := "res://config/drones/5_inch_6s.json"

class InputProbe:
    extends Node

    var action := ""
    var pressed := false

    func _input(event: InputEvent) -> void:
        if event.is_action_pressed(action):
            pressed = true

class ButtonClock:
    extends RefCounted

    var milliseconds := 0

    func now_ms() -> int:
        return milliseconds

class MutableGamepadDeviceState:
    extends GamepadDeviceState.DeviceState

    var snapshot: Array[int] = []
    var known_device_ids: Dictionary = {}

    func replace_snapshot(device_ids: Array[int], known_ids: Array[int]) -> void:
        snapshot = device_ids.duplicate()
        known_device_ids.clear()
        for device_id in known_ids:
            known_device_ids[device_id] = true

    func connected_joypads() -> Array[int]:
        return snapshot.duplicate()

    func is_joy_known(device_id: int) -> bool:
        return bool(known_device_ids.get(device_id, false))

    func joy_name(device_id: int) -> String:
        return "Xbox Test Controller %d" % device_id

class SmokeLicenseProvider:
    extends Node

    func get_snapshot() -> Dictionary:
        return {"ok": true, "status": "online_valid", "last_online_result": "smoke"}

var verified_jolt_collision_trials := 0
var production_gamepad_device_state := GamepadDeviceState.DeviceState.new()

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
    if not _verify_industrial_yard_descriptor_and_scene():
        quit(1)
        return
    # Gamepad event injection registers a virtual controller for this process.
    # Verify the deterministic no-controller path before exercising those bindings.
    var input_fallback_status := _input_fallback_status([])
    if not input_fallback_status.contains("KeyboardProfile") or not input_fallback_status.contains("non-sim"):
        push_error("No-controller fallback status must explicitly name KeyboardProfile and non-sim control")
        quit(1)
        return
    var gamepad_profile_status := _input_fallback_status([0])
    if not gamepad_profile_status.contains("GamepadProfile") or not gamepad_profile_status.contains("non-sim"):
        push_error("Connected gamepad status must explicitly name GamepadProfile and non-sim control")
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
    if not _verify_xbox_default_profile():
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
    if not _verify_px4_actuator_public_path(native):
        quit(1)
        return
    var jolt_collision_verified := await _verify_jolt_collision_scene(native)
    if not jolt_collision_verified:
        quit(1)
        return
    if not await _verify_runtime_actions():
        quit(1)
        return
    if not await _verify_gamepad_profile_actions():
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

    var mobile_trajectory_result: Variant = native.call("simulate_trajectory", 1.0, 120, 500, 0.0)
    var stride: int = native.call("trajectory_stride")
    if not (mobile_trajectory_result is Dictionary):
        push_error("AeroSimNative.simulate_trajectory returned a non-Dictionary result")
        quit(1)
        return
    var mobile_status := String(mobile_trajectory_result.get("status", "missing_status"))
    var mobile_failed_frame := int(mobile_trajectory_result.get("failed_frame", -1))
    var mobile_trajectory: PackedFloat64Array = mobile_trajectory_result.get("rows", PackedFloat64Array())

    var zero_trajectory_result: Dictionary = native.call("simulate_trajectory", 0.0, 120, 500, 0.0)
    var zero_rows: PackedFloat64Array = zero_trajectory_result.get("rows", PackedFloat64Array())
    var limited_trajectory_result: Dictionary = native.call("simulate_trajectory", 1000000.0, 120, 500, 0.0)
    var limited_rows: PackedFloat64Array = limited_trajectory_result.get("rows", PackedFloat64Array())

    if String(zero_trajectory_result.get("status", "")) != "Ok" or not zero_rows.is_empty() \
            or int(zero_trajectory_result.get("failed_frame", 0)) != -1 \
            or String(limited_trajectory_result.get("status", "")) != "ResourceLimitExceeded" \
            or not limited_rows.is_empty() or int(limited_trajectory_result.get("failed_frame", 0)) != -1:
        push_error("AeroSimNative.simulate_trajectory violated its StepStatus contract")
        quit(1)
        return

    if mobile_status != "Ok" or trajectory.is_empty() or mobile_trajectory.is_empty() or stride != 12 or mobile_trajectory.size() % stride != 0:
        push_error("AeroSimNative.simulate_trajectory failed: status=%s failed_frame=%d" % [mobile_status, mobile_failed_frame])
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
        "completed": true,
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

func _input_fallback_status(connected_joypads: Array) -> String:
    return InputProfiles.fallback_status(connected_joypads)

func _verify_industrial_yard_descriptor_and_scene() -> bool:
    var maps := FreeFlightMap.new()
    var descriptor: Dictionary = maps.load_descriptor("industrial_yard")
    if not maps.last_ok:
        push_error("Industrial Yard descriptor must load: %s" % maps.last_error)
        return false
    var expected_fields := {
        "id": "industrial_yard",
        "name": "Industrial Yard",
        "type": "free_flight",
        "recommended_aircraft": "5_inch_6s",
        "wind_preset": "calm",
        "spawn_count": 2,
        "spawns": [{"name": "SpawnNorth"}, {"name": "SpawnSouth"}],
        "mode": "free_flight"
    }
    for field in expected_fields:
        if descriptor.get(field) != expected_fields[field]:
            push_error("Industrial Yard descriptor field %s must be %s" % [field, str(expected_fields[field])])
            return false
    for field in expected_fields:
        var missing_field := descriptor.duplicate(true)
        missing_field.erase(field)
        if maps.validate_descriptor(missing_field) == "":
            push_error("Industrial Yard descriptor validation must reject missing %s" % field)
            return false

    var scene := IndustrialYardScene.instantiate()
    var named_nodes := {
        "SpawnNorth": Marker3D,
        "SpawnSouth": Marker3D,
        "Ground": MeshInstance3D,
        "CargoContainers": Node3D,
        "LowGate": StaticBody3D,
        "TurnMarker": StaticBody3D,
        "Tower": StaticBody3D
    }
    for node_name in named_nodes:
        if not is_instance_of(scene.get_node_or_null(node_name), named_nodes[node_name]):
            push_error("Industrial Yard scene must expose %s" % node_name)
            scene.queue_free()
            return false
    var north_spawn := scene.get_node_or_null("SpawnNorth") as Marker3D
    var south_spawn := scene.get_node_or_null("SpawnSouth") as Marker3D
    if north_spawn.position.distance_to(south_spawn.position) < 1.0:
        push_error("Industrial Yard formal spawn markers must be distinct")
        scene.queue_free()
        return false
    var cargo_containers := scene.get_node_or_null("CargoContainers")
    if cargo_containers.get_child_count() < 2:
        push_error("Industrial Yard scene must expose at least two cargo containers")
        scene.queue_free()
        return false
    var time_trial := scene.get_node_or_null("TimeTrial")
    if not is_instance_of(time_trial, Node3D) or time_trial.get_node_or_null("Finish") == null:
        push_error("Industrial Yard scene must expose a TimeTrial route and Finish marker")
        scene.queue_free()
        return false
    for checkpoint_name in ["Checkpoint01", "Checkpoint02", "Checkpoint03"]:
        var checkpoint := time_trial.get_node_or_null(checkpoint_name) as Marker3D
        if checkpoint == null or checkpoint.get_node_or_null("DirectionArrow") == null:
            push_error("Industrial Yard TimeTrial must expose %s with a direction arrow" % checkpoint_name)
            scene.queue_free()
            return false
    var static_bodies := scene.find_children("*", "StaticBody3D", true, false)
    if static_bodies.is_empty():
        push_error("Industrial Yard scene must expose StaticBody3D collision")
        scene.queue_free()
        return false
    for body in static_bodies:
        if body.find_children("*", "CollisionShape3D", true, false).is_empty():
            push_error("Industrial Yard StaticBody3D %s must have a CollisionShape3D" % body.name)
            scene.queue_free()
            return false
    scene.queue_free()
    return true

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
    var per_motor_model: Dictionary = loader.derive_per_motor_model(preset, power_model)
    if not per_motor_model.ok:
        push_error("Default hardware preset must derive native public-path per-motor model: %s" % per_motor_model.get("error", "unknown"))
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
    if not native.has_method("set_hardware_per_motor_model") or not native.call("set_hardware_per_motor_model", per_motor_model):
        push_error("Default hardware preset must apply native per-motor model")
        return false
    if native.has_method("set_hardware_telemetry_model") and not native.call(
            "set_hardware_telemetry_model",
            float(power_model.max_motor_rpm),
            float(power_model.battery_remaining_mah)
        ):
        push_error("Default hardware preset must apply native telemetry metadata")
        return false
    if not native.has_method("set_hardware_altitude_hold_noise_deadband") or not native.call(
            "set_hardware_altitude_hold_noise_deadband", float(preset.sensors.barometer_noise_m)):
        push_error("Default hardware preset must apply native altitude-hold noise tuning")
        return false
    if native.has_method("set_config_hash") and native.has_method("replay_vehicle_config_manifest") and native.has_method("replay_manifest_hash"):
        var canonicalizer := FlightRuntime.new()
        var config_json: String = canonicalizer._replay_canonical_json(native.call("replay_vehicle_config_manifest"))
        var config_hash := String(native.call("replay_manifest_hash", config_json))
        canonicalizer.free()
        if config_hash.is_empty() or not native.call("set_config_hash", config_hash):
            push_error("Default hardware preset must publish a canonical config hash")
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
    if not native.has_method("step_acro_mode") or not native.has_method("betaflight_rate_for_stick"):
        push_error("AeroSimNative.step_acro_mode must exist for Acro/rates public path")
        return false

    var preview_stick := float(native.call("betaflight_stick_for_rate", 360.0, 1.0, 0.722222222222, 0.0))
    var preview_rate := float(native.call("betaflight_rate_for_stick", preview_stick, 1.0, 0.722222222222, 0.0))
    if absf(preview_rate - 360.0) > 0.5:
        push_error("Betaflight public forward/inverse rates bindings must round-trip")
        return false
    if (
            float(native.call("betaflight_rate_for_stick", 0.5, 3.1, 0.7, 0.0)) != 0.0 or
            float(native.call("betaflight_rate_for_stick", 0.5, 1.0, 1.1, 0.0)) != 0.0 or
            float(native.call("betaflight_rate_for_stick", 0.5, 1.0, 0.7, 1.1)) != 0.0 or
            float(native.call("betaflight_rate_for_stick", NAN, 1.0, 0.7, 0.0)) != 0.0
        ):
        push_error("Betaflight public forward rates binding must reject out-of-range profiles")
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
    if native.call("step_simulation", 0, 1000, 0.0).size() != 0 or native.call("step_simulation", 240, 0, 0.0).size() != 0:
        push_error("Public step_simulation must reject non-positive simulation rates")
        return false
    if native.call("step_angle_mode", 0, 1000, 0.0, 0.0, 0.0, 0.0).size() != 0 or native.call("step_acro_mode", 240, 0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.7, 0.0).size() != 0:
        push_error("Public flight-control paths must reject non-positive simulation rates")
        return false
    if native.call("step_altitude_hold_mode", 0, 1000, 0.0, 0.0, 0.0, 0.0).size() != 0 or native.call("step_px4_actuator_mode", 240, 0, 0.0, 0.0, 0.0, 0.0).size() != 0:
        push_error("Public altitude-hold and PX4 paths must reject non-positive simulation rates")
        return false

    native.call("reset_flight")
    if not native.call("arm_flight_control", 0.0):
        push_error("Low throttle should arm flight control through Godot public path")
        return false
    var armed_row: PackedFloat64Array = native.call("step_angle_mode", Engine.physics_ticks_per_second, 1000, 0.75, 0.0, 0.0, 0.0)
    if armed_row[2] <= disarmed_row[2]:
        push_error("Armed Angle Mode throttle should produce lift")
        return false

    native.call("step_acro_mode", Engine.physics_ticks_per_second, 1000, 0.5, 0.0, 0.0, 0.0, 1.0, 0.722222222222, 0.0)
    native.call("disarm_flight_control")
    if native.call("flight_control_armed"):
        push_error("Disarm must clear native flight-control armed state immediately")
        return false
    var disarmed_diagnostics: Dictionary = native.call("flight_control_diagnostics")
    var disarmed_snapshot: Dictionary = native.call("telemetry_snapshot")
    var disarmed_motors: Array = disarmed_snapshot.get("motors", [])
    if (
            float(disarmed_diagnostics.get("motor_thrust_newtons", 1.0)) != 0.0 or
            bool(disarmed_snapshot.get("armed", true)) or
            String(disarmed_diagnostics.get("flight_mode", "")) != "ANGLE" or
            bool(disarmed_diagnostics.get("uses_estimated_attitude", true)) or
            String(disarmed_snapshot.get("mode", "")) != "ANGLE" or
            disarmed_motors.size() != 4
        ):
        push_error("Disarm must clear native diagnostics, mode metadata, and telemetry immediately")
        return false
    for motor_value in disarmed_motors:
        if (
                float(motor_value.get("thrust_newtons", 1.0)) != 0.0 or
                float(motor_value.get("speed_rad_s", 1.0)) != 0.0 or
                float(motor_value.get("current_a", 1.0)) != 0.0
            ):
            push_error("Disarm must clear telemetry motor state immediately")
            return false

    native.call("reset_flight")
    if not native.call("arm_flight_control", 0.0):
        push_error("Native flight control must re-arm after immediate disarm cleanup")
        return false
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
    for _frame in range(Engine.physics_ticks_per_second / 2):
        native.call("step_acro_mode", Engine.physics_ticks_per_second, 1000, 0.5, 1.0, 0.0, 0.0, 1.0, 0.722222222222, 0.0)
    var acro: Dictionary = native.call("flight_control_diagnostics")
    var roll_rate_dps := rad_to_deg(float(acro.get("angular_velocity_x_rad_s", 0.0)))
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
        "vehicle_id",
        "world_frame",
        "body_frame",
        "units",
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
        "air_density_kg_m3",
        "airspeed_body_frd_mps_mean",
        "body_drag_force_body_frd_n_mean",
        "body_drag_torque_body_frd_nm_mean",
        "a3_drag_force_body_frd_n_mean",
        "a6_angular_accel_body_frd_rad_s2",
        "body_drag_operating_state",
        "body_drag_evidence_state",
        "body_drag_reason_code",
        "a3_operating_state",
        "a6_operating_state",
        "config_hash",
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
    if int(snapshot.schema_version) != 2 or str(snapshot.coordinate_frame) != "FRD" or str(snapshot.world_frame) != "NED" or str(snapshot.body_frame) != "FRD" or str(snapshot.units) != "SI" or str(snapshot.source) != "native_double_buffer":
        push_error("TelemetrySnapshot must expose v2 SI NED/FRD frames and native double-buffer source")
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
    if str(snapshot.body_drag_operating_state) != "disabled" or str(snapshot.body_drag_evidence_state) != "provisional" or \
            str(snapshot.body_drag_reason_code) != "disabled" or snapshot.body_drag_force_body_frd_n_mean != Vector3.ZERO or \
            snapshot.body_drag_torque_body_frd_nm_mean != Vector3.ZERO:
        push_error("TelemetrySnapshot disabled body drag must be explicit and exactly zero")
        return false
    if str(snapshot.config_hash).is_empty() or str(snapshot.config_hash) == "unavailable":
        push_error("TelemetrySnapshot must expose a config hash")
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

    if not native.call("set_a3_drag_model", false, 0.0001, 0.0001, 0.00012):
        push_error("A3 drag public path must accept a disabled valid configuration")
        return false
    var disabled: Dictionary = native.call("a3_drag_configuration")
    if bool(disabled.get("enabled", true)) != false:
        push_error("A3 drag configuration must echo the disabled switch")
        return false

    native.call("reset_simulation")
    native.call("sync_flight_state", 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0, 10.0, 0.0, 0.0, 0.0, 0.0, 0.0)
    var off_row: PackedFloat64Array = native.call("step_px4_actuator_mode", Engine.physics_ticks_per_second, 1000, 0.5, 0.5, 0.5, 0.5)
    if absf(float(off_row[8]) - 10.0) > 1e-9:
        push_error("A3 disabled must not decelerate the public coasting path")
        return false

    if not native.call("set_a3_drag_model", true, 0.0001, 0.0001, 0.00012):
        push_error("A3 drag public path must accept an enabled valid configuration")
        return false
    var enabled: Dictionary = native.call("a3_drag_configuration")
    if bool(enabled.get("enabled", false)) != true:
        push_error("A3 drag configuration must echo the enabled switch")
        return false

    native.call("reset_simulation")
    native.call("sync_flight_state", 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0, 10.0, 0.0, 0.0, 0.0, 0.0, 0.0)
    var on_row: PackedFloat64Array = native.call("step_px4_actuator_mode", Engine.physics_ticks_per_second, 1000, 0.5, 0.5, 0.5, 0.5)
    if float(on_row[8]) >= float(off_row[8]):
        push_error("A3 enabled must decelerate the public path using live motor state")
        return false

    native.call("configure_wind", {"preset": "calm", "steady_wind": Vector3.ZERO})
    native.call("reset_simulation")
    native.call("sync_flight_state", 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0, 10.0, 0.0, 0.0, 0.0, 0.0, 0.0)
    var still_air_row: PackedFloat64Array = native.call("step_px4_actuator_mode", Engine.physics_ticks_per_second, 1000, 0.5, 0.5, 0.5, 0.5)
    native.call("configure_wind", {"preset": "calm", "steady_wind": Vector3(10.0, 0.0, 0.0)})
    native.call("reset_simulation")
    native.call("sync_flight_state", 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0, 10.0, 0.0, 0.0, 0.0, 0.0, 0.0)
    var matching_wind_row: PackedFloat64Array = native.call("step_px4_actuator_mode", Engine.physics_ticks_per_second, 1000, 0.5, 0.5, 0.5, 0.5)
    if float(matching_wind_row[8]) <= float(still_air_row[8]):
        push_error("PX4 actuator mode must apply wind to relative airspeed")
        return false
    native.call("configure_wind", {"preset": "calm", "steady_wind": Vector3.ZERO})

    native.call("disarm_flight_control")
    native.call("reset_simulation")
    native.call("sync_flight_state", 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0, 10.0, 0.0, 0.0, 0.0, 0.0, 0.0)
    var px4_external_row: PackedFloat64Array = native.call("step_px4_actuator_mode", Engine.physics_ticks_per_second, 1000, 0.5, 0.5, 0.5, 0.5)
    if float(px4_external_row[8]) >= 10.0:
        push_error("PX4 actuator mode must use PX4 external arming authority after local disarm")
        return false
    if not native.call("arm_flight_control", 0.0):
        push_error("Native flight control must re-arm before aggregate A3 path verification")
        return false

    native.call("set_a3_drag_model", false, 0.0001, 0.0001, 0.00012)
    native.call("reset_simulation")
    native.call("sync_flight_state", 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0, 10.0, 0.0, 0.0, 0.0, 0.0, 0.0)
    var aggregate_off_row: PackedFloat64Array = native.call("step_simulation", Engine.physics_ticks_per_second, 1000, 10.0)
    native.call("set_a3_drag_model", true, 0.0001, 0.0001, 0.00012)
    native.call("reset_simulation")
    native.call("sync_flight_state", 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0, 10.0, 0.0, 0.0, 0.0, 0.0, 0.0)
    var aggregate_on_row: PackedFloat64Array = native.call("step_simulation", Engine.physics_ticks_per_second, 1000, 10.0)
    if float(aggregate_on_row[8]) >= float(aggregate_off_row[8]):
        push_error("A3 enabled aggregate thrust path must decelerate using live motor state")
        return false
    return true

func _verify_a4_a5_public_path(native: Object) -> bool:
    for method in ["set_a4_ground_effect_model", "a4_ground_effect_configuration", "set_a5_downwash_model", "a5_downwash_configuration", "a5_downwash_force_y", "set_a5_downwash_source_position", "set_a6_propwash_model", "a6_propwash_configuration", "set_dual_aircraft_positions", "step_dual_aircraft_simulation", "sync_flight_state"]:
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
    if native.call("set_a5_downwash_model", false, INF, 2267.18, 0.16, -0.11) or native.call("set_a5_downwash_model", false, prop_radius, INF, 0.16, -0.11):
        push_error("A5 public setter must reject non-finite configuration values")
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

    if not _verify_named_a5_runtime_path(native, prop_radius):
        return false
    if not native.call("set_a6_propwash_model", false, 12.0, 2.0, 0.5):
        push_error("A6 public path must accept a disabled valid configuration")
        return false
    var a6_disabled: Dictionary = native.call("a6_propwash_configuration")
    if bool(a6_disabled.get("enabled", true)) or native.call("telemetry_snapshot").get("propwash_disturbance_rad_s2", Vector3.ONE) != Vector3.ZERO:
        push_error("A6 disabled public path must expose an exact-zero configuration and telemetry")
        return false
    if not native.call("set_a6_propwash_model", true, 12.0, 2.0, 0.5):
        push_error("A6 public path must accept an enabled valid configuration")
        return false
    native.call("reset_flight")
    if not native.call("arm_flight_control", 0.0):
        push_error("A6 public path must arm from low throttle")
        return false
    native.call("sync_flight_state", 0.0, 0.0, 0.0, 0.5, 0.0, 0.0, 0.866025403784, 0.0, -6.0, 0.0, 3.0, 0.0, -4.0)
    native.call("step_angle_mode", Engine.physics_ticks_per_second, 1000, 0.75, 0.0, 0.0, 0.0)
    var a6_snapshot: Dictionary = native.call("telemetry_snapshot")
    if a6_snapshot.get("propwash_disturbance_rad_s2", Vector3.ZERO) == Vector3.ZERO:
        push_error("A6 enabled public path must apply and publish the configured disturbance")
        return false
    if not native.call("set_a6_propwash_model", false, 0.0, 0.0, 0.0):
        push_error("A6 public path must accept disabling the model")
        return false
    if native.call("telemetry_snapshot").get("propwash_disturbance_rad_s2", Vector3.ONE) != Vector3.ZERO:
        push_error("A6 disable transition must clear published disturbance immediately")
        return false
    if not native.call("set_dual_aircraft_positions", 0.0, 2.0, 0.0, 0.0, 0.0, 0.0):
        push_error("A5 dual path must accept finite upper/lower positions")
        return false
    var dual_row: PackedFloat64Array = native.call("step_dual_aircraft_simulation", Engine.physics_ticks_per_second, 1000, 0.72 * 9.80665)
    if dual_row.size() < 11 or float(dual_row[8]) >= 0.0 or float(dual_row[9]) > float(dual_row[8]):
        push_error("A5 dual frame path must consume the enabled configuration")
        return false
    if native.call("step_dual_aircraft_simulation", Engine.physics_ticks_per_second, 0, 0.72 * 9.80665).size() != 0:
        push_error("A5 dual frame path must reject non-positive substep rates")
        return false
    if native.call("step_dual_aircraft_simulation", 0, 1000, 0.72 * 9.80665).size() != 0:
        push_error("A5 dual frame path must reject non-positive physics rates")
        return false
    if native.call("set_a5_downwash_model", true, prop_radius, -1.0, 0.16, -0.11):
        push_error("A5 public path must reject a negative force magnitude coefficient")
        return false
    native.call("set_a6_propwash_model", false, 0.0, 0.0, 0.0)
    native.call("set_a5_downwash_model", false, prop_radius, 2267.18, 0.16, -0.11)
    native.call("set_a5_downwash_source_position", NAN, NAN, NAN)
    native.call("set_a3_drag_model", false, 0.0001, 0.0001, 0.00012)
    native.call("set_a4_ground_effect_model", false, 3.16e-10, 11.36859, prop_radius, prop_radius, 12000.0, 12000.0, 12000.0, 12000.0)
    return true


func _verify_named_a5_runtime_path(native: Object, prop_radius: float) -> bool:
    if not native.call("set_a4_ground_effect_model", false, 3.16e-10, 11.36859, prop_radius, prop_radius, 12000.0, 12000.0, 12000.0, 12000.0):
        push_error("named A5 runtime path could not disable A4")
        return false
    if not native.call("set_a6_propwash_model", false, 0.0, 0.0, 0.0):
        push_error("named A5 runtime path could not disable A6")
        return false

    native.call("set_a5_downwash_model", false, prop_radius, 2267.18, 0.16, -0.11)
    native.call("reset_flight")
    if not native.call("arm_flight_control", 0.0):
        push_error("named A5 effects-off path could not arm")
        return false
    native.call("sync_flight_state", 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0)
    var effects_off_y := 0.0
    for frame in range(20):
        native.call("set_a5_downwash_source_position", -4.0 + float(frame) * 0.4, 2.0, 0.0)
        var row: PackedFloat64Array = native.call("step_angle_mode", Engine.physics_ticks_per_second, 1000, 0.5, 0.0, 0.0, 0.0)
        effects_off_y = float(row[2])
    if absf(float(native.call("a5_downwash_force_y", 0.0, 2.0, 0.0, 0.0, 0.0, 0.0))) > 1e-12:
        push_error("named A5 effects-off runtime path must produce exact zero")
        return false

    native.call("set_a5_downwash_model", true, prop_radius, 2267.18, 0.16, -0.11)
    native.call("reset_flight")
    if not native.call("arm_flight_control", 0.0):
        push_error("named A5 effects-on path could not arm")
        return false
    native.call("sync_flight_state", 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0)
    var effects_on_y := 0.0
    for frame in range(20):
        native.call("set_a5_downwash_source_position", -4.0 + float(frame) * 0.4, 2.0, 0.0)
        var row: PackedFloat64Array = native.call("step_angle_mode", Engine.physics_ticks_per_second, 1000, 0.5, 0.0, 0.0, 0.0)
        effects_on_y = float(row[2])
    if effects_on_y >= effects_off_y:
        push_error("named A5 effects-on crossing runtime path must reduce lower trajectory")
        return false
    native.call("set_a5_downwash_model", true, prop_radius, 2267.18, 0.16, -0.11)
    return true

func _verify_collision_public_path(native: Object) -> bool:
    if not native.has_method("step_collision_acro_mode"):
        push_error("AeroSimNative.step_collision_acro_mode must exist for ACRO collision authority")
        return false
    native.call("reset_flight")
    native.call("set_collision_release_frames", 5)
    var invalid_angle_args: Array = [0, 1000, 0.0, 0.0, 0.0, 0.0, true, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, -1.0]
    if native.callv("step_collision_angle_mode", invalid_angle_args).size() != 0:
        push_error("Public collision Angle path must reject non-positive simulation rates")
        return false
    var invalid_acro_args: Array = [0, 1000, 0.0, 0.0, 0.0, 0.0, 1.0, 0.7, 0.0, true, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, -1.0]
    if native.callv("step_collision_acro_mode", invalid_acro_args).size() != 0:
        push_error("Public collision Acro path must reject non-positive simulation rates")
        return false
    var invalid_altitude_args: Array = [0, 1000, 0.0, 0.0, 0.0, 0.0, true, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, -1.0]
    if native.callv("step_collision_altitude_hold_mode", invalid_altitude_args).size() != 0:
        push_error("Public collision altitude-hold path must reject non-positive simulation rates")
        return false
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
    if not native.call("arm_flight_control", 0.0):
        push_error("Zero-energy collision setup should arm from low throttle")
        return false
    var zero_energy_impact: PackedFloat64Array = _step_native_collision(
        native,
        0.5,
        true,
        Vector3.LEFT,
        Vector3.ZERO,
        Vector3(100.0, 0.0, 0.0),
        Vector3.ZERO,
        0.0
    )
    if zero_energy_impact.size() < 18 or not is_finite(float(zero_energy_impact[17])) or float(zero_energy_impact[17]) > 0.0:
        push_error("Collision public path must enforce a stationary zero-energy Jolt cap")
        return false
    native.call("reset_flight")
    return true

func _verify_px4_actuator_public_path(native: Object) -> bool:
    if not native.has_method("step_collision_px4_actuator_mode"):
        push_error("AeroSimNative.step_collision_px4_actuator_mode must expose the PX4 actuator path")
        return false
    native.call("reset_flight")
    if native.call("step_px4_actuator_mode", 0, 1000, 0.5, 0.5, 0.5, 0.5).size() != 0:
        push_error("Public PX4 actuator path must reject non-positive simulation rates")
        return false
    var invalid_collision_row: PackedFloat64Array = native.call(
        "step_collision_px4_actuator_mode",
        0,
        1000,
        0.5,
        0.5,
        0.5,
        0.5,
        true,
        0.0,
        1.0,
        0.0,
        0.0,
        0.0,
        0.0,
        0.0,
        0.0,
        0.0,
        0.0,
        0.0,
        0.0,
        0.0,
        -1.0
    )
    if invalid_collision_row.size() != 0:
        push_error("Public collision path must reject non-positive simulation rates before touching contact state")
        return false
    var invalid_energy_args := [
        Engine.physics_ticks_per_second, 1000, 0.5, 0.5, 0.5, 0.5, false,
        0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
        0.0, 0.0, 0.0, 0.0, 0.0, 0.0, -2.0
    ]
    if not (native.callv("step_collision_px4_actuator_mode", invalid_energy_args) as PackedFloat64Array).is_empty():
        push_error("Public collision path must reject invalid negative kinetic-energy limits")
        return false
    if not native.call("set_body_drag_model", true, 1.0, 1.0, 1.0, 0.1, 0.1, 0.1, 0.0, 0.0, 0.0, 1.225):
        push_error("PX4 telemetry setup must enable body drag")
        return false
    native.call("reset_flight")
    native.call("sync_flight_state", 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0, 10.0, 0.0, 0.0, 0.0, 0.0, 0.0)
    native.call("step_px4_actuator_mode", Engine.physics_ticks_per_second, 1000, 0.5, 0.5, 0.5, 0.5)
    var active_snapshot: Dictionary = native.call("telemetry_snapshot")
    if str(active_snapshot.get("body_drag_operating_state", "")) != "active" or \
            str(active_snapshot.get("control_authority", "")) != "px4_external" or \
            active_snapshot.get("armed", false) != null or bool(active_snapshot.get("armed_available", true)) or \
            bool(active_snapshot.get("pid_available", true)) or active_snapshot.pid[0].output != null or \
            float(active_snapshot.motors[0].thrust_newtons) <= 0.0 or \
            not (active_snapshot.get("body_drag_force_body_frd_n_mean") is Vector3) or \
            (active_snapshot.body_drag_force_body_frd_n_mean as Vector3) == Vector3.ZERO:
        push_error("Normal PX4 actuator authority must publish applied body-drag telemetry")
        return false
    var row: PackedFloat64Array = native.call(
        "step_collision_px4_actuator_mode",
        Engine.physics_ticks_per_second,
        1000,
        0.5,
        0.5,
        0.5,
        0.5,
        false,
        0.0,
        0.0,
        0.0,
        0.0,
        0.0,
        0.0,
        0.0,
        0.0,
        0.0,
        0.0,
        0.0,
        0.0,
        0.0,
        -1.0
    )
    if row.size() < 17 or not is_finite(float(row[1])) or not is_finite(float(row[2])):
        push_error("PX4 actuator public path must return a deterministic body-state row")
        return false
    var jolt_args := [
        Engine.physics_ticks_per_second, 1000, 0.5, 0.5, 0.5, 0.5, true,
        0.0, 1.0, 0.0, 0.0, 1.0, 0.0, 0.0,
        float(row[8]), float(row[9]), float(row[10]), float(row[14]), float(row[15]), float(row[16]), -1.0
    ]
    var jolt_row: PackedFloat64Array = native.callv("step_collision_px4_actuator_mode", jolt_args)
    var unavailable_snapshot: Dictionary = native.call("telemetry_snapshot")
    if int(unavailable_snapshot.get("publish_count", -1)) != int(active_snapshot.get("publish_count", -2)):
        push_error("Jolt unavailable telemetry must not bypass the frozen 30 Hz publication cadence")
        return false
    for _frame in range(12):
        jolt_row = native.callv("step_collision_px4_actuator_mode", jolt_args)
        unavailable_snapshot = native.call("telemetry_snapshot")
        if int(unavailable_snapshot.get("publish_count", -1)) > int(active_snapshot.get("publish_count", -2)):
            break
    if jolt_row.is_empty() or str(unavailable_snapshot.get("body_drag_operating_state", "")) != "unavailable" or \
            unavailable_snapshot.get("body_drag_force_body_frd_n_mean", Vector3.ZERO) != null or \
            unavailable_snapshot.get("body_drag_torque_body_frd_nm_mean", Vector3.ZERO) != null:
        push_error("Jolt authority must publish explicit unavailable body-drag values")
        return false
    native.call("set_body_drag_model", false, 0.0, 0.0, 0.0, 0.1, 0.1, 0.1, 0.0, 0.0, 0.0, 1.225)
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
    var per_motor: Dictionary = native.call("hardware_per_motor_diagnostics")
    var inertia_frd: Vector3 = per_motor.get("inertia_frd", Vector3.ZERO)
    if inertia_frd.x <= 0.0 or inertia_frd.y <= 0.0 or inertia_frd.z <= 0.0:
        push_error("Jolt collision smoke requires positive configured hardware inertia")
        return false

    verified_jolt_collision_trials = 0
    for mode in ["ANGLE", "ACRO"]:
        for scenario in ["wall", "glancing_ground", "pole", "tumble_ground"]:
            for seed in range(100):
                var first: Dictionary = await _run_jolt_collision_trial(native, scenario, seed, mass_kg, inertia_frd, mode)
                var second: Dictionary = await _run_jolt_collision_trial(native, scenario, seed, mass_kg, inertia_frd, mode)
                if not first.ok or not second.ok or not _same_collision_row(first.row, second.row):
                    push_error("Headless Jolt G0.8 trial failed: %s %s seed %d first=%s second=%s" % [mode, scenario, seed, first.get("reason", ""), second.get("reason", "")])
                    return false
                verified_jolt_collision_trials += 1
    var rotated: Dictionary = await _run_jolt_collision_trial(native, "rotated_anisotropic", 0, mass_kg, inertia_frd, "ANGLE")
    if not rotated.ok:
        push_error("Headless Jolt rotated anisotropic-inertia G0.8 trial failed: %s" % rotated.get("reason", ""))
        return false
    verified_jolt_collision_trials += 1
    var zero_energy: Dictionary = await _run_jolt_collision_trial(native, "zero_energy_impactor", 0, mass_kg, inertia_frd, "ANGLE")
    if not zero_energy.ok:
        push_error("Headless Jolt zero-energy production-contact regression failed: %s" % zero_energy.get("reason", ""))
        return false
    verified_jolt_collision_trials += 1
    return true

func _run_jolt_collision_trial(native: Object, scenario: String, seed: int, mass_kg: float, inertia_frd: Vector3, mode: String) -> Dictionary:
    var trial_root := Node3D.new()
    trial_root.name = "JoltCollisionTrial"
    root.add_child(trial_root)

    var drone = CollisionProbeBodyScript.new()
    drone.contact_monitor = true
    drone.max_contacts_reported = 4
    drone.gravity_scale = 0.0
    drone.set("continuous_cd", true)
    drone.mass = mass_kg
    drone.inertia = Vector3(inertia_frd.x, inertia_frd.z, inertia_frd.y)
    _add_shape(drone, _drone_shape(scenario))
    trial_root.add_child(drone)

    _setup_jolt_trial_geometry(trial_root, drone, scenario, seed)
    var energy_before := _kinetic(drone.linear_velocity, _jolt_angular_velocity_body_y_up(drone), mass_kg, inertia_frd)

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
            var solved_angular := _jolt_angular_velocity_body_y_up(drone)
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
        var body_energy := _kinetic(drone.linear_velocity, _jolt_angular_velocity_body_y_up(drone), mass_kg, inertia_frd)
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
        for _frame in range(Engine.physics_ticks_per_second / 2):
            await physics_frame
            _sync_native_from_body(native, drone)
            clear = _step_native_clear_collision(native, 0.8, mode)
            _apply_collision_row_to_body(drone, clear)
        var response_thrust := float(native.call("flight_control_diagnostics").get("motor_thrust_newtons", 0.0))
        ok = ok and clear.size() >= 18 and response_thrust > mass_kg * 9.80665 and _collision_row_finite(clear)
        if not ok and reason == "impact":
            reason = "response"
        if ok:
            _apply_collision_row_to_body(drone, clear)
            ok = _body_state_finite(drone)
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
    elif scenario == "tumble_ground":
        var tumble_ground := StaticBody3D.new()
        tumble_ground.position = Vector3.ZERO
        var tumble_box := BoxShape3D.new()
        tumble_box.size = Vector3(4.0, 0.1, 4.0)
        _add_shape(tumble_ground, tumble_box)
        parent.add_child(tumble_ground)
        drone.position = Vector3(_jitter(seed, 7, -0.2, 0.2), 0.8, _jitter(seed, 8, -0.2, 0.2))
        drone.linear_velocity = Vector3(_jitter(seed, 9, -2.0, 2.0), -8.0, _jitter(seed, 10, -2.0, 2.0))
        drone.angular_velocity = Vector3(_jitter(seed, 11, -9.0, 9.0), _jitter(seed, 12, -9.0, 9.0), _jitter(seed, 13, -9.0, 9.0))
    elif scenario == "zero_energy_impactor":
        drone.position = Vector3.ZERO
        var impactor := RigidBody3D.new()
        impactor.gravity_scale = 0.0
        impactor.mass = drone.mass
        impactor.set("continuous_cd", true)
        _add_shape(impactor, _drone_shape(scenario))
        parent.add_child(impactor)
        impactor.position = Vector3(-1.0, 0.0, 0.0)
        impactor.linear_velocity = Vector3(20.0, 0.0, 0.0)
    else:
        var rotated_ground := StaticBody3D.new()
        var rotated_box := BoxShape3D.new()
        rotated_box.size = Vector3(4.0, 0.1, 4.0)
        _add_shape(rotated_ground, rotated_box)
        parent.add_child(rotated_ground)
        drone.rotation = Vector3(0.0, 0.0, PI * 0.5)
        drone.position = Vector3(0.0, 0.8, 0.0)
        drone.linear_velocity = Vector3(0.0, -8.0, 0.0)
        drone.angular_velocity = Vector3(0.0, 9.0, 0.0)

func _drone_shape(scenario: String) -> Shape3D:
    if scenario == "tumble_ground" or scenario == "rotated_anisotropic":
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
    var angular_velocity_body := _jolt_angular_velocity_body_y_up(body)
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
        angular_velocity_body.x,
        angular_velocity_body.y,
        angular_velocity_body.z
    )

func _jolt_angular_velocity_body_y_up(body: RigidBody3D) -> Vector3:
    return body.global_transform.basis.inverse() * body.angular_velocity

func _row_impulse(row: PackedFloat64Array) -> Vector3:
    return Vector3(row[21], row[22], row[23])

func _row_normal(row: PackedFloat64Array) -> Vector3:
    return Vector3(row[18], row[19], row[20])

func _row_roll_degrees(row: PackedFloat64Array) -> float:
    return rad_to_deg(2.0 * atan2(float(row[4]), float(row[7])))

func _row_pitch_degrees(row: PackedFloat64Array) -> float:
    return rad_to_deg(2.0 * atan2(float(row[6]), float(row[7])))

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

func _kinetic(linear_velocity: Vector3, angular_velocity: Vector3, mass_kg: float, inertia_frd: Vector3) -> float:
    return 0.5 * mass_kg * linear_velocity.length_squared() + 0.5 * (
        inertia_frd.x * angular_velocity.x * angular_velocity.x +
        inertia_frd.z * angular_velocity.y * angular_velocity.y +
        inertia_frd.y * angular_velocity.z * angular_velocity.z)

func _vector_finite(value: Vector3) -> bool:
    return is_finite(value.x) and is_finite(value.y) and is_finite(value.z)

func _jitter(seed: int, salt: int, low: float, high: float) -> float:
    var unit := fposmod(sin(float(seed * 31 + salt * 17)) * 43758.5453123, 1.0)
    return low + (high - low) * unit

func _verify_runtime_actions() -> bool:
    var scene := SmokeScene.instantiate()
    var device_state := MutableGamepadDeviceState.new()
    scene.gamepad_device_state = device_state
    root.add_child(scene)
    await process_frame
    if scene.native == null:
        push_error("Smoke runtime must instantiate AeroSimNative")
        scene.queue_free()
        return false
    if scene.license_provider != null:
        scene.license_provider.queue_free()
    var smoke_license_provider := SmokeLicenseProvider.new()
    scene.license_provider = smoke_license_provider
    scene.add_child(smoke_license_provider)
    scene.show_main_menu()
    if scene.get_viewport().get_camera_3d() == null or scene.get_viewport().get_camera_3d().name != "ChaseCamera":
        push_error("Playable GUI smoke scene must have a current ChaseCamera Camera3D")
        scene.queue_free()
        return false
    var drone_visual_loader := scene.get_node_or_null("DroneBody/DroneVisualLoader")
    if drone_visual_loader == null or not bool(drone_visual_loader.get("model_loaded")):
        push_error("Playable GUI smoke scene must load the drone visual model")
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
    if scene.main_menu_entries != ["Quick Fly", "Lab Mode", "Controller", "Drone", "Map", "Settings", "Quit"]:
        push_error("Cold-start main menu must expose the exact seven CAP-006 first-layer entries")
        scene.queue_free()
        return false
    var setup_panel = scene.flight_setup_panel
    var drone_entry := scene.get_node_or_null("MainMenu/Entries/Drone") as Button
    var map_entry := scene.get_node_or_null("MainMenu/Entries/Map") as Button
    var drone_button := scene.get_node_or_null("MainMenu/FlightSetupPanel/Rows/Drone") as Button
    var map_button := scene.get_node_or_null("MainMenu/FlightSetupPanel/Rows/Map") as Button
    if drone_entry == null or map_entry == null or drone_button == null or map_button == null:
        push_error("Drone and Map must expose the shared Flight Setup panel")
        scene.queue_free()
        return false
    drone_entry.pressed.emit()
    if scene.flight_setup_panel != setup_panel or scene.get_viewport().gui_get_focus_owner() != drone_button:
        push_error("Drone must open the shared Flight Setup panel with Drone focused")
        scene.queue_free()
        return false
    scene.show_main_menu()
    map_entry.pressed.emit()
    if scene.flight_setup_panel != setup_panel or scene.get_viewport().gui_get_focus_owner() != map_button:
        push_error("Map must open the shared Flight Setup panel with Map focused")
        scene.queue_free()
        return false
    scene.show_main_menu()
    if not scene.apply_flight_setup({"wind_preset": "severe"}):
        push_error("Quick Fly default reset setup must accept the existing wind choice")
        scene.queue_free()
        return false
    scene.flight_setup["stale"] = "invalid"
    scene.quick_fly()
    if scene.flight_setup != scene.default_flight_setup() or scene.selected_wind_preset != "calm":
        push_error("Quick Fly must reset the shared setup to its canonical defaults")
        scene.queue_free()
        return false
    if scene.screen != "fallback_prompt" or scene.loaded_map_id != "industrial_yard" or scene.loaded_map == null or scene.get_viewport().get_camera_3d() != scene.chase_camera:
        push_error("No-controller Quick Fly must show Industrial Yard through the FPV camera before keyboard fallback confirmation")
        scene.queue_free()
        return false
    await _press_key(KEY_R)
    if scene.screen != "fallback_prompt" or scene.takeoff_requested or scene.native.call("flight_control_armed"):
        push_error("Reset must not bypass Quick Fly input confirmation")
        scene.queue_free()
        return false
    await _press_key(KEY_ESCAPE)
    if scene.screen != "main_menu" or scene.loaded_map != null or scene.get_node_or_null("LoadedMap") != null:
        push_error("Canceling Quick Fly input fallback must free the preloaded Industrial Yard before returning to the menu")
        scene.queue_free()
        return false
    var native_before: Object = scene.native
    var lab_entry := scene.get_node_or_null("MainMenu/Entries/LabMode") as Button
    if lab_entry == null:
        push_error("Main menu must expose an interactive Lab Mode entry")
        scene.queue_free()
        return false
    lab_entry.pressed.emit()
    await process_frame
    var full_dashboard: Dictionary = scene.status_diagram.get_render_evidence() if scene.status_diagram != null else {}
    if scene.screen != "lab_mode" or scene.dashboard_layout_mode != "full" or scene.native != native_before or \
            full_dashboard.get("layout_mode", "") != "full" or not bool(full_dashboard.get("visible", false)) or \
            not bool(full_dashboard.get("selector_visible", false)):
        push_error("Lab Mode entry must reuse native and show the full existing dashboard layout")
        scene.queue_free()
        return false
    await _press_key(KEY_ESCAPE)
    var compact_dashboard: Dictionary = scene.status_diagram.get_render_evidence() if scene.status_diagram != null else {}
    if scene.screen != "main_menu" or scene.dashboard_layout_mode != "compact" or \
            compact_dashboard.get("layout_mode", "") != "compact" or not bool(compact_dashboard.get("visible", false)) or \
            not bool(compact_dashboard.get("selector_visible", false)):
        push_error("Returning from Lab Mode must restore the compact dashboard and main menu")
        scene.queue_free()
        return false
    scene.quit_on_exit = false
    var quit_button := scene.get_node_or_null("MainMenu/Entries/Quit") as Button
    if quit_button == null:
        push_error("Main menu must expose an interactive Quit entry")
        scene.queue_free()
        return false
    quit_button.pressed.emit()
    if not scene.exit_requested or scene.screen != "main_menu":
        push_error("Quit must use the cleanup-safe request_exit route")
        scene.queue_free()
        return false
    scene.exit_requested = false
    var missing_config_provider := FlightRuntime.new()
    missing_config_provider._build_main_menu()
    missing_config_provider._build_flight_hud()
    if missing_config_provider._configure_license_provider({}) or missing_config_provider.screen != "license_blocked" or not missing_config_provider.last_error_message.contains("configuration failed"):
        push_error("Missing license provider configuration must fail loudly")
        missing_config_provider.free()
        scene.queue_free()
        return false
    missing_config_provider.free()

    var canary_provider_runtime := FlightRuntime.new()
    canary_provider_runtime._build_main_menu()
    canary_provider_runtime._build_flight_hud()
    var canary_config := {
        "schema_version": 1,
        "issue_endpoint": "https://license.example.test/issue",
        "verify_endpoint": "https://license.example.test/verify",
        "public_key_path": "res://config/SMOKE_KEY_CANARY_19C4.pem",
        "allowed_kids": ["SMOKE_CLAIM_CANARY_83B1"],
        "state_path": "user://aerosim-smoke-canary-state.json",
        "token": "SMOKE_TOKEN_CANARY_7F2A",
        "key": "SMOKE_KEY_CANARY_19C4",
        "customer": "SMOKE_CUSTOMER_CANARY_52D8",
        "claim": "SMOKE_CLAIM_CANARY_83B1",
    }
    if canary_provider_runtime._configure_license_provider(canary_config) or canary_provider_runtime.screen != "license_blocked" or \
            not canary_provider_runtime.last_error_message.contains("configuration failed") or \
            canary_provider_runtime.license_provider == null or canary_provider_runtime.license_provider.get_script() != LicenseProviderScript:
        push_error("Real license provider must fail loudly on the invalid canary-bearing configuration")
        canary_provider_runtime.free()
        scene.queue_free()
        return false
    var blocked_output := JSON.stringify({
        "screen": canary_provider_runtime.screen,
        "error": canary_provider_runtime.last_error_message,
        "license_status": canary_provider_runtime.license_status_label.text,
        "arm_status": canary_provider_runtime.arm_status_label.text,
        "snapshot": canary_provider_runtime.get_license_snapshot(),
    })
    for canary in [canary_config.token, canary_config.key, canary_config.customer, canary_config.claim]:
        if blocked_output.contains(String(canary)):
            push_error("Blocked license UI/status/error output must not expose controlled credential canaries")
            canary_provider_runtime.free()
            scene.queue_free()
            return false
    canary_provider_runtime.free()
    if not scene.has_method("open_map_menu") or not scene.has_method("select_map"):
        push_error("Smoke runtime must expose Map wind preset selection")
        scene.queue_free()
        return false
    if not scene.load_map("industrial_yard"):
        push_error("Normal Industrial Yard loading must succeed before map wind selection")
        scene.queue_free()
        return false
    var descriptor_wind_config: Dictionary = scene.native.call("wind_configuration")
    if descriptor_wind_config.get("preset", "") != "calm":
        push_error("Normal map loading must apply the descriptor wind_preset")
        scene.queue_free()
        return false
    scene.open_map_menu()
    await process_frame
    var severe_wind_button := scene.get_node_or_null("MapMenu/WindPresets/Severe") as Button
    if severe_wind_button == null:
        push_error("Map menu must expose the Severe wind preset")
        scene.queue_free()
        return false
    severe_wind_button.pressed.emit()
    var wind_config: Dictionary = scene.native.call("wind_configuration")
    if wind_config.get("preset", "") != "severe" or \
            not _same_imu_value(wind_config.get("steady_wind", Vector3.ZERO), scene.scene_steady_wind_mps):
        push_error("Map selection must apply the scene steady wind vector to native wind configuration")
        scene.queue_free()
        return false
    scene.native.call("configure_wind", {
        "preset": "not-a-preset",
        "steady_wind": Vector3(9.0, 8.0, 7.0),
    })
    var invalid_preset_config: Dictionary = scene.native.call("wind_configuration")
    if invalid_preset_config.get("preset", "") != "severe" or \
            not _same_imu_value(invalid_preset_config.get("steady_wind", Vector3.ZERO), scene.scene_steady_wind_mps):
        push_error("Invalid wind presets must not replace the last valid native configuration")
        scene.queue_free()
        return false
    scene.native.call("configure_wind", {
        "preset": "severe",
        "steady_wind": Vector3(INF, 0.0, 0.0),
    })
    var invalid_vector_config: Dictionary = scene.native.call("wind_configuration")
    if invalid_vector_config.get("preset", "") != "severe" or \
            not _same_imu_value(invalid_vector_config.get("steady_wind", Vector3.ZERO), scene.scene_steady_wind_mps):
        push_error("Non-finite wind vectors must not enter the native wind configuration")
        scene.queue_free()
        return false
    scene.native.call("configure_wind", {
        "preset": "severe",
        "steady_wind": Vector3(1.0, 2.0, 3.0),
    })
    scene.native.call("configure_wind", {"preset": "severe"})
    var partial_config: Dictionary = scene.native.call("wind_configuration")
    if not _same_imu_value(partial_config.get("steady_wind", Vector3.ZERO), Vector3(1.0, 2.0, 3.0)):
        push_error("Omitted wind fields must preserve the existing native configuration")
        scene.queue_free()
        return false
    scene.native.call("configure_wind", {
        "preset": "light",
        "steady_wind": "not a Vector3",
    })
    var invalid_type_config: Dictionary = scene.native.call("wind_configuration")
    if invalid_type_config.get("preset", "") != "severe" or \
            not _same_imu_value(invalid_type_config.get("steady_wind", Vector3.ZERO), Vector3(1.0, 2.0, 3.0)):
        push_error("Wrong-type wind vectors must reject the entire native configuration update")
        scene.queue_free()
        return false
    if not scene.load_map("industrial_yard"):
        push_error("Reloading Industrial Yard must preserve the selected wind preset")
        scene.queue_free()
        return false
    descriptor_wind_config = scene.native.call("wind_configuration")
    if descriptor_wind_config.get("preset", "") != "severe":
        push_error("Map wind selection must survive normal map loading")
        scene.queue_free()
        return false
    var quick_fly_button := scene.get_node_or_null("MainMenu/Entries/QuickFly") as Button
    if quick_fly_button == null or quick_fly_button.text != "Quick Fly":
        push_error("Cold-start main menu must expose an interactive Quick Fly button")
        scene.queue_free()
        return false
    var controller_button := scene.get_node_or_null("MainMenu/Entries/Controller") as Button
    if controller_button == null:
        push_error("Main menu must expose an interactive Controller entry")
        scene.queue_free()
        return false
    controller_button.pressed.emit()
    await process_frame
    if scene.screen != "fallback_prompt":
        push_error("Controller opened from the menu must use the fallback route without a controller")
        scene.queue_free()
        return false
    scene.arm_takeoff_button.pressed.emit()
    await process_frame
    if scene.screen != "main_menu" or scene.takeoff_requested:
        push_error("Controller fallback from the menu must return to the main menu")
        scene.queue_free()
        return false
    var known_device_id := await _inject_known_gamepad()
    if known_device_id < 0:
        push_error("Virtual SDL gamepad must register as a known controller for confirmation coverage")
        scene.queue_free()
        return false
    device_state.replace_snapshot([known_device_id], [known_device_id])
    Input.joy_connection_changed.emit(known_device_id, true)
    await process_frame
    var settings_button := scene.get_node_or_null("MainMenu/Entries/Settings") as Button
    if settings_button == null:
        push_error("Main menu must expose an interactive Settings entry")
        scene.queue_free()
        return false
    settings_button.pressed.emit()
    await process_frame
    if scene.screen != "settings":
        push_error("Settings entry must open the Settings screen")
        scene.queue_free()
        return false
    var settings_controller_button := scene.get_node_or_null("MainMenu/SettingsPanel/Rows/Controller") as Button
    if settings_controller_button == null:
        push_error("Settings must expose a Controller entry")
        scene.queue_free()
        return false
    settings_controller_button.pressed.emit()
    await process_frame
    if scene.screen != "controller_settings":
        push_error("Settings Controller entry must open Controller settings")
        scene.queue_free()
        return false
    var controller_settings := scene.get_node_or_null("MainMenu/ControllerSettingsPanel") as Control
    var device_label := scene.get_node_or_null("MainMenu/ControllerSettingsPanel/Rows/CurrentDevice") as Label
    var fixed_mapping_label := scene.get_node_or_null("MainMenu/ControllerSettingsPanel/Rows/FixedMapping") as Label
    var channel_monitor_label := scene.get_node_or_null("MainMenu/ControllerSettingsPanel/Rows/ChannelMonitor") as Label
    var reset_button := scene.get_node_or_null("MainMenu/ControllerSettingsPanel/Rows/ResetXboxDefault") as Button
    if controller_settings == null or device_label == null or fixed_mapping_label == null or channel_monitor_label == null or reset_button == null:
        push_error("Controller settings must show device, fixed mapping, Channel Monitor, and Xbox reset action")
        scene.queue_free()
        return false
    if not controller_settings.is_visible_in_tree() or not device_label.text.contains(str(known_device_id)):
        push_error("Controller settings must show the currently connected device")
        scene.queue_free()
        return false
    if fixed_mapping_label.text != "FIXED XBOX MAPPING: UNAVAILABLE" or channel_monitor_label.text != "\n".join([
        "CHANNEL MONITOR (30 Hz)",
        "roll:     UNAVAILABLE",
        "pitch:    UNAVAILABLE",
        "yaw:      UNAVAILABLE",
        "throttle: UNAVAILABLE",
        "DEADZONE: 0.080 (fixed)",
        "ARM: UNAVAILABLE",
        "MODE: UNAVAILABLE",
    ]):
        push_error("Controller settings must show the unavailable Channel Monitor before Xbox profile confirmation")
        scene.queue_free()
        return false
    reset_button.pressed.emit()
    await process_frame
    if scene.screen != "controller_confirmation":
        push_error("Reset Xbox default must require confirmation before replacing the session profile")
        scene.queue_free()
        return false
    if scene.controller_confirmation_panel == null:
        push_error("Reset Xbox default must open the real controller confirmation panel")
        scene.queue_free()
        return false
    var confirmation: Control = scene.controller_confirmation_panel
    var mapping := confirmation.get_node_or_null("Rows/FixedMapping") as Label
    var axes := confirmation.get_node_or_null("Rows/LiveAxes") as Label
    var confirm_button := confirmation.get_node_or_null("Rows/UseXboxDefaultProfile") as Button
    if mapping == null or axes == null or confirm_button == null:
        push_error("Controller confirmation must expose fixed mapping, live axes, and confirmation action")
        scene.queue_free()
        return false
    for expected_mapping in ["roll -> Axis 2", "pitch -> Axis 3", "yaw -> Axis 0", "throttle -> Axis 1"]:
        if not mapping.text.contains(expected_mapping):
            push_error("Controller confirmation must show the fixed Xbox mapping: %s" % expected_mapping)
            scene.queue_free()
            return false
    for expected_axis in [
        "roll: Raw +0.250 | Normalized +0.167",
        "pitch: Raw -0.750 | Normalized +0.694",
        "yaw: Raw +0.500 | Normalized +0.420",
        "throttle: Raw -0.500 | Normalized +0.420"
    ]:
        if not axes.text.contains(expected_axis):
            push_error("Controller confirmation must show the expected live axis value: %s" % expected_axis)
            scene.queue_free()
            return false
    for update in [
        {"axis": JOY_AXIS_LEFT_X, "value": -0.5, "expected": "yaw: Raw -0.500 | Normalized -0.420"},
        {"axis": JOY_AXIS_LEFT_Y, "value": 0.5, "expected": "throttle: Raw +0.500 | Normalized -0.420"},
        {"axis": JOY_AXIS_RIGHT_X, "value": -0.25, "expected": "roll: Raw -0.250 | Normalized -0.167"},
        {"axis": JOY_AXIS_RIGHT_Y, "value": 0.75, "expected": "pitch: Raw +0.750 | Normalized -0.694"}
    ]:
        _inject_joy_axis(known_device_id, update.axis, update.value)
        await process_frame
        await process_frame
        if not axes.text.contains(update.expected):
            push_error("Controller confirmation must update each live axis value: %s" % update.expected)
            scene.queue_free()
            return false
    confirm_button.pressed.emit()
    await process_frame
    if scene.screen != "controller_settings" or scene.session_gamepad_profile == null or scene.takeoff_requested or scene.native.call("flight_control_armed"):
        push_error("Settings Xbox default profile confirmation must save the session profile and return to Controller Settings")
        scene.queue_free()
        return false
    var controller_settings_back := scene.get_node_or_null("MainMenu/ControllerSettingsPanel/Rows/Back") as Button
    var settings_back := scene.get_node_or_null("MainMenu/SettingsPanel/Rows/Back") as Button
    if controller_settings_back == null or settings_back == null:
        push_error("Controller Settings smoke must expose the real Settings return path")
        scene.queue_free()
        return false
    controller_settings_back.pressed.emit()
    await process_frame
    settings_back.pressed.emit()
    await process_frame
    if scene.screen != "main_menu":
        push_error("Settings return path must restore the main menu after Controller Settings")
        scene.queue_free()
        return false
    scene.persisted_gamepad_profile = null
    scene.session_gamepad_profile = null
    scene.session_gamepad_device_id = -1
    scene.unload_map()
    quick_fly_button.pressed.emit()
    await process_frame
    if scene.screen != "controller_confirmation" or scene.controller_return_screen != "preflight":
        push_error("Quick Fly must exercise a fresh controller confirmation route before preflight")
        scene.queue_free()
        return false
    if scene.loaded_map_id != "industrial_yard" or scene.loaded_map == null or scene.get_viewport().get_camera_3d() != scene.chase_camera:
        push_error("Known unconfirmed controller Quick Fly must show Industrial Yard through the FPV camera before confirmation")
        scene.queue_free()
        return false
    confirmation = scene.controller_confirmation_panel
    confirm_button = confirmation.get_node_or_null("Rows/UseXboxDefaultProfile") as Button
    if confirm_button == null:
        push_error("Quick Fly confirmation must expose the real Xbox profile completion action")
        scene.queue_free()
        return false
    confirm_button.pressed.emit()
    await process_frame
    if scene.screen != "preflight" or scene.takeoff_requested or scene.native.call("flight_control_armed"):
        push_error("Quick Fly confirmation completion must enter low-throttle preflight, not the menu")
        scene.queue_free()
        return false
    if scene.loaded_map_id != "industrial_yard" or scene.loaded_map == null:
        push_error("Quick Fly preflight must load Industrial Yard as the default Free Flight map")
        scene.queue_free()
        return false
    if scene.get_viewport().get_camera_3d() != scene.chase_camera or not scene.chase_camera.current:
        push_error("Industrial Yard preflight must keep ChaseCamera as the active Camera3D")
        scene.queue_free()
        return false
    _inject_joy_button(known_device_id, JOY_BUTTON_BACK, true)
    await process_frame
    _inject_joy_button(known_device_id, JOY_BUTTON_BACK, false)
    await process_frame
    var third_person_camera := scene.get_node_or_null("ThirdPersonCamera") as Camera3D
    if third_person_camera == null or scene.get_viewport().get_camera_3d() != third_person_camera or scene._airsim_camera_source() != scene.chase_camera:
        push_error("Xbox BACK View Toggle must switch the player to a third-person camera without changing the AirSim FPV source")
        scene.queue_free()
        return false
    var local_camera_offset: Vector3 = scene.drone_body.global_basis.inverse() * (third_person_camera.global_position - scene.drone_body.global_position)
    if local_camera_offset.y <= 0.0 or local_camera_offset.z <= 0.0:
        push_error("Third-person camera must remain above and behind the drone in body coordinates")
        scene.queue_free()
        return false
    await _press_key(KEY_V)
    if scene.get_viewport().get_camera_3d() != scene.chase_camera or not scene.chase_camera.current:
        push_error("View Toggle must return the player to the FPV camera")
        scene.queue_free()
        return false
    await _press_key(KEY_V)
    scene.quick_fly()
    await process_frame
    if scene.screen != "preflight" or scene.get_viewport().get_camera_3d() != scene.chase_camera or scene.third_person_view:
        push_error("Every new Quick Fly session must reset the primary player view to FPV")
        scene.queue_free()
        return false
    var spawn := scene.loaded_map.get_node_or_null("SpawnNorth") as Marker3D
    if spawn == null or scene.drone_body.global_position.distance_to(spawn.global_position) > 1e-6:
        push_error("Industrial Yard load must place the drone at SpawnNorth")
        scene.queue_free()
        return false
    if scene.load_map("missing_map") or not scene.last_error_message.contains("missing_map"):
        push_error("Missing Free Flight maps must fail with the requested map id in the error")
        scene.queue_free()
        return false
    if scene.loaded_map_id != "industrial_yard" or scene.loaded_map == null:
        push_error("Missing map load must not fall back to or replace the active Industrial Yard map")
        scene.queue_free()
        return false
    if not scene.has_method("set_gamepad_button_time_source"):
        push_error("Flight runtime must accept an injected button timestamp source for deterministic debounce tests")
        scene.queue_free()
        return false
    var button_clock := ButtonClock.new()
    scene.set_gamepad_button_time_source(button_clock.now_ms)
    for axis in [JOY_AXIS_LEFT_X, JOY_AXIS_LEFT_Y, JOY_AXIS_RIGHT_X, JOY_AXIS_RIGHT_Y]:
        _inject_joy_axis(known_device_id, axis, 0.04)
    await process_frame
    await process_frame
    if scene._profile_axis("roll") != 0.0 or scene._profile_axis("pitch") != 0.0 or scene._profile_axis("yaw") != 0.0:
        push_error("Xbox axes inside the profile deadzone must produce zero flight input")
        scene.queue_free()
        return false
    _inject_joy_axis(known_device_id, JOY_AXIS_RIGHT_Y, 0.50)
    await process_frame
    await process_frame
    if scene._profile_axis("pitch") >= 0.0:
        push_error("Positive Xbox pitch raw input must be reversed before flight control")
        scene.queue_free()
        return false
    _inject_joy_axis(known_device_id, JOY_AXIS_RIGHT_Y, -0.50)
    await process_frame
    await process_frame
    if scene._profile_axis("pitch") <= 0.0:
        push_error("Negative Xbox pitch raw input must retain the opposite reversed sign")
        scene.queue_free()
        return false
    _inject_joy_axis(known_device_id, JOY_AXIS_LEFT_Y, -0.75)
    await process_frame
    await process_frame
    if not scene.arm_status_label.text.contains("HIGH"):
        push_error("Confirmed Xbox profile must show the live high throttle state before arming")
        scene.queue_free()
        return false
    _inject_joy_button(known_device_id, JOY_BUTTON_A, true)
    await process_frame
    if scene.takeoff_requested or scene.native.call("flight_control_armed"):
        push_error("Xbox Arm press must reject a live profile throttle above the fixed low threshold")
        scene.queue_free()
        return false
    if not scene.arm_status_label.text.contains("Arm PRESSED"):
        push_error("Xbox Arm press state must be observable in the flight HUD")
        scene.queue_free()
        return false
    _inject_joy_button(known_device_id, JOY_BUTTON_A, false)
    await process_frame
    if not scene.arm_status_label.text.contains("Arm RELEASED"):
        push_error("Xbox Arm release state must be observable in the flight HUD")
        scene.queue_free()
        return false
    _inject_joy_axis(known_device_id, JOY_AXIS_LEFT_Y, 1.0)
    await process_frame
    await process_frame
    if not scene.arm_status_label.text.contains("LOW"):
        push_error("Xbox preflight HUD must show the live low throttle state")
        scene.queue_free()
        return false
    button_clock.milliseconds = 49
    _inject_joy_button(known_device_id, JOY_BUTTON_A, true)
    await process_frame
    if scene.takeoff_requested or scene.native.call("flight_control_armed"):
        push_error("Xbox Arm press at 49 ms must remain debounced")
        scene.queue_free()
        return false
    _inject_joy_button(known_device_id, JOY_BUTTON_A, false)
    await process_frame
    if not scene.arm_status_label.text.contains("Arm RELEASED"):
        push_error("Debounced Xbox Arm release must remain observable in the flight HUD")
        scene.queue_free()
        return false
    button_clock.milliseconds = 50
    _inject_joy_button(known_device_id, JOY_BUTTON_A, true)
    await process_frame
    if not scene.takeoff_requested or not scene.native.call("flight_control_armed"):
        push_error("Xbox Arm press must arm only after the live profile throttle is low")
        scene.queue_free()
        return false
    _inject_joy_button(known_device_id, JOY_BUTTON_A, false)
    _inject_joy_axis(known_device_id, JOY_AXIS_LEFT_Y, -0.70)
    for _frame in range(60):
        await physics_frame
    var high_profile_thrust := float(scene.native.call("flight_control_diagnostics").get("motor_thrust_newtons", 0.0))
    _inject_joy_axis(known_device_id, JOY_AXIS_LEFT_Y, 0.70)
    for _frame in range(60):
        await physics_frame
    var low_profile_thrust := float(scene.native.call("flight_control_diagnostics").get("motor_thrust_newtons", 0.0))
    if high_profile_thrust <= low_profile_thrust:
        push_error("Xbox throttle axis must change simulated thrust instead of using a fixed runtime throttle")
        scene.queue_free()
        return false
    for axis in [JOY_AXIS_LEFT_X, JOY_AXIS_LEFT_Y, JOY_AXIS_RIGHT_X, JOY_AXIS_RIGHT_Y]:
        _inject_joy_axis(known_device_id, axis, 0.0)
    scene.native.call("reset_flight")
    scene.drone_body.apply_native_state(Vector3(100.0, 100.0, 100.0), Quaternion.IDENTITY, Vector3.ZERO, Vector3.ZERO)
    scene.drone_body.reset_contact()
    _inject_joy_axis(known_device_id, JOY_AXIS_LEFT_X, -0.50)
    _inject_joy_axis(known_device_id, JOY_AXIS_RIGHT_X, -0.25)
    _inject_joy_axis(known_device_id, JOY_AXIS_RIGHT_Y, 0.50)
    for _frame in range(30):
        await physics_frame
    var angle_rates := Vector3(
        float(scene.native.call("flight_control_diagnostics").get("angular_velocity_x_rad_s", 0.0)),
        float(scene.native.call("flight_control_diagnostics").get("angular_velocity_y_rad_s", 0.0)),
        float(scene.native.call("flight_control_diagnostics").get("angular_velocity_z_rad_s", 0.0))
    )
    var angle_rates_frd := AirSimCoordinateContract.godot_body_to_frd(angle_rates)
    if angle_rates_frd.x >= -0.01 or angle_rates_frd.y >= -0.01 or angle_rates_frd.z >= -0.01:
        push_error("Xbox Mode 2 roll, pitch, and yaw axes must produce the expected negative FRD response in Angle mode")
        scene.queue_free()
        return false
    button_clock.milliseconds = 100
    _inject_joy_button(known_device_id, JOY_BUTTON_Y, true)
    await process_frame
    await process_frame
    if scene.flight_mode != "ASSISTED_HOLD" or not scene.arm_status_label.text.contains("Mode PRESSED"):
        push_error("Xbox Mode press must switch flight mode and be observable in the flight HUD")
        scene.queue_free()
        return false
    _inject_joy_button(known_device_id, JOY_BUTTON_Y, false)
    await process_frame
    if not scene.arm_status_label.text.contains("Mode RELEASED"):
        push_error("Xbox Mode release state must be observable in the flight HUD")
        scene.queue_free()
        return false
    button_clock.milliseconds = 149
    _inject_joy_button(known_device_id, JOY_BUTTON_Y, true)
    await process_frame
    if scene.flight_mode != "ASSISTED_HOLD":
        push_error("Xbox Mode presses inside 50 ms must be debounced")
        scene.queue_free()
        return false
    _inject_joy_button(known_device_id, JOY_BUTTON_Y, false)
    await process_frame
    if not scene.arm_status_label.text.contains("Mode RELEASED"):
        push_error("Debounced Xbox Mode release must remain observable in the flight HUD")
        scene.queue_free()
        return false
    button_clock.milliseconds = 150
    _inject_joy_button(known_device_id, JOY_BUTTON_Y, true)
    await process_frame
    if scene.flight_mode != "ANGLE":
        push_error("Xbox Mode press after the 50 ms debounce window must be accepted")
        scene.queue_free()
        return false
    _inject_joy_button(known_device_id, JOY_BUTTON_Y, false)
    _inject_joy_axis(known_device_id, JOY_AXIS_LEFT_X, -0.50)
    _inject_joy_axis(known_device_id, JOY_AXIS_RIGHT_X, -0.25)
    _inject_joy_axis(known_device_id, JOY_AXIS_RIGHT_Y, 0.50)
    await process_frame
    await process_frame
    if scene._angle_roll_degrees() >= 0.0 or scene._angle_pitch_degrees() >= 0.0 or scene._angle_yaw_rate_degrees_per_second() >= 0.0:
        push_error("Altitude Hold must receive the processed Xbox roll, pitch, and yaw profile axes")
        scene.queue_free()
        return false
    scene.flight_mode = "ALTITUDE_HOLD"
    scene.drone_body.apply_native_state(Vector3(100.0, 100.0, 100.0), Quaternion.IDENTITY, Vector3.ZERO, Vector3.ZERO)
    scene.drone_body.reset_contact()
    for _frame in range(30):
        await physics_frame
    var altitude_hold_rates := Vector3(
        float(scene.native.call("flight_control_diagnostics").get("angular_velocity_x_rad_s", 0.0)),
        float(scene.native.call("flight_control_diagnostics").get("angular_velocity_y_rad_s", 0.0)),
        float(scene.native.call("flight_control_diagnostics").get("angular_velocity_z_rad_s", 0.0))
    )
    var altitude_hold_rates_frd := AirSimCoordinateContract.godot_body_to_frd(altitude_hold_rates)
    if altitude_hold_rates_frd.x >= -0.01 or altitude_hold_rates_frd.y >= -0.01 or altitude_hold_rates_frd.z >= -0.01:
        push_error("Xbox negative roll, pitch, and yaw axes must produce negative FRD angular velocity in Altitude Hold")
        scene.queue_free()
        return false
    scene.native.call("reset_flight")
    if not scene.native.call("flight_control_armed"):
        push_error("ACRO profile-axis test must preserve the armed flight controller after reset")
        scene.queue_free()
        return false
    scene.drone_body.apply_native_state(Vector3(100.0, 100.0, 100.0), Quaternion.IDENTITY, Vector3.ZERO, Vector3.ZERO)
    scene.drone_body.reset_contact()
    _inject_joy_axis(known_device_id, JOY_AXIS_LEFT_X, 0.0)
    _inject_joy_axis(known_device_id, JOY_AXIS_LEFT_Y, 0.0)
    _inject_joy_axis(known_device_id, JOY_AXIS_RIGHT_X, 0.65)
    _inject_joy_axis(known_device_id, JOY_AXIS_RIGHT_Y, 0.0)
    await process_frame
    await process_frame
    if scene._profile_axis("roll") <= 0.0 or scene._profile_axis("pitch") != 0.0 or scene._profile_axis("yaw") != 0.0:
        push_error("ACRO test must inject a fresh roll-only Xbox profile input")
        scene.queue_free()
        return false
    scene.flight_mode = "ACRO"
    for _frame in range(30):
        await physics_frame
    var acro_rates := Vector3(
        float(scene.native.call("flight_control_diagnostics").get("angular_velocity_x_rad_s", 0.0)),
        float(scene.native.call("flight_control_diagnostics").get("angular_velocity_y_rad_s", 0.0)),
        float(scene.native.call("flight_control_diagnostics").get("angular_velocity_z_rad_s", 0.0))
    )
    var acro_rates_frd := AirSimCoordinateContract.godot_body_to_frd(acro_rates)
    if acro_rates_frd.x <= 0.01 or absf(acro_rates_frd.x) <= absf(acro_rates_frd.y) or absf(acro_rates_frd.x) <= absf(acro_rates_frd.z):
        push_error("Fresh Xbox roll profile input must produce the expected dominant positive FRD ACRO roll response")
        scene.queue_free()
        return false
    scene.queue_free()
    await process_frame
    scene = SmokeScene.instantiate()
    var replacement_device_state := MutableGamepadDeviceState.new()
    replacement_device_state.replace_snapshot([known_device_id], [known_device_id])
    scene.gamepad_device_state = replacement_device_state
    root.add_child(scene)
    await process_frame
    if scene.license_provider != null:
        scene.license_provider.queue_free()
    var replacement_license_provider := SmokeLicenseProvider.new()
    scene.license_provider = replacement_license_provider
    scene.add_child(replacement_license_provider)
    scene.show_main_menu()
    scene.persisted_gamepad_profile = null
    scene.session_gamepad_profile = null
    scene.session_gamepad_device_id = -1
    scene.quick_fly()
    await process_frame
    if scene.screen != "controller_confirmation" or scene.controller_return_screen != "preflight":
        push_error("Quick Fly must open a fresh controller confirmation route without reusing a profile")
        scene.queue_free()
        return false
    var replacement_confirmation: Control = scene.controller_confirmation_panel
    var replacement_confirm_button := replacement_confirmation.get_node_or_null("Rows/UseXboxDefaultProfile") as Button
    if replacement_confirm_button == null:
        push_error("Quick Fly confirmation must expose its completion action")
        scene.queue_free()
        return false
    replacement_confirm_button.pressed.emit()
    await process_frame
    if scene.screen != "preflight" or scene.takeoff_requested or scene.native.call("flight_control_armed"):
        push_error("Quick Fly confirmation completion must enter preflight, not the menu")
        scene.queue_free()
        return false
    var unknown_device_id := known_device_id + 1
    replacement_device_state.replace_snapshot([], [])
    Input.joy_connection_changed.emit(known_device_id, false)
    await process_frame
    if not scene.last_profile_status.contains("No controller"):
        push_error("Connection handler must refresh fallback status from the injected empty device snapshot")
        scene.queue_free()
        return false
    replacement_device_state.replace_snapshot([unknown_device_id], [])
    Input.joy_connection_changed.emit(unknown_device_id, true)
    await process_frame
    if replacement_device_state.is_joy_known(unknown_device_id) or scene._first_connected_device() != unknown_device_id:
        push_error("Fallback coverage must replace the confirmed device with a connected unknown SDL device")
        scene.queue_free()
        return false
    scene.unload_map()
    scene.quick_fly()
    await process_frame
    if scene.screen != "fallback_prompt" or scene.session_gamepad_profile != null or not scene.arm_status_label.text.contains("Unsupported controller") or scene.arm_takeoff_button.text != "USE KEYBOARD FALLBACK":
        push_error("Quick Fly must block the connected replacement unknown SDL device with an explicit KeyboardProfile fallback")
        scene.queue_free()
        return false
    if scene.loaded_map_id != "industrial_yard" or scene.loaded_map == null or scene.get_viewport().get_camera_3d() != scene.chase_camera:
        push_error("Unknown-controller Quick Fly must show Industrial Yard through the FPV camera before keyboard fallback confirmation")
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
    var takeoff_position: Vector3 = scene.drone_body.global_position
    await _press_key(KEY_T)
    var moved_after_takeoff := false
    var climbed_after_takeoff := false
    # Controlled throttle takeoff is intentionally slower than the removed one-shot jump.
    for _frame in range(480):
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
    if scene.flight_mode != "ASSISTED_HOLD" or not scene.fallback_status_label.text.contains("Mode: ALTITUDE_HOLD"):
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
        if absf(scene.drone_body.angular_velocity.x) > 1.0:
            acro_rate_observed = true
            break
    scene.acro_roll_stick = 0.0
    if scene.collision_handoff_count <= acro_handoffs_before:
        push_error("flight runtime ACRO path must feed DroneBody contact into native collision authority")
        scene.queue_free()
        return false
    if scene.last_collision_authority != 0 or not acro_rate_observed:
        push_error("flight runtime ACRO path must hand back and respond to rates input within 0.5 seconds; authority=%d angular_x=%f" % [scene.last_collision_authority, scene.drone_body.angular_velocity.x])
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
    spawn = scene.loaded_map.get_node_or_null("SpawnNorth") as Marker3D
    if spawn == null or scene.drone_body.global_position.distance_to(spawn.global_position) > 1e-6 or scene.drone_body.linear_velocity.length() > 1e-6 or scene.drone_body.angular_velocity.length() > 1e-6:
        push_error("flight_respawn action must return to Industrial Yard SpawnNorth and clear body velocity; position=%s linear=%s angular=%s" % [scene.drone_body.global_position, scene.drone_body.linear_velocity, scene.drone_body.angular_velocity])
        scene.queue_free()
        return false
    if scene.get_viewport().get_camera_3d() != scene.chase_camera:
        push_error("Industrial Yard reset must retain the active ChaseCamera Camera3D")
        scene.queue_free()
        return false
    for _frame in range(Engine.physics_ticks_per_second / 4 + 1):
        await physics_frame
    if scene.drone_body.freeze or not scene.native.call("flight_control_armed"):
        push_error("flight_respawn action must release reset hold and re-arm after pausing")
        scene.queue_free()
        return false

    scene.quit_on_exit = false
    await _press_key(KEY_ESCAPE)
    await process_frame
    if not scene.exit_requested or scene.screen != "main_menu" or scene.loaded_map != null or scene.get_node_or_null("LoadedMap") != null:
        push_error("flight_exit action must stop flight, free the map, and return to the main menu stub")
        scene.queue_free()
        return false

    scene.queue_free()
    return true

func _inject_known_gamepad() -> int:
    _inject_joy_axis(0, JOY_AXIS_LEFT_X, 0.5)
    _inject_joy_axis(0, JOY_AXIS_LEFT_Y, -0.5)
    _inject_joy_axis(0, JOY_AXIS_RIGHT_X, 0.25)
    _inject_joy_axis(0, JOY_AXIS_RIGHT_Y, -0.75)
    await process_frame
    for device_id in Input.get_connected_joypads():
        if InputProfiles.GamepadProfile.is_supported_device(device_id, production_gamepad_device_state):
            return device_id
    return -1

func _inject_joy_axis(device_id: int, axis: JoyAxis, value: float) -> void:
    var event := InputEventJoypadMotion.new()
    event.device = device_id
    event.axis = axis
    event.axis_value = value
    Input.parse_input_event(event)

func _inject_joy_button(device_id: int, button: JoyButton, pressed: bool) -> void:
    var event := InputEventJoypadButton.new()
    event.device = device_id
    event.button_index = button
    event.pressed = pressed
    Input.parse_input_event(event)

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
    for key in ["frame", "motor", "propeller", "battery", "esc", "aerodynamics", "aircraft", "sensors", "fpv"]:
        if not preset.has(key):
            push_error("5 inch hardware preset missing 3.6.1 category: %s" % key)
            return false
    for key in ["version", "units", "coordinate_frame", "motor_order", "spin_direction", "prop_table_interpolation"]:
        if not preset.has(key):
            push_error("5 inch hardware preset missing required metadata: %s" % key)
            return false
    if preset.aerodynamics.a3.enabled or float(preset.aerodynamics.a3.coefficient_kg.x) < 0.0:
        push_error("Hardware preset must keep uncalibrated A3 coefficients finite, non-negative, and disabled")
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
    if not scene.native.has_method("hardware_per_motor_diagnostics"):
        push_error("AeroSimNative must expose per-motor diagnostics for runtime preset verification")
        scene.queue_free()
        return false
    var startup_power: Dictionary = scene.native.call("hardware_power_diagnostics")
    if abs(float(startup_power.mass_kg) - float(preset.aircraft.mass_kg)) > 1e-9:
        push_error("Runtime startup preset must apply aircraft mass to native")
        scene.queue_free()
        return false
    var preset_inertia := Vector3(float(preset.aircraft.inertia_kg_m2.x), float(preset.aircraft.inertia_kg_m2.y), float(preset.aircraft.inertia_kg_m2.z))
    var jolt_inertia := Vector3(preset_inertia.x, preset_inertia.z, preset_inertia.y)
    if absf(scene.drone_body.mass - float(preset.aircraft.mass_kg)) > 1e-6 or scene.drone_body.inertia.distance_to(jolt_inertia) > 1e-6:
        push_error("Runtime startup preset must apply aircraft mass and inertia to the Jolt body")
        scene.queue_free()
        return false
    if abs(float(startup_power.hover_throttle) - float(power_model.hover_throttle)) > 1e-9:
        push_error("Runtime startup preset must apply derived hover throttle to native")
        scene.queue_free()
        return false
    if abs(float(startup_power.altitude_hold_noise_deadband_m) - float(preset.sensors.barometer_noise_m)) > 1e-9:
        push_error("Runtime startup preset must apply validated barometer noise as native altitude-hold tuning")
        scene.queue_free()
        return false
    if float(startup_power.full_throttle_cap_newtons) >= float(power_model.max_total_thrust_n):
        push_error("Runtime startup preset must apply battery sag to the native thrust cap")
        scene.queue_free()
        return false
    var startup_per_motor: Dictionary = scene.native.call("hardware_per_motor_diagnostics")
    if startup_per_motor.get("spin_direction", []) != preset.spin_direction:
        push_error("Runtime startup preset must apply the declared motor spin order")
        scene.queue_free()
        return false
    if abs(float(startup_per_motor.get("max_thrust_per_motor_newtons", 0.0)) - float(power_model.max_total_thrust_n) / 4.0) > 1e-9:
        push_error("Runtime startup preset must apply per-motor thrust derived from the prop model")
        scene.queue_free()
        return false
    scene.native.call("reset_flight")
    if not scene.native.call("arm_flight_control", 0.0):
        push_error("Config-hash telemetry setup must arm from low throttle")
        scene.queue_free()
        return false
    scene.native.call("step_angle_mode", Engine.physics_ticks_per_second, 1000, float(power_model.hover_throttle), 0.0, 0.0, 0.0)
    var startup_snapshot: Dictionary = scene.native.call("telemetry_snapshot")
    var startup_manifest_json: String = scene._replay_canonical_json(scene.native.call("replay_vehicle_config_manifest"))
    var startup_manifest_hash := String(scene.native.call("replay_manifest_hash", startup_manifest_json))
    if String(startup_snapshot.get("config_hash", "")) != startup_manifest_hash:
        push_error("Telemetry and replay must share the final canonical hardware config hash")
        scene.queue_free()
        return false
    if OS.is_debug_build():
        var debug_panel: Node = scene.body_drag_debug_panel
        if debug_panel == null:
            push_error("Debug builds must create the body-drag presenter")
            scene.queue_free()
            return false
        debug_panel.call("update_from_snapshot", startup_snapshot)
        var wrong_schema_type := startup_snapshot.duplicate(true)
        wrong_schema_type["schema_version"] = "2"
        if String(debug_panel.call("_validate_snapshot", wrong_schema_type, int(startup_snapshot.publish_count) + 1)).is_empty():
            push_error("Body-drag presenter must reject coercible but incorrectly typed telemetry")
            scene.queue_free()
            return false
        # The smoke scene is still on the menu here; expose the presenter explicitly
        # so this check isolates paused rendering from screen-routing visibility.
        debug_panel.call("set_screen_visible", true)
        scene.set_paused(true, false)
        var debug_canvas = debug_panel.get("_panel")
        if String(debug_panel.call("_text_value", "body_drag_operating_state")) != "PAUSED" or debug_canvas == null or not debug_canvas.visible:
            push_error("Paused runtime must leave a visible blind-mode state in the body-drag presenter")
            scene.queue_free()
            return false
        scene.set_paused(false, false)
        debug_panel.call("set_screen_visible", false)
    var native_before: Object = scene.native
    var reset_count_before: int = scene.reset_count
    if not loader.apply_to_runtime(scene, "res://config/drones/5_inch_6s.json"):
        push_error("Runtime must hot-switch the built-in 5 inch hardware preset")
        scene.queue_free()
        return false
    var startup_a3: Dictionary = scene.native.call("a3_drag_configuration")
    if (bool(startup_a3.get("enabled", false)) != bool(preset.aerodynamics.a3.enabled) or
            abs(float(startup_a3.get("coefficient_x_kg", -1.0)) - float(preset.aerodynamics.a3.coefficient_kg.x)) > 1e-12 or
            abs(float(startup_a3.get("coefficient_y_kg", -1.0)) - float(preset.aerodynamics.a3.coefficient_kg.y)) > 1e-12 or
            abs(float(startup_a3.get("coefficient_z_kg", -1.0)) - float(preset.aerodynamics.a3.coefficient_kg.z)) > 1e-12 or
            startup_a3.get("motor_speed_source", "") != "live_motor_thrust_state"):
        push_error("Runtime startup preset must apply static A3 settings and retain live motor speed ownership")
        scene.queue_free()
        return false
    var startup_a6: Dictionary = scene.native.call("a6_propwash_configuration")
    if (bool(startup_a6.get("enabled", true)) != bool(preset.aerodynamics.a6.enabled) or
            abs(float(startup_a6.get("full_collective_angular_accel_rad_s2", -1.0)) - float(preset.aerodynamics.a6.full_collective_angular_accel_rad_s2)) > 1e-12 or
            abs(float(startup_a6.get("minimum_wake_entry_speed_mps", -1.0)) - float(preset.aerodynamics.a6.minimum_wake_entry_speed_mps)) > 1e-12 or
            abs(float(startup_a6.get("minimum_transverse_rate_rad_s", -1.0)) - float(preset.aerodynamics.a6.minimum_transverse_rate_rad_s)) > 1e-12):
        push_error("Runtime startup preset must apply static A6 settings and retain the disabled production default")
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
        "step_simulation",
        Engine.physics_ticks_per_second,
        1000,
        mass_kg * 9.80665
    )
    if hover.size() != 12:
        push_error("AeroSimNative.step_simulation failed to produce a trajectory row")
        return false
    return abs(float(hover[2])) <= 1e-6

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
    var contract_result: Dictionary = InputProfiles.ActionContract.validate_input_map()
    if not contract_result.ok:
        push_error("ActionContract validation failed: %s" % contract_result.error)
        return false
    var actions := {
        "flight_takeoff": KEY_T,
        "flight_pause": KEY_P,
        "flight_respawn": KEY_R,
        "flight_altitude_hold": KEY_H,
        "flight_acro": KEY_C,
        "flight_exit": KEY_ESCAPE,
        "flight_view_toggle": KEY_V,
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
    if profile.profile_schema_version != 2:
        push_error("GamepadProfile must use the fixed Xbox profile schema version")
        return false
    if profile.axis_for_role != {"yaw": JOY_AXIS_LEFT_X, "throttle": JOY_AXIS_LEFT_Y, "roll": JOY_AXIS_RIGHT_X, "pitch": JOY_AXIS_RIGHT_Y}:
        push_error("GamepadProfile must freeze the four distinct Xbox axes")
        return false
    if profile.arm_button != JOY_BUTTON_A or profile.mode_button != JOY_BUTTON_Y:
        push_error("GamepadProfile must freeze distinct Xbox Arm and Mode buttons")
        return false
    if profile.RAW_AXIS_DEADZONE < 0.08 or profile.RAW_AXIS_DEADZONE > 0.10:
        push_error("GamepadProfile must retain the named raw-axis deadzone")
        return false
    if not is_zero_approx(InputProfiles.GamepadProfile.normalize_axis(0.07, profile.RAW_AXIS_DEADZONE)):
        push_error("GamepadProfile axes must ignore input inside the fixed deadzone")
        return false
    if absf(InputProfiles.GamepadProfile.normalize_axis(0.5, profile.RAW_AXIS_DEADZONE) - 0.42038) > 0.00001:
        push_error("GamepadProfile axes must use the fixed centered response curve")
        return false
    if not profile.throttle_axis_is_low(1.0) or profile.throttle_axis_is_low(-1.0):
        push_error("GamepadProfile arm safety must require the left stick to be down")
        return false

    var actions := {
        "flight_takeoff": JOY_BUTTON_A,
        "flight_pause": JOY_BUTTON_START,
        "flight_respawn": JOY_BUTTON_X,
        "flight_altitude_hold": JOY_BUTTON_Y,
        "flight_exit": JOY_BUTTON_B,
        "flight_acro": InputProfiles.GamepadProfile.ACRO_BUTTON
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

func _verify_xbox_default_profile() -> bool:
    if InputProfiles.GamepadProfile.is_supported_device(-1, production_gamepad_device_state) != Input.is_joy_known(-1):
        push_error("GamepadProfile support must use the SDL known-device predicate")
        return false
    if InputProfiles.GamepadProfile.xbox_default(-1, production_gamepad_device_state) != null:
        push_error("An unknown SDL device must not produce an Xbox profile")
        return false
    for device_id in Input.get_connected_joypads():
        if not InputProfiles.GamepadProfile.is_supported_device(device_id, production_gamepad_device_state):
            continue
        var profile := InputProfiles.GamepadProfile.xbox_default(device_id, production_gamepad_device_state)
        if profile == null or profile.profile_schema_version != 2:
            push_error("A known SDL device must receive the fixed Xbox profile schema")
            return false
        if profile.axis_for_role != {"yaw": JOY_AXIS_LEFT_X, "throttle": JOY_AXIS_LEFT_Y, "roll": JOY_AXIS_RIGHT_X, "pitch": JOY_AXIS_RIGHT_Y}:
            push_error("A known SDL device must receive four distinct Xbox axes")
            return false
        if profile.arm_button == profile.mode_button or profile.RAW_AXIS_DEADZONE < 0.08 or profile.RAW_AXIS_DEADZONE > 0.10:
            push_error("A known SDL device must receive distinct buttons and a raw-axis deadzone")
            return false
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
