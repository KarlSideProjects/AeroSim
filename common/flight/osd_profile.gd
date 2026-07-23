class_name OsdProfile
extends RefCounted

const SCHEMA_VERSION := 1
const PRESETS := ["Minimal", "Race", "Debug"]
const ELEMENTS := ["battery", "armed", "flight_mode", "timer", "lap_checkpoint", "signal", "warnings", "reset_hint"]

const DEFAULT_ELEMENTS := {
    "Minimal": {"battery": true, "armed": true, "flight_mode": false, "timer": false, "lap_checkpoint": false, "signal": false, "warnings": true, "reset_hint": true},
    "Race": {"battery": true, "armed": true, "flight_mode": true, "timer": true, "lap_checkpoint": true, "signal": true, "warnings": true, "reset_hint": true},
    "Debug": {"battery": true, "armed": true, "flight_mode": true, "timer": true, "lap_checkpoint": true, "signal": true, "warnings": true, "reset_hint": true},
}

const DEFAULT_POSITIONS := {
    "battery": {"x": 0.68, "y": 0.48},
    "armed": {"x": 0.68, "y": 0.54},
    "flight_mode": {"x": 0.68, "y": 0.60},
    "timer": {"x": 0.35, "y": 0.04},
    "lap_checkpoint": {"x": 0.35, "y": 0.10},
    "signal": {"x": 0.68, "y": 0.66},
    "warnings": {"x": 0.03, "y": 0.25},
    "reset_hint": {"x": 0.68, "y": 0.90},
}


static func default_profile() -> Dictionary:
    return {
        "schema_version": SCHEMA_VERSION,
        "preset": "Minimal",
        "elements": DEFAULT_ELEMENTS["Minimal"].duplicate(true),
        "positions": DEFAULT_POSITIONS.duplicate(true),
    }


static func profile_for_preset(preset: String) -> Dictionary:
    var profile := default_profile()
    if preset in PRESETS:
        profile.preset = preset
        profile.elements = DEFAULT_ELEMENTS[preset].duplicate(true)
    return profile


static func validate_profile(candidate: Variant) -> Dictionary:
    if typeof(candidate) != TYPE_DICTIONARY:
        return {"ok": false, "error": "osd must be an object"}
    var source: Dictionary = candidate
    for key in source.keys():
        if key not in ["schema_version", "preset", "elements", "positions"]:
            return {"ok": false, "error": "unknown osd field: %s" % key}
    for key in ["schema_version", "preset", "elements", "positions"]:
        if not source.has(key):
            return {"ok": false, "error": "missing osd field: %s" % key}
    if typeof(source.schema_version) != TYPE_INT or int(source.schema_version) != SCHEMA_VERSION:
        return {"ok": false, "error": "unsupported osd schema_version"}
    if typeof(source.preset) != TYPE_STRING or source.preset not in PRESETS:
        return {"ok": false, "error": "osd preset must be Minimal, Race, or Debug"}
    if typeof(source.elements) != TYPE_DICTIONARY:
        return {"ok": false, "error": "osd elements must be an object"}
    for element in source.elements:
        if element not in ELEMENTS or typeof(source.elements[element]) != TYPE_BOOL:
            return {"ok": false, "error": "invalid osd element: %s" % element}
    for element in ELEMENTS:
        if not source.elements.has(element):
            return {"ok": false, "error": "missing osd element: %s" % element}
    if typeof(source.positions) != TYPE_DICTIONARY:
        return {"ok": false, "error": "osd positions must be an object"}
    for element in source.positions:
        if element not in ELEMENTS or typeof(source.positions[element]) != TYPE_DICTIONARY:
            return {"ok": false, "error": "invalid osd position: %s" % element}
        var position: Dictionary = source.positions[element]
        if position.keys().size() != 2 or not position.has("x") or not position.has("y"):
            return {"ok": false, "error": "osd position must contain x and y: %s" % element}
        if not _finite_number(position.x) or not _finite_number(position.y) or float(position.x) < 0.0 or float(position.x) > 1.0 or float(position.y) < 0.0 or float(position.y) > 1.0:
            return {"ok": false, "error": "osd position is outside 0..1: %s" % element}
    for element in ELEMENTS:
        if not source.positions.has(element):
            return {"ok": false, "error": "missing osd position: %s" % element}
    return {"ok": true, "error": "", "profile": source.duplicate(true)}


static func _finite_number(value: Variant) -> bool:
    return (typeof(value) == TYPE_INT or typeof(value) == TYPE_FLOAT) and is_finite(float(value))
