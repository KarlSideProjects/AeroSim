extends CanvasLayer

const Localization = preload("res://common/flight/localization.gd")

signal vehicle_selected(vehicle_name: String)

const MOTOR_KEYS := ["M1", "M2", "M3", "M4"]
const STALE_AFTER_US := 100_000

var debug_values: Dictionary = {}
var vehicle_snapshots: Dictionary = {}
var selected_vehicle_name := ""
var layout_mode := "compact"
var _vehicle_names: Array[String] = []
var _vehicle_selector: OptionButton
var _dashboard_panel: PanelContainer
var _dashboard_margin: MarginContainer
var _now_timestamp_us := -1
var _last_publish_counts: Dictionary = {}
var _last_publish_received_us: Dictionary = {}
var _labels := {}
var _heading: Label

func _ready() -> void:
    layer = 20
    name = "StatusDiagramDebug"
    var margin := MarginContainer.new()
    margin.name = "DashboardMargin"
    margin.set_anchors_preset(Control.PRESET_TOP_RIGHT)
    margin.offset_left = -436.0
    margin.offset_bottom = 260.0
    margin.add_theme_constant_override("margin_left", 8)
    margin.add_theme_constant_override("margin_top", 8)
    margin.add_theme_constant_override("margin_right", 8)
    margin.add_theme_constant_override("margin_bottom", 8)
    add_child(margin)
    _dashboard_margin = margin

    var panel := PanelContainer.new()
    panel.name = "DashboardPanel"
    panel.custom_minimum_size = Vector2(420.0, 284.0)
    margin.add_child(panel)
    _dashboard_panel = panel

    var rows := VBoxContainer.new()
    rows.add_theme_constant_override("separation", 4)
    panel.add_child(rows)

    var heading := Label.new()
    _heading = heading
    heading.text = _t("ui.dashboard.title")
    heading.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    rows.add_child(heading)

    _vehicle_selector = OptionButton.new()
    _vehicle_selector.name = "VehicleSelector"
    _vehicle_selector.tooltip_text = _t("ui.dashboard.vehicle_tooltip")
    _vehicle_selector.item_selected.connect(_on_vehicle_selector_item_selected)
    rows.add_child(_vehicle_selector)
    _add_label(rows, "status")
    _add_label(rows, "mode")
    for key in MOTOR_KEYS:
        _add_label(rows, key)
    _add_label(rows, "battery")
    _add_label(rows, "wind")
    _add_label(rows, "environment")
    _add_label(rows, "pid")
    _add_label(rows, "rate")
    _add_label(rows, "latency")
    _add_label(rows, "timestamp")
    _apply_layout()


func set_locale(locale: String) -> void:
    if not Localization.set_locale(locale):
        return
    if _heading != null:
        _heading.text = _t("ui.dashboard.title")
    if _vehicle_selector != null:
        _vehicle_selector.tooltip_text = _t("ui.dashboard.vehicle_tooltip")
    if not debug_values.is_empty():
        update_from_snapshot(debug_values, _now_timestamp_us)


func _t(key: String) -> String:
    return Localization.translate(key)


func _format(key: String, values: Array) -> String:
    return Localization.format(key, values)


func set_layout_mode(mode: String) -> bool:
    if mode not in ["compact", "full"]:
        return false
    layout_mode = mode
    _apply_layout()
    return true


func set_compact_mode(compact: bool) -> void:
    set_layout_mode("compact" if compact else "full")


func get_layout_mode() -> String:
    return layout_mode


func get_render_evidence() -> Dictionary:
    return {
        "visible": _dashboard_panel != null and _dashboard_panel.is_visible_in_tree(),
        "selector_visible": _vehicle_selector != null and _vehicle_selector.is_visible_in_tree(),
        "layout_mode": layout_mode,
        "selected_vehicle_name": selected_vehicle_name,
        "connection_state": String(debug_values.get("connection_state", "disconnected")),
        "timestamp_us": int(debug_values.get("timestamp_us", 0)),
    }


func set_vehicle_names(names: Array) -> void:
    _vehicle_names.clear()
    for name_variant in names:
        var name := String(name_variant)
        if not name.is_empty() and not _vehicle_names.has(name):
            _vehicle_names.append(name)
    if _vehicle_selector == null:
        return
    _vehicle_selector.clear()
    for name in _vehicle_names:
        _vehicle_selector.add_item(name)
    if _vehicle_names.is_empty():
        selected_vehicle_name = ""
        _vehicle_selector.disabled = true
        return
    _vehicle_selector.disabled = false
    if not _vehicle_names.has(selected_vehicle_name):
        selected_vehicle_name = _vehicle_names[0]
    _vehicle_selector.select(_vehicle_names.find(selected_vehicle_name))


