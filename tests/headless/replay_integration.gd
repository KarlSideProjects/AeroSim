extends SceneTree

const SETTINGS_HASH := "integration-settings-v1"


func _initialize() -> void:
    var native: Object = ClassDB.instantiate("AeroSimNative")
    if native == null:
        _fail("AeroSimNative is not registered")
        return
    if not native.call("set_hardware_mass_kg", 1.0):
        _fail("native mass setup failed")
        return
    if not native.call("set_hardware_power_model", 4.0, 0.5, 0.03, 22.2, 6.0, 0.003, 4.0):
        _fail("native power setup failed")
        return
    if not native.call("set_hardware_telemetry_model", 10000.0, 1000.0):
        _fail("native telemetry setup failed")
        return
    var per_motor := {
        "inertia_frd": Vector3(0.01, 0.01, 0.02),
        "position_frd": [Vector3(-0.1, 0.1, 0.0), Vector3(0.1, 0.1, 0.0), Vector3(-0.1, -0.1, 0.0), Vector3(0.1, -0.1, 0.0)],
        "spin_direction": [1.0, -1.0, -1.0, 1.0],
        "max_thrust_per_motor_newtons": 1.0,
        "max_current_per_motor_a": 1.0,
        "yaw_torque_per_newton": 0.01,
    }
    if not native.call("set_hardware_per_motor_model", per_motor):
        _fail("native per-motor setup failed")
        return
    var config_json := JSON.stringify(_json_safe(native.call("replay_vehicle_config_manifest")))
    var config_hash := _hash(config_json)
    var begin: Dictionary = native.call(
        "begin_complete_replay_recording", 7, SETTINGS_HASH,
        "DroneA", config_hash, config_json, 0,
        "DroneB", config_hash, config_json, 0)
    if not bool(begin.get("ok", false)):
        _fail("replay recording did not start: %s" % String(begin.get("diagnostic_message", "unknown")))
        return
    var initial_row := PackedFloat64Array([0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0])
    _expect_ok(native.call("record_replay_command", 0, "DroneA", 0.55, 0.0, 0.0, 0.0, 0), "upper command")
    _expect_ok(native.call("record_replay_command", 0, "DroneB", 0.50, 0.0, 0.0, 0.0, 0), "lower command")
    _expect_ok(native.call("record_replay_checkpoint", 0, initial_row, initial_row), "initial checkpoint")
    _expect_ok(native.call("record_replay_simulation_operation", 0, 0, 0.0), "pause")
    _expect_ok(native.call("record_replay_simulation_operation", 2000, 2, 0.0), "step")
    _expect_ok(native.call("record_replay_scene_object", 2000, 0, "crate", "primitive_box", Vector3(1.0, 2.0, 3.0), Quaternion.IDENTITY), "scene")
    _expect_ok(native.call("record_replay_environment", 3000, "{\"rain\":0.25}"), "environment")
    _expect_ok(native.call("record_replay_simulation_operation", 4000, 1, 0.0), "resume")
    var finish: Dictionary = native.call("finish_complete_replay_recording", 5000, "integration")
    if not bool(finish.get("ok", false)):
        _fail("replay recording did not finish: %s" % String(finish.get("diagnostic_message", "unknown")))
        return
    var config_manifest: Dictionary = native.call("replay_vehicle_config_manifest")
    var replay: Dictionary = native.call(
        "replay_complete_session", finish.serialized, SETTINGS_HASH, config_hash, config_hash,
        config_manifest, config_manifest)
    if not bool(replay.get("ok", false)) or int(replay.get("scene_object_count", 0)) != 1 or String(replay.get("environment_json", "")).find("rain") < 0:
        _fail("native replay failed: %s" % String(replay.get("diagnostic_message", "unknown")))
        return
    var altered_manifest: Dictionary = JSON.parse_string(finish.serialized)
    altered_manifest["vehicles"][0]["config"]["mass_kg"] = 1.25
    var strict_manifest_rejection: Dictionary = native.call(
        "replay_complete_session", JSON.stringify(altered_manifest), SETTINGS_HASH, config_hash, config_hash,
        config_manifest, config_manifest)
    if bool(strict_manifest_rejection.get("ok", true)) or int(strict_manifest_rejection.get("diagnostic_code", 0)) == 0:
        _fail("altered vehicle manifest was not rejected")
        return
    var altered_serialized: String = finish.serialized.replace("\"throttle\":0.55", "\"throttle\":0.65")
    var divergence: Dictionary = native.call(
        "compare_complete_replay_sessions", finish.serialized, altered_serialized, SETTINGS_HASH)
    if not bool(divergence.get("ok", false)) or not bool(divergence.get("diverged", false)) or String(divergence.get("field", "")) != "command.throttle":
        _fail("replay divergence report failed: %s" % String(divergence.get("diagnostic_message", "unknown")))
        return
    var altered_checkpoint_serialized: String = finish.serialized.replace("\"position\":[0,0,0]", "\"position\":[0.25,0,0]")
    var checkpoint_divergence: Dictionary = native.call(
        "replay_complete_session", altered_checkpoint_serialized, SETTINGS_HASH, config_hash, config_hash,
        config_manifest, config_manifest)
    if bool(checkpoint_divergence.get("ok", true)) or not bool(checkpoint_divergence.get("diverged", false)) or String(checkpoint_divergence.get("divergence_field", "")) != "upper.position.x":
        _fail("replay checkpoint divergence was not rejected")
        return
    _pass()


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


func _expect_ok(result: Dictionary, label: String) -> void:
    if not bool(result.get("ok", false)):
        _fail("%s failed: %s" % [label, String(result.get("diagnostic_message", "unknown"))])


func _pass() -> void:
    print("complete-session replay integration: PASS")
    quit(0)


func _fail(message: String) -> void:
    push_error(message)
    quit(1)
