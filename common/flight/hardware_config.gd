extends RefCounted

const SCHEMA_PATH := "res://config/drone_schema.json"

const FACTORY_DEFAULT := {
    "version": "factory-default",
    "units": {"mass": "kg", "length": "m", "area": "m^2", "thrust": "N", "torque": "Nm", "rpm": "rpm", "current": "A", "resistance": "ohm", "time": "s", "frequency": "Hz", "angle": "deg"},
    "coordinate_frame": {"world": "Godot Y-up", "body": "FRD: +X forward, +Y right, +Z down"},
    "motor_order": ["rear_right", "front_right", "rear_left", "front_left"],
    "spin_direction": ["cw", "ccw", "ccw", "cw"],
    "prop_table_interpolation": "linear_no_extrapolation",
    "frame": {
        "wheelbase_m": 0.225,
        "arm_length_m": 0.159,
        "dry_mass_kg": 0.42,
        "frontal_area_m2": {"x": 0.018, "y": 0.018, "z": 0.030},
        "layout": "x"
    },
    "motor": {
        "stator": "2207",
        "kv": 1750,
        "resistance_ohm": 0.055,
        "max_current_a": 45,
        "tau_m_s": 0.030,
        "count": 4
    },
    "propeller": {
        "diameter_in": 5.0,
        "pitch_in": 4.3,
        "blades": 3,
        "mass_kg": 0.0045,
        "table": [
            {"rpm": 5000, "thrust_n": 1.2, "torque_nm": 0.012, "current_a": 3.0},
            {"rpm": 15000, "thrust_n": 9.8, "torque_nm": 0.083, "current_a": 21.0}
        ]
    },
    "battery": {
        "cells": 6,
        "capacity_mah": 1300,
        "c_rating": 100,
        "cell_resistance_ohm": 0.003,
        "nominal_voltage_v": 22.2,
        "discharge_curve": [
            {"remaining": 1.0, "voltage_v": 25.2},
            {"remaining": 0.0, "voltage_v": 19.2}
        ]
    },
    "esc": {"current_limit_a": 45, "protocol": "DShot600", "update_rate_hz": 600},
    "aircraft": {
        "mass_kg": 0.72,
        "inertia_kg_m2": {"x": 0.0030, "y": 0.0030, "z": 0.0050},
        "cg_offset_m": {"x": 0.0, "y": 0.0, "z": 0.0},
        "motor_layout": [
            {"x": -0.1125, "y": 0.1125, "z": 0.0},
            {"x": 0.1125, "y": 0.1125, "z": 0.0},
            {"x": -0.1125, "y": -0.1125, "z": 0.0},
            {"x": 0.1125, "y": -0.1125, "z": 0.0}
        ]
    },
    "sensors": {
        "gyro_hz": 8000,
        "imu_noise_density": 0.005,
        "bias_drift": 0.0002,
        "random_walk": 0.0001,
        "barometer_noise_m": 0.10
    },
    "fpv": {"camera_angle_deg": 30, "fov_deg": 150}
}

var current: Dictionary = FACTORY_DEFAULT.duplicate(true)
var last_ok := true
var last_error := ""

func load_preset(path: String) -> Dictionary:
    var parsed := _read_json(path)
    if not parsed.ok:
        return _fail(parsed.error)
    var error := validate_config(parsed.value)
    if error != "":
        return _fail("%s: %s" % [path, error])
    current = parsed.value
    last_ok = true
    last_error = ""
    return current

func validate_config(config: Dictionary) -> String:
    var schema := _read_json(SCHEMA_PATH)
    if not schema.ok:
        return schema.error
    return _validate(config, schema.value)

func apply_to_runtime(runtime: Object, path: String) -> bool:
    var preset := load_preset(path)
    var ok := last_ok
    _apply_current_to_runtime(runtime, path)
    return ok

func prop_sample_at_rpm(config: Dictionary, rpm: float) -> Dictionary:
    var table: Array = config.get("propeller", {}).get("table", [])
    if table.size() < 2:
        return {"ok": false, "error": "prop table needs at least two rows"}
    if rpm < float(table[0].rpm) or rpm > float(table[table.size() - 1].rpm):
        return {"ok": false, "error": "prop table forbids rpm extrapolation"}
    for index in range(table.size() - 1):
        var left: Dictionary = table[index]
        var right: Dictionary = table[index + 1]
        if rpm >= float(left.rpm) and rpm <= float(right.rpm):
            var span := float(right.rpm) - float(left.rpm)
            var t := 0.0 if span == 0.0 else (rpm - float(left.rpm)) / span
            return {
                "ok": true,
                "thrust_n": lerpf(float(left.thrust_n), float(right.thrust_n), t),
                "torque_nm": lerpf(float(left.torque_nm), float(right.torque_nm), t),
                "current_a": lerpf(float(left.current_a), float(right.current_a), t)
            }
    return {"ok": false, "error": "prop table rpm is not bracketed"}

