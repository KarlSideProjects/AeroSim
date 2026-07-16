extends GutTest

const StatusDiagramDebug = preload("res://common/flight/status_diagram_debug.gd")


func _snapshot(vehicle_name: String, mode: String) -> Dictionary:
    return {
        "vehicle_name": vehicle_name,
        "mode": mode,
        "motors": [],
        "battery": {},
        "wind_body_mps": Vector3.ZERO,
        "pid": [],
    }


func test_vehicle_selector_switches_dashboard_state_to_selected_snapshot() -> void:
    var dashboard := StatusDiagramDebug.new()
    autofree(dashboard)
    dashboard._ready()

    dashboard.set_vehicle_snapshots({
        "DroneA": _snapshot("DroneA", "ANGLE"),
        "DroneB": _snapshot("DroneB", "ACRO"),
    }, "DroneA")
    assert_eq(dashboard.get_selected_vehicle_name(), "DroneA")
    assert_eq(String(dashboard.debug_values.get("vehicle_name", "")), "DroneA")

    assert_true(dashboard.select_vehicle("DroneB"))
    assert_eq(dashboard.get_selected_vehicle_name(), "DroneB")
    assert_eq(String(dashboard.debug_values.get("vehicle_name", "")), "DroneB")
    assert_eq(String(dashboard.debug_values.get("mode", "")), "ACRO")