func set_vehicle_snapshots(
        snapshots: Dictionary,
        preferred_vehicle_name: String = "",
        now_timestamp_us: int = -1) -> void:
    vehicle_snapshots = snapshots.duplicate(true)
    _now_timestamp_us = now_timestamp_us
    var names: Array = _vehicle_names.duplicate()
    for name in vehicle_snapshots.keys():
        var vehicle_name := String(name)
        if not names.has(vehicle_name):
            names.append(vehicle_name)
    set_vehicle_names(names)
    if _vehicle_names.is_empty():
        if not vehicle_snapshots.is_empty():
            update_from_snapshot(vehicle_snapshots[vehicle_snapshots.keys()[0]], now_timestamp_us)
        return
    var requested := preferred_vehicle_name if _vehicle_names.has(preferred_vehicle_name) else selected_vehicle_name
    if not select_vehicle(requested, false):
        select_vehicle(_vehicle_names[0], false)


func select_vehicle(vehicle_name: String, notify: bool = true) -> bool:
    if not _vehicle_names.has(vehicle_name):
        return false
    selected_vehicle_name = vehicle_name
    if _vehicle_selector != null:
        _vehicle_selector.select(_vehicle_names.find(vehicle_name))
    if vehicle_snapshots.has(vehicle_name):
        update_from_snapshot(vehicle_snapshots[vehicle_name], _now_timestamp_us)
    else:
        _set_disconnected(vehicle_name)
    if notify:
        vehicle_selected.emit(vehicle_name)
    return true


func get_selected_vehicle_name() -> String:
    return selected_vehicle_name


func _on_vehicle_selector_item_selected(index: int) -> void:
    if index >= 0 and index < _vehicle_names.size():
        select_vehicle(_vehicle_names[index])

func update_from_snapshot(snapshot: Dictionary, now_timestamp_us: int = -1) -> void:
    if snapshot.is_empty():
        return
    var motors: Array = snapshot.get("motors", [])
    var battery: Dictionary = snapshot.get("battery", {})
    var wind_body: Vector3 = snapshot.get("wind_body_mps", Vector3.ZERO)
    var pid: Array = snapshot.get("pid", [])
    var snapshot_vehicle_name := String(snapshot.get("vehicle_name", ""))
    if not snapshot_vehicle_name.is_empty():
        selected_vehicle_name = snapshot_vehicle_name
    var timestamp_us := int(snapshot.get("timestamp_us", 0))
    var effective_now_timestamp_us := now_timestamp_us if now_timestamp_us >= 0 else _now_timestamp_us
    var telemetry_vehicle_name := snapshot_vehicle_name if not snapshot_vehicle_name.is_empty() else selected_vehicle_name
    var publish_count := int(snapshot.get("publish_count", 0))
    if publish_count > 0 and (not _last_publish_counts.has(telemetry_vehicle_name) or int(_last_publish_counts[telemetry_vehicle_name]) != publish_count):
        _last_publish_counts[telemetry_vehicle_name] = publish_count
        _last_publish_received_us[telemetry_vehicle_name] = effective_now_timestamp_us
    var received_us := int(_last_publish_received_us.get(telemetry_vehicle_name, -1))
    var snapshot_age_us := maxi(0, effective_now_timestamp_us - received_us) if effective_now_timestamp_us >= 0 and received_us >= 0 else 0
    var connection_state := _connection_state(snapshot, effective_now_timestamp_us, snapshot_age_us)
    var latency_us := snapshot_age_us
    debug_values = snapshot.duplicate(true)
    debug_values.merge({
        "schema_version": int(snapshot.get("schema_version", 0)),
        "timestamp_us": timestamp_us,
        "publish_count": int(snapshot.get("publish_count", 0)),
        "source": str(snapshot.get("source", "")),
        "vehicle_name": str(snapshot.get("vehicle_name", "")),
        "armed": bool(snapshot.get("armed", false)),
        "mode": str(snapshot.get("mode", "")),
        "motors": motors,
        "battery": battery,
        "wind_body_mps": wind_body,
        "pid": pid,
        "connection_state": connection_state,
        "latency_ms": float(latency_us) / 1000.0,
        "update_rate_hz": float(snapshot.get("snapshot_hz", 0.0)),
    })

    _labels.status.text = _format("ui.dashboard.status", [
        connection_state.to_upper(),
        float(debug_values.update_rate_hz),
        float(debug_values.latency_ms),
    ])
    _labels.status.add_theme_color_override("font_color", _status_color(connection_state))
    _labels.mode.text = _format("ui.dashboard.mode", [debug_values.vehicle_name, "ON" if debug_values.armed else "OFF", debug_values.mode])
    for index in range(min(motors.size(), MOTOR_KEYS.size())):
        var motor: Dictionary = motors[index]
        _labels[MOTOR_KEYS[index]].text = _format("ui.dashboard.motor", [
            MOTOR_KEYS[index],
            float(motor.get("thrust_newtons", 0.0)),
            float(motor.get("speed_rad_s", 0.0)),
            " SAT" if bool(motor.get("saturated", false)) else ""
        ])
    _labels.battery.text = _format("ui.dashboard.battery", [
        float(battery.get("voltage_v", 0.0)),
        float(battery.get("sag_v", 0.0))
    ])
    _labels.wind.text = _format("ui.dashboard.wind", [wind_body.x, wind_body.y, wind_body.z])
    _labels.pid.text = _format("ui.dashboard.pid", [_pid_saturation_text(pid)])
    _labels.rate.text = _format("ui.dashboard.rate", [
        float(debug_values.update_rate_hz),
        int(debug_values.publish_count),
    ])
    _labels.latency.text = _format("ui.dashboard.latency", [
        float(debug_values.latency_ms),
        "FRESH" if connection_state == "live" else "NOT FRESH",
    ])
    _labels.timestamp.text = _format("ui.dashboard.timestamp", [timestamp_us])


