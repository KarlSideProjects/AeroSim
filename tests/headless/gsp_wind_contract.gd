extends SceneTree

const EnvironmentState = preload("res://common/rpc/environment_state.gd")
const FlightRuntime = preload("res://common/flight/flight_runtime.gd")
const GspServer = preload("res://common/gsp/gsp_server.gd")

var failures: Array[String] = []

func _init() -> void:
    var valid := GspServer.validate_set_wind_message(JSON.stringify({"v": 2, "t": "set_wind", "seq": 1, "d": {"wind_from_deg": 0.0, "speed_mps": 5.0}}), 0)
    _expect(bool(valid.get("ok", false)), "bounded meteorological wind request is accepted")
    _expect(not bool(GspServer.validate_set_wind_message(JSON.stringify({"v": 2, "t": "set_wind", "seq": 1, "d": {"wind_from_deg": 360.0, "speed_mps": 5.0}}), 0).get("ok", false)), "out-of-domain bearing is rejected before mutation")
    var runtime := FlightRuntime.new()
    runtime.environment_state = EnvironmentState.new()
    runtime._active_hardware_configuration = {"environment": {"wind_speed_mps": {"max": 10.0}}}
    var before: Dictionary = runtime.environment_state.snapshot()
    var pending: Dictionary = runtime.gsp_wind_request(7, 9, 11, 0.0, 5.0)
    _expect(bool(pending.get("pending", false)) and runtime.environment_state.snapshot() == before, "preview/request state does not mutate environment before the physics boundary")
    runtime._apply_gsp_wind_requests(42)
    var results: Array = runtime.gsp_wind_results()
    var applied: Dictionary = results[0] if not results.is_empty() else {}
    var wind: Vector3 = runtime.environment_state.snapshot().steady_wind
    _expect(bool(applied.get("ok", false)) and int(applied.get("request_seq", -1)) == 11 and int(applied.get("applied_tick", -1)) == 42 and wind.is_equal_approx(Vector3(-5.0, 0.0, 0.0)), "north-from resolves south NED and returns correlated applied tick")
    var calm := runtime.gsp_wind_request(7, 9, 12, 90.0, 0.0)
    runtime._apply_gsp_wind_requests(43)
    _expect(bool(calm.get("pending", false)) and runtime.environment_state.snapshot().steady_wind == Vector3.ZERO, "zero speed remains true calm")
    var rejected := runtime.gsp_wind_request(7, 9, 13, 0.0, 10.1)
    _expect(not bool(rejected.get("ok", false)) and runtime.environment_state.snapshot().steady_wind == Vector3.ZERO, "qualified speed domain rejects without mutation")
    if failures.is_empty():
        print("GSP wind contract: PASS")
        quit(0)
    for failure in failures:
        push_error(failure)
    print("GSP wind contract: FAIL")
    quit(1)

func _expect(condition: bool, message: String) -> void:
    if not condition:
        failures.append(message)
