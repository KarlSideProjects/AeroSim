extends GutTest

const StatusDiagramDebug = preload("res://common/flight/status_diagram_debug.gd")
const Localization = preload("res://common/flight/localization.gd")
const FlightRuntime = preload("res://common/flight/flight_runtime.gd")


func after_each() -> void:
    Localization.set_locale("en")


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
    assert_true(dashboard._dashboard_panel.custom_minimum_size.x >= 420.0)
    assert_true(dashboard._dashboard_margin.offset_left <= -436.0)
    dashboard.set_layout_mode("full")
    assert_eq(dashboard.get_layout_mode(), "full")
    assert_true(dashboard._dashboard_panel.custom_minimum_size.x >= 520.0)
    assert_true(dashboard._dashboard_margin.offset_left <= -536.0)
    dashboard.set_layout_mode("compact")
    assert_eq(dashboard.get_layout_mode(), "compact")


func test_dashboard_geometry_fits_supported_headed_viewports() -> void:
    var dashboard := StatusDiagramDebug.new()
    autofree(dashboard)
    dashboard._ready()
    for viewport_size in [Vector2(1280, 720), Vector2(1280, 800), Vector2(1920, 1080)]:
        var compact_size := Vector2(absf(dashboard._dashboard_margin.offset_left), dashboard._dashboard_margin.offset_bottom)
        assert_true(compact_size.x <= viewport_size.x and compact_size.y <= viewport_size.y)
    dashboard.set_layout_mode("full")
    for viewport_size in [Vector2(1280, 720), Vector2(1280, 800), Vector2(1920, 1080)]:
        var full_size := Vector2(absf(dashboard._dashboard_margin.offset_left), dashboard._dashboard_margin.offset_bottom)
        assert_true(full_size.x <= viewport_size.x and full_size.y <= viewport_size.y)


func test_dashboard_marks_snapshot_freshness_and_reports_rate_and_latency() -> void:
    var dashboard := StatusDiagramDebug.new()
    autofree(dashboard)
    dashboard._ready()
    dashboard.set_vehicle_names(["DroneA", "DroneB"])

    dashboard.set_vehicle_snapshots({"DroneA": _live_snapshot("DroneA", 1_000_000)}, "DroneA", 10_000_000)
    assert_eq(String(dashboard.debug_values.get("connection_state", "")), "live")
    assert_eq(float(dashboard.debug_values.get("update_rate_hz", 0.0)), 30.0)
    assert_eq(float(dashboard.debug_values.get("latency_ms", 0.0)), 0.0)

    assert_true(dashboard.select_vehicle("DroneB"))
    assert_eq(String(dashboard.debug_values.get("connection_state", "")), "disconnected")

    dashboard.set_vehicle_snapshots({"DroneA": _live_snapshot("DroneA", 1_000_000)}, "DroneA", 10_120_001)
    assert_eq(String(dashboard.debug_values.get("connection_state", "")), "stale")
    assert_gt(float(dashboard.debug_values.get("latency_ms", 0.0)), 100.0)


func test_single_unnamed_snapshot_still_updates_dashboard() -> void:
    var dashboard := StatusDiagramDebug.new()
    autofree(dashboard)
    dashboard._ready()

    dashboard.set_vehicle_snapshots({"": _live_snapshot("", 1_000_000)}, "", 10_000_000)
    assert_eq(String(dashboard.debug_values.get("source", "")), "native_double_buffer")
    assert_eq(int(dashboard.debug_values.get("timestamp_us", 0)), 1_000_000)
    assert_eq(String(dashboard.debug_values.get("connection_state", "")), "live")

    dashboard.set_vehicle_snapshots({"": _live_snapshot("", 1_000_000)}, "", 10_120_001)
    assert_eq(String(dashboard.debug_values.get("connection_state", "")), "stale")