func _set_disconnected(vehicle_name: String) -> void:
    update_from_snapshot({
        "vehicle_name": vehicle_name,
        "connection_state": "disconnected",
        "mode": "-",
        "motors": [],
        "battery": {},
        "wind_body_mps": Vector3.ZERO,
        "pid": [],
    })


func _connection_state(snapshot: Dictionary, now_timestamp_us: int, snapshot_age_us: int) -> String:
    var explicit_state := String(snapshot.get("connection_state", ""))
    if explicit_state in ["live", "stale", "disconnected"]:
        return explicit_state
    var timestamp_us := int(snapshot.get("timestamp_us", 0))
    if timestamp_us <= 0 or int(snapshot.get("publish_count", 0)) <= 0 or String(snapshot.get("source", "")).is_empty():
        return "disconnected"
    if now_timestamp_us < 0:
        return "live"
    return "stale" if snapshot_age_us > STALE_AFTER_US else "live"


func _status_color(connection_state: String) -> Color:
    match connection_state:
        "live":
            return Color("#83e28b")
        "stale":
            return Color("#f1c75b")
        _:
            return Color("#f08080")


func _apply_layout() -> void:
    if _dashboard_margin == null or _dashboard_panel == null:
        return
    var full := layout_mode == "full"
    _dashboard_margin.offset_left = -536.0 if full else -436.0
    _dashboard_margin.offset_bottom = 430.0 if full else 300.0
    _dashboard_panel.custom_minimum_size = Vector2(520.0, 414.0) if full else Vector2(420.0, 284.0)
    for key in ["rate", "latency", "timestamp"]:
        _labels[key].visible = full


func update_environment(snapshot: Dictionary) -> void:
    if snapshot.is_empty() or not _labels.has("environment"):
        return
    var sun_position: Vector3 = snapshot.get("sun_position", Vector3(0.0, 1.0, 0.0))
    _labels.environment.text = _format("ui.dashboard.environment", [
        int(snapshot.get("revision", 0)),
        "LIVE" if bool(snapshot.get("weather_enabled", false)) else "READY",
        float(snapshot.get("rain", 0.0)),
        float(snapshot.get("fog", 0.0)),
        float(snapshot.get("time_of_day", 12.0)),
        sun_position.x,
        sun_position.y,
        sun_position.z,
    ])

func _add_label(parent: VBoxContainer, key: String) -> void:
    var label := Label.new()
    label.custom_minimum_size = Vector2(288.0, 20.0)
    label.text = _t("ui.dashboard.empty")
    parent.add_child(label)
    _labels[key] = label

func _pid_saturation_text(pid: Array) -> String:
    var names := ["PITCH", "YAW", "ROLL"]
    var saturated := []
    for index in range(min(pid.size(), names.size())):
        var axis: Dictionary = pid[index]
        if bool(axis.get("saturated", false)):
            saturated.append(names[index])
    if saturated.is_empty():
        return _t("ui.dashboard.none")
    var text := str(saturated[0])
    for index in range(1, saturated.size()):
        text += ",%s" % saturated[index]
    return text
