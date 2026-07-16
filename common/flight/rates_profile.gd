class_name RatesProfile
extends RefCounted

const SCHEMA_VERSION := 1
const FIELD_NAMES := ["schema_version", "rc_rate", "super_rate", "expo"]
const DEFAULT_RC_RATE := 1.0
const DEFAULT_SUPER_RATE := 13.0 / 18
const DEFAULT_EXPO := 0.0


static func default_profile() -> Dictionary:
    return {
        "schema_version": SCHEMA_VERSION,
        "rc_rate": DEFAULT_RC_RATE,
        "super_rate": DEFAULT_SUPER_RATE,
        "expo": DEFAULT_EXPO,
    }


static func validate_profile(candidate: Variant) -> Dictionary:
    if typeof(candidate) != TYPE_DICTIONARY:
        return {"ok": false, "error": "rates profile must be an object"}
    var source: Dictionary = candidate
    for key in source.keys():
        if not FIELD_NAMES.has(key):
            return {"ok": false, "error": "unknown rates field: %s" % key}
    for key in FIELD_NAMES:
        if not source.has(key):
            return {"ok": false, "error": "missing rates field: %s" % key}
    if typeof(source["schema_version"]) not in [TYPE_INT, TYPE_FLOAT] or not is_equal_approx(float(source["schema_version"]), float(SCHEMA_VERSION)):
        return {"ok": false, "error": "unsupported rates schema_version"}
    for key in ["rc_rate", "super_rate", "expo"]:
        if typeof(source[key]) not in [TYPE_INT, TYPE_FLOAT] or not is_finite(float(source[key])):
            return {"ok": false, "error": "%s must be a finite number" % key}
    if float(source["rc_rate"]) < 0.0 or float(source["rc_rate"]) > 3.0:
        return {"ok": false, "error": "rc_rate must be between 0 and 3"}
    if float(source["super_rate"]) < 0.0 or float(source["super_rate"]) > 1.0:
        return {"ok": false, "error": "super_rate must be between 0 and 1"}
    if float(source["expo"]) < 0.0 or float(source["expo"]) > 1.0:
        return {"ok": false, "error": "expo must be between 0 and 1"}
    return {
        "ok": true,
        "error": "",
        "profile": {
            "schema_version": SCHEMA_VERSION,
            "rc_rate": float(source["rc_rate"]),
            "super_rate": float(source["super_rate"]),
            "expo": float(source["expo"]),
        },
    }


static func to_json(profile: Dictionary) -> String:
    var result := validate_profile(profile)
    if not result.ok:
        return ""
    return JSON.stringify(result.profile)


static func from_json(encoded: String) -> Dictionary:
    var parser := JSON.new()
    if parser.parse(encoded) != OK:
        return {"ok": false, "error": "rates JSON is malformed"}
    var parsed = parser.data
    var result := validate_profile(parsed)
    if not result.ok:
        return result
    return result


static func diff(current: Dictionary, imported: Dictionary) -> Array[Dictionary]:
    var changes: Array[Dictionary] = []
    for key in ["rc_rate", "super_rate", "expo"]:
        if not is_equal_approx(float(current[key]), float(imported[key])):
            changes.append({
                "key": key,
                "current": float(current[key]),
                "imported": float(imported[key]),
            })
    return changes