func test_dashboard_localizes_dynamic_status_words() -> void:
    var dashboard := StatusDiagramDebug.new()
    autofree(dashboard)
    dashboard._ready()
    dashboard.set_locale("zh_TW")

    dashboard.set_vehicle_snapshots({"DroneA": _live_snapshot("DroneA", 1_000_000)}, "DroneA", 1_000_000)

    assert_string_contains(dashboard._labels.status.text, "即時")
    assert_string_contains(dashboard._labels.mode.text, "解鎖")
    assert_string_contains(dashboard._labels.mode.text, "模式")
    assert_false(dashboard._labels.status.text.contains("LIVE"))
    assert_false(dashboard._labels.mode.text.contains("ARM"))
    assert_false(dashboard._labels.mode.text.contains("MODE"))


func test_unknown_dashboard_mode_is_catalog_backed() -> void:
    var dashboard := StatusDiagramDebug.new()
    autofree(dashboard)
    dashboard._ready()
    dashboard.set_locale("zh_TW")

    var snapshot := _snapshot("DroneA", "UNSUPPORTED_RUNTIME_MODE")
    dashboard.set_vehicle_snapshots({"DroneA": snapshot}, "DroneA")

    assert_string_contains(dashboard._labels.mode.text, "未知模式")
    assert_false(dashboard._labels.mode.text.contains("UNSUPPORTED_RUNTIME_MODE"))


func test_px4_unavailable_authority_fields_are_not_rendered_as_disarmed_or_unsaturated() -> void:
    var dashboard := StatusDiagramDebug.new()
    autofree(dashboard)
    dashboard._ready()
    var snapshot := _live_snapshot("DroneA", 1_000_000)
    snapshot.merge({
        "mode": "PX4_ACTUATOR",
        "armed": null,
        "armed_available": false,
        "pid": [{"output": null, "saturated": null}],
        "pid_available": false,
    })

    dashboard.update_from_snapshot(snapshot, 1_000_000)

    assert_string_contains(dashboard._labels.mode.text, "UNAVAILABLE")
    assert_false(dashboard._labels.mode.text.contains("ARM OFF"))
    assert_string_contains(dashboard._labels.pid.text, "UNAVAILABLE")


func test_motor_hud_uses_physical_nose_up_order_and_converts_radians_to_rpm() -> void:
    var dashboard := StatusDiagramDebug.new()
    autofree(dashboard)
    dashboard._ready()
    var snapshot := _live_snapshot("DroneA", 1_000_000)
    snapshot["motors"] = [
        {"thrust_newtons": 1.0, "speed_rad_s": 10.0, "current_a": 2.0}, # RR
        {"thrust_newtons": 2.0, "speed_rad_s": 20.0, "current_a": 3.0}, # FR
        {"thrust_newtons": 3.0, "speed_rad_s": 30.0, "current_a": 4.0}, # RL
        {"thrust_newtons": 4.0, "speed_rad_s": 20.0 * PI, "current_a": 5.0, "saturated": true}, # FL
    ]

    dashboard.update_from_snapshot(snapshot, 1_000_000)
    var motor_hud: Dictionary = dashboard.get_motor_hud_state(false, "")

    assert_eq(motor_hud.state, "live")
    assert_eq(motor_hud.cells.map(func(cell: Dictionary) -> String: return cell.label), ["FL", "FR", "RL", "RR"])
    assert_string_contains(String(motor_hud.cells[0].text), "4.00 N")
    assert_string_contains(String(motor_hud.cells[0].text), "600 RPM")
    assert_string_contains(String(motor_hud.cells[0].text), "5.00 A")
    assert_string_contains(String(motor_hud.cells[0].text), "SAT")


