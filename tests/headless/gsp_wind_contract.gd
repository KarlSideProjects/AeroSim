extends SceneTree

const EnvironmentState = preload("res://common/rpc/environment_state.gd")
const FlightRuntime = preload("res://common/flight/flight_runtime.gd")
const GspServer = preload("res://common/gsp/gsp_server.gd")

var failures: Array[String] = []

class FakeNative extends Node:
    var config := {
        "preset": "calm", "steady_wind": Vector3.ZERO,
        "turbulence_sigma": Vector3(1.0, 2.0, 3.0), "shear_enabled": true, "seed": 17,
    }
    var replay_environment_event_count := 0
    var replay_environment_tick := 0
    var external_authority_updates: Array[bool] = []

    func wind_configuration() -> Dictionary:
        return config.duplicate(true)

    func configure_wind(next: Dictionary) -> void:
        config = next.duplicate(true)

    func record_replay_environment(timestamp_us: int, _state_json: String) -> Dictionary:
        var identity := {
            "timestamp_us": timestamp_us,
            "physics_tick": replay_environment_tick,
            "event_order": replay_environment_event_count,
            "type": "environment",
        }
        replay_environment_event_count += 1
        return {"ok": true, "event_identity": identity}

    func set_external_authority_active(active: bool) -> void:
        external_authority_updates.append(active)


func _init() -> void:
    var valid := GspServer.validate_set_wind_message(JSON.stringify({"v": 2, "t": "set_wind", "seq": 1, "d": {"wind_from_deg": 0.0, "speed_mps": 5.0}}), 0)
    _expect(bool(valid.get("ok", false)), "bounded meteorological wind request is accepted")
    _expect(not bool(GspServer.validate_set_wind_message(JSON.stringify({"v": 2, "t": "set_wind", "seq": 1, "d": {"wind_from_deg": 360.0, "speed_mps": 5.0}}), 0).get("ok", false)), "out-of-domain bearing is rejected before mutation")
    _expect(not bool(GspServer.validate_set_wind_message(JSON.stringify({"v": 2, "t": "set_wind", "seq": 1, "d": {"wind_from_deg": 0.0, "speed_mps": 5.0}}), 1).get("ok", false)), "stale wind sequence is rejected before provider mutation")
    var runtime := FlightRuntime.new()
    runtime.environment_state = EnvironmentState.new()
    runtime.native = FakeNative.new()
    runtime._active_hardware_configuration = {"environment": {"wind_speed_mps": {"max": 10.0}}}
    var authority_bridge := preload("res://common/rpc/px4_sitl_bridge.gd").new()
    authority_bridge.configure({"Transport": "Fake", "UseSerial": false, "LockStep": true}, Callable(runtime, "_on_px4_authority_changed"))
    runtime.px4_sitl_bridge = authority_bridge
    authority_bridge._set_state("armed", true, "test armed authority")
    _expect(runtime.native.external_authority_updates == [true], "armed PX4 authority transitions directly into native authority at the bridge boundary")
    authority_bridge._set_state("stale", false, "test stale authority")
    _expect(runtime.native.external_authority_updates == [true, false], "stale PX4 authority clears native authority at the same bridge boundary")
    runtime.px4_sitl_bridge = null
    var before: Dictionary = runtime.environment_state.snapshot()
    var pending: Dictionary = runtime.gsp_wind_request(7, 9, 11, 0.0, 5.0)
    _expect(bool(pending.get("pending", false)) and runtime.environment_state.snapshot() == before, "preview/request state does not mutate environment before the physics boundary")
    runtime._apply_gsp_wind_requests(42)
    var results: Array = runtime.gsp_wind_results()
    var applied: Dictionary = results[0] if not results.is_empty() else {}
    var wind: Vector3 = runtime.environment_state.snapshot().steady_wind
    _expect(bool(applied.get("ok", false)) and int(applied.get("request_seq", -1)) == 11 and int(applied.get("applied_tick", -1)) == 42 and wind.is_equal_approx(Vector3(-5.0, 0.0, 0.0)), "north-from resolves south NED and returns correlated applied tick")
    _expect(runtime.native.config.turbulence_sigma == Vector3(1.0, 2.0, 3.0) and bool(runtime.native.config.shear_enabled) and int(runtime.native.config.seed) == 17, "steady-wind apply retains deterministic advanced Dryden/shear configuration")
    var calm := runtime.gsp_wind_request(7, 9, 12, 90.0, 0.0)
    runtime._apply_gsp_wind_requests(43)
    _expect(bool(calm.get("pending", false)) and runtime.environment_state.snapshot().steady_wind == Vector3.ZERO, "zero speed remains true calm")
    var rejected := runtime.gsp_wind_request(7, 9, 13, 0.0, 10.1)
    _expect(not bool(rejected.get("ok", false)) and runtime.environment_state.snapshot().steady_wind == Vector3.ZERO, "qualified speed domain rejects without mutation")
    runtime._replay_recording_active = true
    runtime._replay_authoritative_physics_tick = 73
    runtime.native.replay_environment_tick = 73
    runtime.gsp_wind_request(7, 9, 14, 180.0, 4.0)
    runtime._apply_gsp_wind_requests(44)
    var recorded_results: Array = runtime.gsp_wind_results()
    var recorded_result: Dictionary = recorded_results.back() if not recorded_results.is_empty() else {}
    var replay_identity: Dictionary = recorded_result.get("replay_event_identity", {})
    _expect(bool(recorded_result.get("ok", false)) and int(recorded_result.get("applied_tick", -1)) == 73 and int(recorded_result.get("public_applied_tick", -1)) == 44 and int(replay_identity.get("physics_tick", -1)) == 73 and int(replay_identity.get("event_order", -1)) >= 0 and String(replay_identity.get("type", "")) == "environment", "successful wind ACK exposes the native recorder event identity at its authoritative tick")
    runtime._replay_recording_active = true
    runtime._replay_recording_failed = true
    runtime._replay_recording_failure = "forced replay failure"
    var replay_before: Dictionary = runtime.environment_state.snapshot()
    var replay_wind_before: Dictionary = runtime.native.wind_configuration()
    runtime.gsp_wind_request(7, 9, 15, 180.0, 4.0)
    runtime._apply_gsp_wind_requests(44)
    var replay_results: Array = runtime.gsp_wind_results()
    var replay_result: Dictionary = replay_results.back() if not replay_results.is_empty() else {}
    _expect(not bool(replay_result.get("ok", false)) and String(replay_result.get("error", "")) == "replay_recording_failed" and runtime.environment_state.snapshot() == replay_before and runtime.native.wind_configuration() == replay_wind_before, "replay recording failure rejects wind and restores every mutated boundary")
    if failures.is_empty():
        print("GSP wind contract: PASS")
        quit(0)
        return
    for failure in failures:
        push_error(failure)
    print("GSP wind contract: FAIL")
    quit(1)

func _expect(condition: bool, message: String) -> void:
    if not condition:
        failures.append(message)
