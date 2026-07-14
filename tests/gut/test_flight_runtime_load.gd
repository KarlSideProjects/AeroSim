extends GutTest


func test_production_flight_runtime_script_loads_with_airsim_rpc_dependencies() -> void:
    var runtime_script := load("res://common/flight/flight_runtime.gd")

    assert_not_null(runtime_script)
