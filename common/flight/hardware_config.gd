extends RefCounted

const SCHEMA_PATH := "res://config/drone_schema.json"
const GRAVITY_MPS2 := 9.80665
const USABLE_BATTERY_FRACTION := 0.80

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
            {"rpm": 4000, "thrust_n": 1.152, "torque_nm": 0.0112, "current_a": 2.8},
            {"rpm": 10000, "thrust_n": 7.2, "torque_nm": 0.0700, "current_a": 10.5},
            {"rpm": 15000, "thrust_n": 16.2, "torque_nm": 0.1575, "current_a": 27.0}
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
    var apply_ok := _apply_current_to_runtime(runtime, path)
    return ok and apply_ok

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

func derive_power_model(config: Dictionary) -> Dictionary:
    var table: Array = config.get("propeller", {}).get("table", [])
    var motor_count := int(config.get("motor", {}).get("count", 0))
    var mass_kg := float(config.get("aircraft", {}).get("mass_kg", 0.0))
    if table.size() < 2 or motor_count <= 0 or mass_kg <= 0.0:
        return {"ok": false, "error": "power model requires mass, motor count, and prop table"}

    var thrust_fit := _fit_quadratic_from_rpm(table, "thrust_n")
    var torque_fit := _fit_quadratic_from_rpm(table, "torque_nm")
    if not thrust_fit.ok or not torque_fit.ok:
        return {"ok": false, "error": "power model coefficient fit failed"}

    var max_rpm := float(table[table.size() - 1].rpm)
    var max_thrust_per_motor_n := float(table[table.size() - 1].thrust_n)
    var hover_thrust_per_motor_n := mass_kg * GRAVITY_MPS2 / float(motor_count)
    var hover_rpm := sqrt(hover_thrust_per_motor_n / float(thrust_fit.coefficient))
    if hover_rpm <= 0.0 or hover_rpm > max_rpm:
        return {"ok": false, "error": "hover rpm is outside measured prop table"}

    var hover_sample := prop_sample_at_rpm(config, hover_rpm)
    if not hover_sample.ok:
        return {"ok": false, "error": hover_sample.error}

    var total_hover_current_a := float(hover_sample.current_a) * float(motor_count)
    var endurance_minutes := 0.0
    if total_hover_current_a > 0.0:
        endurance_minutes = float(config.battery.capacity_mah) / 1000.0 * USABLE_BATTERY_FRACTION / total_hover_current_a * 60.0

    var max_total_thrust_n := max_thrust_per_motor_n * float(motor_count)
    var hover_throttle := hover_rpm / max_rpm
    var sag_curve := _loaded_voltage_curve(config, total_hover_current_a)
    return {
        "ok": true,
        "k_t_n_per_rpm2": thrust_fit.coefficient,
        "k_q_nm_per_rpm2": torque_fit.coefficient,
        "max_fit_residual_pct": max(float(thrust_fit.max_residual_pct), float(torque_fit.max_residual_pct)),
        "hover_throttle": hover_throttle,
        "max_total_thrust_n": max_total_thrust_n,
        "twr": max_total_thrust_n / (mass_kg * GRAVITY_MPS2),
        "hover_endurance_minutes": endurance_minutes,
        "hover_rpm": hover_rpm,
        "max_motor_rpm": max_rpm,
        "hover_current_a": total_hover_current_a,
        "hover_sag_voltage_v": _sag_voltage(float(config.battery.nominal_voltage_v), float(config.battery.cells), float(config.battery.cell_resistance_ohm), total_hover_current_a),
        "net_hover_yaw_torque_nm": _net_yaw_torque(config.spin_direction, float(torque_fit.coefficient), hover_rpm),
        "sag_curve": sag_curve,
        "sag_model_r2": _linear_voltage_r2(sag_curve),
        "motor_tau_s": float(config.motor.tau_m_s),
        "battery_nominal_voltage_v": float(config.battery.nominal_voltage_v),
        "battery_remaining_mah": float(config.battery.capacity_mah) * USABLE_BATTERY_FRACTION,
        "battery_cells": float(config.battery.cells),
        "battery_cell_resistance_ohm": float(config.battery.cell_resistance_ohm),
        "max_total_current_a": float(table[table.size() - 1].current_a) * float(motor_count),
        "inertia_estimate_kg_m2": config.aircraft.inertia_kg_m2,
        "inertia_source": "preset_override"
    }

func derive_per_motor_model(config: Dictionary, power_model: Dictionary) -> Dictionary:
    if not power_model.get("ok", false):
        return {"ok": false, "error": "per-motor model requires a valid power model"}

    var motor: Dictionary = config.get("motor", {})
    var aircraft: Dictionary = config.get("aircraft", {})
    var layout: Array = aircraft.get("motor_layout", [])
    var spin_direction: Array = config.get("spin_direction", [])
    var motor_count := int(motor.get("count", 0))
    if motor_count != 4 or layout.size() != 4 or spin_direction.size() != 4:
        return {"ok": false, "error": "per-motor model requires four ordered motors"}

    var position_frd: Array[Vector3] = []
    var spin_values: Array[float] = []
    for index in range(4):
        var position: Dictionary = layout[index]
        var direction := str(spin_direction[index])
        if direction != "cw" and direction != "ccw":
            return {"ok": false, "error": "spin direction must be cw or ccw"}
        position_frd.append(Vector3(float(position.get("x", NAN)), float(position.get("y", NAN)), float(position.get("z", NAN))))
        spin_values.append(1.0 if direction == "cw" else -1.0)

    var inertia: Dictionary = aircraft.get("inertia_kg_m2", {})
    var max_thrust_total := float(power_model.get("max_total_thrust_n", 0.0))
    var max_current_total := float(power_model.get("max_total_current_a", 0.0))
    if max_thrust_total <= 0.0 or max_current_total <= 0.0:
        return {"ok": false, "error": "power model has no usable per-motor limits"}
    return {
        "ok": true,
        "inertia_frd": Vector3(float(inertia.get("x", NAN)), float(inertia.get("y", NAN)), float(inertia.get("z", NAN))),
        "position_frd": position_frd,
        "spin_direction": spin_values,
        "max_thrust_per_motor_newtons": max_thrust_total / float(motor_count),
        "max_current_per_motor_a": max_current_total / float(motor_count),
        "yaw_torque_per_newton": float(power_model.get("k_q_nm_per_rpm2", 0.0)) / float(power_model.get("k_t_n_per_rpm2", 0.0))
    }

