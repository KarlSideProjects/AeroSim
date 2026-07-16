extends CanvasLayer

signal vehicle_selected(vehicle_name: String)

const MOTOR_KEYS := ["M1", "M2", "M3", "M4"]

var debug_values: Dictionary = {}
var vehicle_snapshots: Dictionary = {}
var selected_vehicle_name := ""
var _vehicle_names: Array[String] = []
var _vehicle_selector: OptionButton
var _labels := {}

func _ready() -> void:
    layer = 20
    name = "StatusDiagramDebug"
    var margin := MarginContainer.new()
    margin.set_anchors_preset(Control.PRESET_TOP_RIGHT)
    margin.offset_left = -320.0
    margin.offset_bottom = 220.0
    margin.add_theme_constant_override("margin_left", 8)
    margin.add_theme_constant_override("margin_top", 8)
    margin.add_theme_constant_override("margin_right", 8)
    margin.add_theme_constant_override("margin_bottom", 8)
    add_child(margin)

    var panel := PanelContainer.new()
    panel.custom_minimum_size = Vector2(312.0, 204.0)
    margin.add_child(panel)

    var rows := VBoxContainer.new()
    rows.add_theme_constant_override("separation", 4)
    panel.add_child(rows)

    _vehicle_selector = OptionButton.new()
    _vehicle_selector.name = "VehicleSelector"
    _vehicle_selector.tooltip_text = "Select the vehicle shown by the operations dashboard"
    _vehicle_selector.item_selected.connect(_on_vehicle_selector_item_selected)
    rows.add_child(_vehicle_selector)
    _add_label(rows, "mode")
    for key in MOTOR_KEYS:
        _add_label(rows, key)
    _add_label(rows, "battery")
    _add_label(rows, "wind")
    _add_label(rows, "pid")


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


func set_vehicle_snapshots(snapshots: Dictionary, preferred_vehicle_name: String = "") -> void:
    vehicle_snapshots = snapshots.duplicate(true)
    var names: Array = []
    for name in vehicle_snapshots.keys():
        names.append(String(name))
    set_vehicle_names(names)
    if _vehicle_names.is_empty():
        if not vehicle_snapshots.is_empty():
            update_from_snapshot(vehicle_snapshots[vehicle_snapshots.keys()[0]])
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
        update_from_snapshot(vehicle_snapshots[vehicle_name])
    if notify:
        vehicle_selected.emit(vehicle_name)
    return true


func get_selected_vehicle_name() -> String:
    return selected_vehicle_name


func _on_vehicle_selector_item_selected(index: int) -> void:
    if index >= 0 and index < _vehicle_names.size():
        select_vehicle(_vehicle_names[index])

func update_from_snapshot(snapshot: Dictionary) -> void:
    if snapshot.is_empty():
        return
    var motors: Array = snapshot.get("motors", [])
    var battery: Dictionary = snapshot.get("battery", {})
    var wind_body: Vector3 = snapshot.get("wind_body_mps", Vector3.ZERO)
    var pid: Array = snapshot.get("pid", [])
    var snapshot_vehicle_name := String(snapshot.get("vehicle_name", ""))
    if not snapshot_vehicle_name.is_empty():
        selected_vehicle_name = snapshot_vehicle_name
    debug_values = {
        "schema_version": int(snapshot.get("schema_version", 0)),
        "timestamp_us": int(snapshot.get("timestamp_us", 0)),
        "publish_count": int(snapshot.get("publish_count", 0)),
        "source": str(snapshot.get("source", "")),
        "vehicle_name": str(snapshot.get("vehicle_name", "")),
        "armed": bool(snapshot.get("armed", false)),
        "mode": str(snapshot.get("mode", "")),
        "motors": motors,
        "battery": battery,
        "wind_body_mps": wind_body,
        "pid": pid
    }

    _labels.mode.text = "%s  ARM %s  MODE %s" % [debug_values.vehicle_name, "ON" if debug_values.armed else "OFF", debug_values.mode]
    for index in range(min(motors.size(), MOTOR_KEYS.size())):
        var motor: Dictionary = motors[index]
        _labels[MOTOR_KEYS[index]].text = "%s  %.2f N  %.1f rad/s%s" % [
            MOTOR_KEYS[index],
            float(motor.get("thrust_newtons", 0.0)),
            float(motor.get("speed_rad_s", 0.0)),
            " SAT" if bool(motor.get("saturated", false)) else ""
        ]
    _labels.battery.text = "BAT %.2f V  sag %.2f V" % [
        float(battery.get("voltage_v", 0.0)),
        float(battery.get("sag_v", 0.0))
    ]
    _labels.wind.text = "WIND body %.2f %.2f %.2f m/s" % [wind_body.x, wind_body.y, wind_body.z]
    _labels.pid.text = "PID sat %s" % _pid_saturation_text(pid)

func _add_label(parent: VBoxContainer, key: String) -> void:
    var label := Label.new()
    label.custom_minimum_size = Vector2(288.0, 20.0)
    label.text = "-"
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
        return "none"
    var text := str(saturated[0])
    for index in range(1, saturated.size()):
        text += ",%s" % saturated[index]
    return text
