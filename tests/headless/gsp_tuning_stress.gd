extends SceneTree

const AirSimSession = preload("res://common/rpc/airsim_session.gd")
const FlightRuntime = preload("res://common/flight/flight_runtime.gd")
const HardwareConfig = preload("res://common/flight/hardware_config.gd")

var _failures: Array[String] = []


func _init() -> void:
    await _run()


func _run() -> void:
    var runtime := FlightRuntime.new()
    runtime.native = ClassDB.instantiate("AeroSimNative")
    runtime.airsim_session = AirSimSession.new(240)
    var hardware := HardwareConfig.new()
    runtime._gsp_tuning_registry = hardware.tuning_registry()
    runtime._gsp_tuning_registry_hash = hardware.tuning_registry_hash()
    _expect(hardware.initialize_tuning(runtime), "stress runtime initializes the canonical tuning registry")
    runtime.paused = false
    var max_pending := 0
    var max_results := 0
    for second in 30:
        for message_index in 50:
            var value := 0.6 + float(second * 50 + message_index) / 2000.0
            runtime.gsp_tuning_request(1, 1, second * 50 + message_index + 1, "simpleflight.rate_p", value)
        max_pending = maxi(max_pending, runtime._gsp_tuning_pending.size())
        for _frame in 8:
            runtime._physics_process(1.0 / 240.0)
            max_results = maxi(max_results, runtime._gsp_tuning_completed.size())
            runtime.gsp_tuning_results()
    runtime.gsp_tuning_request(1, 1, 1501, "simpleflight.rate_p", 1.75)
    runtime._physics_process(1.0 / 240.0)
    runtime.gsp_tuning_results()
    var active: Dictionary = runtime.native.call("flight_tuning_configuration")
    var diagnostics: Dictionary = runtime.native.call("flight_control_diagnostics")
    _expect(float(active.get("simpleflight.rate_p", 0.0)) == 1.75, "stress run commits its final drag value")
    _expect(is_finite(float(active.get("simpleflight.rate_p", NAN))) and
            is_finite(float(diagnostics.get("angular_velocity_x_rad_s", NAN))) and
            is_finite(float(diagnostics.get("angular_velocity_y_rad_s", NAN))) and
            is_finite(float(diagnostics.get("angular_velocity_z_rad_s", NAN))),
            "stress run leaves finite native state")
    _expect(max_pending <= 50 and max_results <= 50 and runtime._gsp_tuning_recent_results.size() <= 16,
            "stress run keeps pending, result, and recent replay-related queues bounded")
    if _failures.is_empty():
        print("GSP tuning stress: PASS")
        quit(0)
        return
    for failure in _failures:
        push_error(failure)
    print("GSP tuning stress: FAIL")
    quit(1)


func _expect(condition: bool, message: String) -> void:
    if not condition:
        _failures.append(message)
