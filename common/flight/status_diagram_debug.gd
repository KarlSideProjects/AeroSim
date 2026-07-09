extends CanvasLayer

const MOTOR_KEYS := ["M1", "M2", "M3", "M4"]

var debug_values: Dictionary = {}
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

    _add_label(rows, "mode")
    for key in MOTOR_KEYS:
        _add_label(rows, key)
    _add_label(rows, "battery")
    _add_label(rows, "wind")
    _add_label(rows, "pid")

func update_from_snapshot(snapshot: Dictionary) -> void:
    if snapshot.is_empty():
        return
    var motors: Array = snapshot.get("motors", [])
    var battery: Dictionary = snapshot.get("battery", {})
    var wind_body: Vector3 = snapshot.get("wind_body_mps", Vector3.ZERO)
    var pid: Array = snapshot.get("pid", [])
    debug_values = {
        "schema_version": int(snapshot.get("schema_version", 0)),
        "timestamp_us": int(snapshot.get("timestamp_us", 0)),
        "publish_count": int(snapshot.get("publish_count", 0)),
        "source": str(snapshot.get("source", "")),
        "armed": bool(snapshot.get("armed", false)),
        "mode": str(snapshot.get("mode", "")),
        "motors": motors,
        "battery": battery,
        "wind_body_mps": wind_body,
        "pid": pid
    }

    _labels.mode.text = "ARM %s  MODE %s" % ["ON" if debug_values.armed else "OFF", debug_values.mode]
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
