extends Control

var state: Dictionary = {"connected": false, "mode": "-", "yaw": 0.0, "throttle": 0.0, "roll": 0.0, "pitch": 0.0}

func _ready() -> void:
    custom_minimum_size = Vector2(282.0, 202.0)
    mouse_filter = Control.MOUSE_FILTER_IGNORE

func set_controller_state(value: Dictionary) -> void:
    state = value
    queue_redraw()

func _draw() -> void:
    var connected := bool(state.get("connected", false))
    var color := Color(0.18, 0.78, 1.0) if connected else Color(0.45, 0.45, 0.45)
    draw_string(ThemeDB.fallback_font, Vector2(85, 18), String(state.get("title", "XBOX MODE 2")), HORIZONTAL_ALIGNMENT_LEFT, -1.0, 14, Color.WHITE)
    draw_string(ThemeDB.fallback_font, Vector2(92.0, 35.0), String(state.get("mode", "-")), HORIZONTAL_ALIGNMENT_LEFT, -1.0, 12, color)
    draw_circle(Vector2(141.0, 108.0), 70.0, Color(0.04, 0.07, 0.11, 0.94))
    draw_arc(Vector2(141.0, 108.0), 70.0, 0.0, TAU, 32, color, 2.0)
    _draw_stick(Vector2(95.0, 116.0), float(state.get("yaw", 0.0)), float(state.get("throttle", 0.0)), String(state.get("left_label", "YAW / CLIMB")), color, connected)
    _draw_stick(Vector2(187.0, 116.0), float(state.get("roll", 0.0)), float(state.get("pitch", 0.0)), String(state.get("right_label", "ROLL / PITCH")), color, connected)
    draw_string(ThemeDB.fallback_font, Vector2(19.0, 181.0), String(state.get("actions", "A ARM/TAKEOFF   Y MODE")), HORIZONTAL_ALIGNMENT_LEFT, -1.0, 11, color)
    draw_string(ThemeDB.fallback_font, Vector2(87.0, 197.0), String(state.get("connection", "CONNECTED" if connected else "CONTROLLER UNAVAILABLE")), HORIZONTAL_ALIGNMENT_LEFT, -1.0, 10, color)

func _draw_stick(center: Vector2, horizontal: float, vertical: float, label: String, color: Color, connected: bool) -> void:
    draw_circle(center, 30.0, Color(color, 0.13 if connected else 0.05))
    draw_arc(center, 30.0, 0.0, TAU, 20, Color(color, 0.7 if connected else 0.25), 1.0)
    draw_line(center - Vector2(24.0, 0.0), center + Vector2(24.0, 0.0), Color(color, 0.35), 1.0)
    draw_line(center - Vector2(0.0, 24.0), center + Vector2(0.0, 24.0), Color(color, 0.35), 1.0)
    var dot := center + Vector2(clampf(horizontal, -1.0, 1.0), -clampf(vertical, -1.0, 1.0)) * 22.0
    draw_circle(dot, 6.0, color)
    draw_string(ThemeDB.fallback_font, center + Vector2(-32.0, 45.0), label, HORIZONTAL_ALIGNMENT_LEFT, -1.0, 10, Color.WHITE)
