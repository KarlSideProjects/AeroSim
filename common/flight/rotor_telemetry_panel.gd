extends Control

var motor_hud: Dictionary = {"state": "unavailable", "cells": []}
var phase := 0.0

func _ready() -> void:
    custom_minimum_size = Vector2(282.0, 202.0)
    mouse_filter = Control.MOUSE_FILTER_IGNORE
    set_process(true)

func set_motor_hud(value: Dictionary) -> void:
    motor_hud = value
    queue_redraw()

func _process(delta: float) -> void:
    phase = fmod(phase + delta * 8.0, TAU)
    if String(motor_hud.get("state", "")) == "live":
        queue_redraw()

func _draw() -> void:
    draw_string(ThemeDB.fallback_font, Vector2(84, 18), "LIVE MOTOR TELEMETRY", HORIZONTAL_ALIGNMENT_LEFT, -1.0, 13, Color.WHITE)
    var cells: Array = motor_hud.get("cells", [])
    var centers := [Vector2(72.0, 65.0), Vector2(210.0, 65.0), Vector2(72.0, 145.0), Vector2(210.0, 145.0)]
    for index in range(centers.size()):
        var cell: Dictionary = cells[index] if index < cells.size() else {}
        _draw_rotor(centers[index], cell)

func _draw_rotor(center: Vector2, cell: Dictionary) -> void:
    var live := String(motor_hud.get("state", "")) == "live" and not cell.is_empty()
    var thrust := float(cell.get("thrust_newtons", 0.0))
    var rpm := float(cell.get("speed_rad_s", 0.0)) * 60.0 / TAU
    var saturation := bool(cell.get("saturated", false))
    var glow := clampf(thrust / 8.0, 0.08, 1.0) if live else 0.05
    var color := Color(1.0, 0.30, 0.15) if saturation else Color(0.18, 0.78, 1.0)
    draw_circle(center, 29.0, Color(color, glow * 0.18))
    draw_circle(center, 21.0, Color(0.04, 0.07, 0.11, 0.94))
    draw_arc(center, 21.0, 0.0, TAU, 24, Color(color, 0.85 if live else 0.25), 2.0)
    var direction := -1.0 if String(cell.get("spin_direction", "")) == "ccw" else 1.0
    var blade_angle := phase * direction * (0.3 + clampf(rpm / 12000.0, 0.0, 1.0) * 2.5)
    for offset in [0.0, PI * 0.5]:
        var blade := Vector2(cos(blade_angle + offset), sin(blade_angle + offset)) * 17.0
        draw_line(center - blade, center + blade, Color(color, 0.9 if live else 0.25), 3.0)
    var label := String(cell.get("label", "--"))
    var direction_label := String(cell.get("spin_direction", "")).to_upper()
    draw_string(ThemeDB.fallback_font, center + Vector2(-29.0, 38.0), "%s %s" % [label, direction_label], HORIZONTAL_ALIGNMENT_LEFT, -1.0, 12, Color.WHITE)
    var value := "%4d RPM" % roundi(rpm) if live else "UNAVAILABLE"
    draw_string(ThemeDB.fallback_font, center + Vector2(-34.0, 52.0), value, HORIZONTAL_ALIGNMENT_LEFT, -1.0, 11, color if live else Color.GRAY)