func _apply_current_to_runtime(runtime: Object, path: String) -> bool:
    if runtime.get("native") != null:
        var power_model := derive_power_model(current)
        if not power_model.ok:
            last_ok = false
            last_error = "power model derivation failed: %s" % power_model.get("error", "unknown")
            push_error(last_error)
            return false
        var per_motor_model := derive_per_motor_model(current, power_model)
        if not per_motor_model.ok:
            last_ok = false
            last_error = "per-motor model derivation failed: %s" % per_motor_model.get("error", "unknown")
            push_error(last_error)
            return false
        if not runtime.native.has_method("set_hardware_power_model") or not runtime.native.has_method("set_hardware_per_motor_model"):
            last_ok = false
            last_error = "native runtime missing hardware model setters"
            push_error(last_error)
            return false
        if not runtime.native.call("set_hardware_mass_kg", float(current.aircraft.mass_kg)):
            last_ok = false
            last_error = "native runtime rejected aircraft mass"
            push_error(last_error)
            return false
        if not runtime.native.call(
                "set_hardware_power_model",
                float(power_model.max_total_thrust_n),
                float(power_model.hover_throttle),
                float(power_model.motor_tau_s),
                float(power_model.battery_nominal_voltage_v),
                float(power_model.battery_cells),
                float(power_model.battery_cell_resistance_ohm),
                float(power_model.max_total_current_a)
            ):
            last_ok = false
            last_error = "native runtime rejected derived power model"
            push_error(last_error)
            return false
        if not runtime.native.call("set_hardware_per_motor_model", per_motor_model):
            last_ok = false
            last_error = "native runtime rejected derived per-motor model"
            push_error(last_error)
            return false
        if runtime.native.has_method("set_hardware_telemetry_model") and not runtime.native.call(
                "set_hardware_telemetry_model",
                float(power_model.max_motor_rpm),
                float(power_model.battery_remaining_mah)
            ):
            last_ok = false
            last_error = "native runtime rejected telemetry model"
            push_error(last_error)
            return false
    runtime.set_meta("hardware_config_version", current.version)
    runtime.set_meta("hardware_config_path", path)
    return true

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

func _fit_quadratic_from_rpm(table: Array, key: String) -> Dictionary:
    var numerator := 0.0
    var denominator := 0.0
    for row in table:
        var x := float(row.rpm) * float(row.rpm)
        numerator += x * float(row[key])
        denominator += x * x
    if denominator <= 0.0:
        return {"ok": false}
    var coefficient := numerator / denominator
    var max_residual_pct := 0.0
    for row in table:
        var measured := float(row[key])
        if measured <= 0.0:
            continue
        var predicted := coefficient * float(row.rpm) * float(row.rpm)
        max_residual_pct = max(max_residual_pct, abs(predicted - measured) / measured * 100.0)
    return {"ok": true, "coefficient": coefficient, "max_residual_pct": max_residual_pct}

func _loaded_voltage_curve(config: Dictionary, total_current_a: float) -> Array:
    var rows := []
    for row in config.battery.discharge_curve:
        rows.append({
            "remaining": float(row.remaining),
            "open_circuit_voltage_v": float(row.voltage_v),
            "loaded_voltage_v": _sag_voltage(float(row.voltage_v), float(config.battery.cells), float(config.battery.cell_resistance_ohm), total_current_a)
        })
    return rows

func _sag_voltage(open_circuit_voltage_v: float, cells: float, cell_resistance_ohm: float, total_current_a: float) -> float:
    return open_circuit_voltage_v - total_current_a * cell_resistance_ohm * cells

func _net_yaw_torque(spin_direction: Array, k_q_nm_per_rpm2: float, rpm: float) -> float:
    var net := 0.0
    for direction in spin_direction:
        var sign := 1.0 if String(direction) == "cw" else -1.0
        net += sign * k_q_nm_per_rpm2 * rpm * rpm
    return net

func _linear_voltage_r2(rows: Array) -> float:
    if rows.size() < 2:
        return 0.0
    var mean_y := 0.0
    for row in rows:
        mean_y += float(row.loaded_voltage_v)
    mean_y /= float(rows.size())

    var mean_x := 0.0
    for row in rows:
        mean_x += float(row.remaining)
    mean_x /= float(rows.size())

    var cov_xy := 0.0
    var var_x := 0.0
    for row in rows:
        var x := float(row.remaining) - mean_x
        var y := float(row.loaded_voltage_v) - mean_y
        cov_xy += x * y
        var_x += x * x
    if var_x <= 0.0:
        return 0.0
    var slope := cov_xy / var_x
    var intercept := mean_y - slope * mean_x
    var ss_res := 0.0
    var ss_tot := 0.0
    for row in rows:
        var y := float(row.loaded_voltage_v)
        var predicted := intercept + slope * float(row.remaining)
        ss_res += (y - predicted) * (y - predicted)
        ss_tot += (y - mean_y) * (y - mean_y)
    if ss_tot <= 0.0:
        return 1.0
    return 1.0 - ss_res / ss_tot