func _apply_current_to_runtime(runtime: Object, path: String) -> void:
    if runtime.get("native") != null:
        runtime.native.call("set_hardware_mass_kg", float(current.aircraft.mass_kg))
    runtime.set_meta("hardware_config_version", current.version)
    runtime.set_meta("hardware_config_path", path)

func _fail(error: String) -> Dictionary:
    current = FACTORY_DEFAULT.duplicate(true)
    last_ok = false
    last_error = error
    push_error(error)
    return current

func _read_json(path: String) -> Dictionary:
    var file := FileAccess.open(path, FileAccess.READ)
    if file == null:
        return {"ok": false, "error": "Cannot open JSON: %s" % path}
    var json := JSON.new()
    var parse_error := json.parse(file.get_as_text())
    if parse_error != OK:
        return {"ok": false, "error": "Bad JSON in %s at line %d: %s" % [path, json.get_error_line(), json.get_error_message()]}
    if not (json.data is Dictionary):
        return {"ok": false, "error": "JSON root must be an object: %s" % path}
    return {"ok": true, "value": json.data}

func _validate(config: Dictionary, schema: Dictionary) -> String:
    for path in schema.required_paths:
        if _dig(config, path) == null:
            return "missing field %s" % path
    if config.units != schema.expected_units:
        return "units must match schema"
    if config.coordinate_frame != schema.expected_coordinate_frame:
        return "coordinate frame must match schema"
    if config.motor_order != schema.expected_motor_order:
        return "motor order must follow Betaflight quad-X"
    if config.spin_direction != schema.expected_spin_direction:
        return "spin direction must match motor order"
    if config.prop_table_interpolation != "linear_no_extrapolation":
        return "prop table interpolation must be linear_no_extrapolation"
    for spec_value in schema.numeric_ranges:
        var spec: Dictionary = spec_value
        var value: Variant = _dig(config, spec.path)
        if not _in_range(value, spec):
            return "%s out of range" % spec.path
    var table_error := _validate_propeller_table(config.propeller.table, schema.propeller_table_ranges)
    if table_error != "":
        return table_error
    var curve_error := _validate_discharge_curve(config.battery.discharge_curve, schema.discharge_curve_ranges)
    if curve_error != "":
        return curve_error
    var layout_error := _validate_motor_layout(config.aircraft.motor_layout)
    if layout_error != "":
        return layout_error
    return ""

func _validate_propeller_table(table: Array, ranges: Dictionary) -> String:
    if table.size() < 2:
        return "propeller table needs at least two rows"
    var previous_rpm := -INF
    for row in table:
        for key in ["rpm", "thrust_n", "torque_nm", "current_a"]:
            if not row.has(key) or not _in_range(row[key], ranges[key]):
                return "propeller table %s out of range" % key
        if float(row.rpm) <= previous_rpm:
            return "propeller table rpm must increase"
        previous_rpm = float(row.rpm)
    return ""

func _validate_discharge_curve(curve: Array, ranges: Dictionary) -> String:
    if curve.size() < 2:
        return "battery.discharge_curve needs at least two rows"
    for row in curve:
        if not row.has("remaining") or not row.has("voltage_v"):
            return "battery.discharge_curve row is incomplete"
        if not _in_range(row.remaining, ranges.remaining) or not _in_range(row.voltage_v, ranges.voltage_v):
            return "battery.discharge_curve row out of range"
    return ""

func _validate_motor_layout(layout: Array) -> String:
    if layout.size() != 4:
        return "aircraft.motor_layout must describe 4 motors"
    for row in layout:
        for key in ["x", "y", "z"]:
            if not row.has(key) or not (row[key] is float or row[key] is int):
                return "aircraft.motor_layout row is incomplete"
            if float(row[key]) < -1.0 or float(row[key]) > 1.0:
                return "aircraft.motor_layout row out of range"
    return ""

func _in_range(value: Variant, spec: Dictionary) -> bool:
    if not (value is float or value is int):
        return false
    return float(value) >= float(spec.min) and float(value) <= float(spec.max)

func _dig(value: Dictionary, path: String) -> Variant:
    var cursor: Variant = value
    for part in path.split("."):
        if not (cursor is Dictionary) or not cursor.has(part):
            return null
        cursor = cursor[part]
    return cursor