func test_motor_hud_rejects_invalid_stale_paused_and_error_values() -> void:
    var dashboard := StatusDiagramDebug.new()
    autofree(dashboard)
    dashboard._ready()
    var snapshot := _live_snapshot("DroneA", 1_000_000)
    snapshot["motors"] = [
        {"thrust_newtons": 1.0, "speed_rad_s": 2.0, "current_a": 3.0},
        {"thrust_newtons": 1.0, "speed_rad_s": 2.0, "current_a": 3.0},
        {"thrust_newtons": 1.0, "speed_rad_s": INF, "current_a": 3.0},
        {"thrust_newtons": 1.0, "speed_rad_s": 2.0, "current_a": 3.0},
    ]
    dashboard.update_from_snapshot(snapshot, 1_000_000)
    var invalid: Dictionary = dashboard.get_motor_hud_state(false, "")
    assert_eq(invalid.state, "unavailable")
    assert_string_contains(String(invalid.cells[0].text), "UNAVAILABLE")

    snapshot["motors"] = [{}, {}, {}]
    dashboard.update_from_snapshot(snapshot, 1_000_000)
    assert_eq(dashboard.get_motor_hud_state(false, "").reason, "incomplete")
    snapshot["motors"] = "bad"
    dashboard.update_from_snapshot(snapshot, 1_000_000)
    assert_eq(dashboard.get_motor_hud_state(false, "").reason, "malformed")

    snapshot["motors"] = [
        {"thrust_newtons": 1.0, "speed_rad_s": 2.0, "current_a": 3.0},
        {"thrust_newtons": 1.0, "speed_rad_s": 2.0, "current_a": 3.0},
        {"thrust_newtons": 1.0, "speed_rad_s": 2.0, "current_a": 3.0},
        {"thrust_newtons": 1.0, "speed_rad_s": 2.0, "current_a": 3.0},
    ]
    snapshot["motors"][2]["speed_rad_s"] = 2.0
    dashboard.update_from_snapshot(snapshot, 1_000_000)
    dashboard.update_from_snapshot(snapshot, 1_120_001)
    var stale: Dictionary = dashboard.get_motor_hud_state(false, "")
    assert_eq(stale.state, "unavailable")
    assert_eq(stale.reason, "stale")
    assert_eq(dashboard.get_motor_hud_state(true, "").state, "unavailable")
    assert_eq(dashboard.get_motor_hud_state(false, "AeroSimNative.step: InvalidState").state, "error")


func test_motor_hud_localizes_labels_and_saturation_marker() -> void:
    var dashboard := StatusDiagramDebug.new()
    autofree(dashboard)
    dashboard._ready()
    dashboard.set_locale("zh_TW")
    var snapshot := _live_snapshot("DroneA", 1_000_000)
    snapshot["motors"] = [
        {"thrust_newtons": 1.0, "speed_rad_s": 2.0, "current_a": 3.0, "saturated": true},
        {"thrust_newtons": 1.0, "speed_rad_s": 2.0, "current_a": 3.0},
        {"thrust_newtons": 1.0, "speed_rad_s": 2.0, "current_a": 3.0},
        {"thrust_newtons": 1.0, "speed_rad_s": 2.0, "current_a": 3.0},
    ]
    dashboard.update_from_snapshot(snapshot, 1_000_000)

    var motor_hud: Dictionary = dashboard.get_motor_hud_state(false, "")
    assert_string_contains(String(motor_hud.cells[3].text), "飽和")
    assert_string_contains(String(motor_hud.cells[3].text), "轉/分")


func test_dashboard_localizes_environment_after_locale_switch() -> void:
    var dashboard := StatusDiagramDebug.new()
    autofree(dashboard)
    dashboard._ready()
    dashboard.update_environment({
        "revision": 1,
        "weather_enabled": false,
        "rain": 0.0,
        "fog": 0.0,
        "time_of_day": 12.0,
        "sun_position": Vector3(0.0, 1.0, 0.0),
    })
    dashboard.set_locale("zh_TW")

    assert_string_contains(dashboard._labels.environment.text, "環境")
    assert_string_contains(dashboard._labels.environment.text, "就緒")
    assert_false(dashboard._labels.environment.text.contains("ENV"))
    assert_false(dashboard._labels.environment.text.contains("READY"))


func test_runtime_localizes_dynamic_hud_states() -> void:
    Localization.set_locale("zh_TW")
    var runtime := FlightRuntime.new()
    autofree(runtime)

    assert_eq(runtime._localized_arm_state(true), "已解鎖")
    assert_eq(runtime._localized_button_state(false), "放開")
    assert_eq(runtime._profile_input_status(), "油門低｜鍵盤設定檔")
    assert_eq(runtime._localized_flight_mode("UNSUPPORTED_RUNTIME_MODE"), "未知模式")
    assert_eq(runtime._localize_fallback_message("unclassified diagnostic"), "錯誤")
