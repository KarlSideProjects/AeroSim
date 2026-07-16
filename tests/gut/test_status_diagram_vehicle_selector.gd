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


func _live_snapshot(vehicle_name: String, timestamp_us: int) -> Dictionary:
    var snapshot := _snapshot(vehicle_name, "ANGLE")
    snapshot.merge({
        "schema_version": 1,
        "timestamp_us": timestamp_us,
        "publish_count": 30,
        "snapshot_hz": 30.0,
        "source": "native_double_buffer",
    })
    return snapshot


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


func test_dashboard_supports_compact_and_full_layouts() -> void:
    var dashboard := StatusDiagramDebug.new()
    autofree(dashboard)
    dashboard._ready()

    assert_eq(dashboard.get_layout_mode(), "compact")
    dashboard.set_layout_mode("full")
    assert_eq(dashboard.get_layout_mode(), "full")
    dashboard.set_layout_mode("compact")
    assert_eq(dashboard.get_layout_mode(), "compact")


func test_dashboard_marks_snapshot_freshness_and_reports_rate_and_latency() -> void:
    var dashboard := StatusDiagramDebug.new()
    autofree(dashboard)
    dashboard._ready()
    dashboard.set_vehicle_names(["DroneA", "DroneB"])

    dashboard.set_vehicle_snapshots({"DroneA": _live_snapshot("DroneA", 1_000_000)}, "DroneA", 1_020_000)
    assert_eq(String(dashboard.debug_values.get("connection_state", "")), "live")
    assert_eq(float(dashboard.debug_values.get("update_rate_hz", 0.0)), 30.0)
    assert_eq(float(dashboard.debug_values.get("latency_ms", 0.0)), 20.0)

    assert_true(dashboard.select_vehicle("DroneB"))
    assert_eq(String(dashboard.debug_values.get("connection_state", "")), "disconnected")

    dashboard.set_vehicle_snapshots({"DroneA": _live_snapshot("DroneA", 1_000_000)}, "DroneA", 1_200_001)
    assert_eq(String(dashboard.debug_values.get("connection_state", "")), "stale")
