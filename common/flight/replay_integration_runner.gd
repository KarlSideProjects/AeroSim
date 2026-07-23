extends RefCounted

const SETTINGS_HASH := "integration-settings-v1"


func run() -> Dictionary:
    var native: Object = ClassDB.instantiate("AeroSimNative")
    var lower_native: Object = ClassDB.instantiate("AeroSimNative")
    if native == null or lower_native == null or native == lower_native:
        return _failure("AeroSimNative is not registered")
    if not native.call("set_hardware_mass_kg", 1.0):
        return _failure("native mass setup failed")
    if not native.call("set_hardware_power_model", 4.0, 0.5, 0.03, 22.2, 6.0, 0.003, 4.0):
        return _failure("native power setup failed")
    if not native.call("set_hardware_telemetry_model", 10000.0, 1000.0):
        return _failure("native telemetry setup failed")
    var per_motor := {
        "inertia_frd": Vector3(0.01, 0.01, 0.02),
        "position_frd": [Vector3(-0.1, 0.1, 0.0), Vector3(0.1, 0.1, 0.0), Vector3(-0.1, -0.1, 0.0), Vector3(0.1, -0.1, 0.0)],
        "spin_direction": [1.0, -1.0, -1.0, 1.0],
        "max_thrust_per_motor_newtons": 1.0,
        "max_current_per_motor_a": 1.0,
        "yaw_torque_per_newton": 0.01,
    }
    if not native.call("set_hardware_per_motor_model", per_motor):
        return _failure("native per-motor setup failed")
    if not lower_native.call("set_hardware_mass_kg", 1.0) or \
            not lower_native.call("set_hardware_power_model", 4.0, 0.5, 0.03, 22.2, 6.0, 0.003, 4.0) or \
            not lower_native.call("set_hardware_telemetry_model", 10000.0, 1000.0) or \
            not lower_native.call("set_hardware_per_motor_model", per_motor):
        return _failure("secondary native setup failed")
    var config_json := JSON.stringify(_json_safe(native.call("replay_vehicle_config_manifest")))
    var config_hash := _hash(config_json)
    var begin: Dictionary = native.call(
        "begin_complete_replay_recording", 7, SETTINGS_HASH,
        "DroneA", config_hash, config_json, 0,
        "DroneB", config_hash, config_json, 0)
    if not bool(begin.get("ok", false)):
        return _failure("replay recording did not start: %s" % String(begin.get("diagnostic_message", "unknown")))
    lower_native.call("begin_replay_checkpoint_capture")
    var atmosphere := {
        "rain": 0.0,
        "atmosphere": _json_safe(native.call("wind_configuration")),
        "atmosphere_air_density_kg_m3": float(native.call("body_drag_configuration").air_density_kg_m3),
    }
    var error := _expect_ok(native.call("record_replay_environment", 0, JSON.stringify(atmosphere)), "initial environment")
    if not error.is_empty():
        return _failure(error)
    if not native.call("arm_flight_control", 0.0) or not lower_native.call("arm_flight_control", 0.0):
        return _failure("distinct native replay controllers did not arm")
    var initial_row: PackedFloat64Array = native.call("step_angle_mode", 240, 1000, 0.65, 2.0, -1.0, 5.0)
    var lower_row: PackedFloat64Array = lower_native.call(
        "step_collision_angle_mode", 240, 1000, 0.70, -2.0, 1.0, -5.0,
        true, 0.0, 1.0, 0.0, 0.0, 2.0, 0.0, 0.25,
        1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0)
    native.call("capture_replay_recorded_response", true)
    lower_native.call("capture_replay_recorded_response", true)
    if initial_row.size() != 12 or lower_row.is_empty():
        return _failure("distinct native replay steps failed")
    error = _expect_ok(native.call("record_replay_command", 0, "DroneA", 0.65, 2.0, -1.0, 5.0, 0), "upper command")
    if not error.is_empty():
        return _failure(error)
    error = _expect_ok(native.call("record_replay_command", 0, "DroneB", 0.70, -2.0, 1.0, -5.0, 0), "lower command")
    if not error.is_empty():
        return _failure(error)
    error = _expect_ok(native.call(
        "record_replay_collision", 2000, "DroneB", true,
        0.0, 1.0, 0.0, 0.0, 2.0, 0.0, 0.25,
        1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, true, 1), "collision")
    if not error.is_empty():
        return _failure(error)
    error = _expect_ok(native.call("record_replay_simulation_operation", 2000, 2, 1.0), "step")
    if not error.is_empty():
        return _failure(error)
    error = _expect_ok(native.call("record_replay_scene_object", 2000, 0, "crate", "primitive_box", Vector3(1.0, 2.0, 3.0), Quaternion.IDENTITY), "scene")
    if not error.is_empty():
        return _failure(error)
    error = _expect_ok(native.call("record_replay_checkpoint", 2500, initial_row, lower_row, lower_native), "stepped checkpoint")
    if not error.is_empty():
        return _failure(error)
    atmosphere["rain"] = 0.25
    error = _expect_ok(native.call("record_replay_environment", 3000, JSON.stringify(atmosphere)), "environment")
    if not error.is_empty():
        return _failure(error)
    error = _expect_ok(native.call("record_replay_simulation_operation", 4000, 1, 0.0), "resume")
    if not error.is_empty():
        return _failure(error)
    var finish: Dictionary = native.call("finish_complete_replay_recording", 5000, "integration")
    if not bool(finish.get("ok", false)):
        return _failure("replay recording did not finish: %s" % String(finish.get("diagnostic_message", "unknown")))
    var config_manifest: Dictionary = native.call("replay_vehicle_config_manifest")
    var replay: Dictionary = native.call(
        "replay_complete_session", finish.serialized, SETTINGS_HASH, config_hash, config_hash,
        config_manifest, config_manifest)
    if not bool(replay.get("ok", false)) or int(replay.get("scene_object_count", 0)) != 1 or String(replay.get("environment_json", "")).find("rain") < 0:
        return _failure("native replay failed: %s expected=%s actual=%s" % [String(replay.get("diagnostic_message", "unknown")), String(replay.get("divergence_expected", "")), String(replay.get("divergence_actual", ""))])
    var altered_manifest: Dictionary = JSON.parse_string(finish.serialized)
    if int(altered_manifest.get("schema_version", 0)) != 3:
        return _failure("replay recording did not emit schema v3")
    var checkpoints: Array = altered_manifest.get("checkpoints", [])
    if checkpoints.is_empty():
        return _failure("replay recording did not emit a checkpoint")
    var checkpoint: Dictionary = checkpoints[0]
    var controllers: Array = checkpoint.get("controllers", [])
    var clocks: Array = checkpoint.get("clocks", [])
    var responses: Array = checkpoint.get("first_response_substeps", [])
    var collisions: Array = checkpoint.get("collisions", [])
    var scene_objects: Array = checkpoint.get("scene_objects", [])
    if controllers.size() != 2 or clocks.size() != 2 or responses.size() != 2 or collisions.size() != 2 or scene_objects.size() != 1 \
            or not bool((collisions[1] as Dictionary).get("touching", false)) or String((scene_objects[0] as Dictionary).get("name", "")) != "crate":
        return _failure("schema-v3 checkpoint state is incomplete")
    for vehicle_index in range(2):
        var controller: Dictionary = controllers[vehicle_index]
        var response: Dictionary = responses[vehicle_index]
        var response_state: Dictionary = response.get("state", {})
        for field in ["target_angle", "target_rate", "integral", "previous_error", "derivative", "mode", "initialized", "motor_latches", "pid_latches", "motor_total"]:
            if not controller.has(field):
                return _failure("schema-v3 controller checkpoint field is missing: %s" % field)
        if not clocks[vehicle_index].has("substep_accumulator") or not clocks[vehicle_index].has("total_substeps") or \
                not response_state.has("motor_thrust") or not response_state.has("propwash"):
            return _failure("schema-v3 clock, motor, or first-response state is missing")
    altered_manifest["vehicles"][0]["config"]["mass_kg"] = 1.25
    var strict_manifest_rejection: Dictionary = native.call(
        "replay_complete_session", JSON.stringify(altered_manifest), SETTINGS_HASH, config_hash, config_hash,
        config_manifest, config_manifest)
    if bool(strict_manifest_rejection.get("ok", true)) or int(strict_manifest_rejection.get("diagnostic_code", 0)) == 0:
        return _failure("altered vehicle manifest was not rejected")
    var altered_serialized: String = finish.serialized.replace("\"throttle\":0.65", "\"throttle\":0.75")
    var divergence: Dictionary = native.call(
        "compare_complete_replay_sessions", finish.serialized, altered_serialized, SETTINGS_HASH)
    if not bool(divergence.get("ok", false)) or not bool(divergence.get("diverged", false)) or String(divergence.get("field", "")) != "command.throttle":
        return _failure("replay divergence report failed: %s" % String(divergence.get("diagnostic_message", "unknown")))
    return {"ok": true}


func _hash(value: String) -> String:
    var context := HashingContext.new()
    if context.start(HashingContext.HASH_SHA256) != OK:
        return ""
    context.update(value.to_utf8_buffer())
    return context.finish().hex_encode()


func _json_safe(value: Variant) -> Variant:
    if value is Vector3:
        return [value.x, value.y, value.z]
    if value is Dictionary:
        var result: Dictionary = {}
        for key in value:
            result[key] = _json_safe(value[key])
        return result
    if value is Array:
        var result: Array = []
        for item in value:
            result.append(_json_safe(item))
        return result
    return value


func _expect_ok(result: Dictionary, label: String) -> String:
    if not bool(result.get("ok", false)):
        return "%s failed: %s" % [label, String(result.get("diagnostic_message", "unknown"))]
    return ""


func _failure(message: String) -> Dictionary:
    return {"ok": false, "error": message}
