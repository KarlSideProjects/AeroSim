class_name CameraProfile
extends RefCounted

const SCHEMA_VERSION := 1
const DEFAULT_CAMERA_ANGLE_DEG := 30.0
const DEFAULT_FOV_DEG := 150.0


static func default_profile() -> Dictionary:
    return {
        "schema_version": SCHEMA_VERSION,
        "camera_angle_deg": DEFAULT_CAMERA_ANGLE_DEG,
        "fov_deg": DEFAULT_FOV_DEG,
        "analog_noise": true,
    }


static func validate_profile(candidate: Variant) -> Dictionary:
    if typeof(candidate) != TYPE_DICTIONARY:
        return {"ok": false, "error": "camera must be an object"}
    var source: Dictionary = candidate
    for key in source.keys():
        if key not in ["schema_version", "camera_angle_deg", "fov_deg", "analog_noise"]:
            return {"ok": false, "error": "unknown camera field: %s" % key}
    for key in ["schema_version", "camera_angle_deg", "fov_deg", "analog_noise"]:
        if not source.has(key):
            return {"ok": false, "error": "missing camera field: %s" % key}
    if typeof(source.schema_version) != TYPE_INT or int(source.schema_version) != SCHEMA_VERSION:
        return {"ok": false, "error": "unsupported camera schema_version"}
    if not _finite_number(source.camera_angle_deg) or float(source.camera_angle_deg) < 0.0 or float(source.camera_angle_deg) > 90.0:
        return {"ok": false, "error": "camera_angle_deg must be between 0 and 90"}
    if not _finite_number(source.fov_deg) or float(source.fov_deg) < 30.0 or float(source.fov_deg) > 180.0:
        return {"ok": false, "error": "fov_deg must be between 30 and 180"}
    if typeof(source.analog_noise) != TYPE_BOOL:
        return {"ok": false, "error": "analog_noise must be boolean"}
    var normalized := source.duplicate(true)
    normalized.schema_version = SCHEMA_VERSION
    normalized.camera_angle_deg = float(source.camera_angle_deg)
    normalized.fov_deg = float(source.fov_deg)
    return {"ok": true, "error": "", "profile": normalized}


static func _finite_number(value: Variant) -> bool:
    return (typeof(value) == TYPE_INT or typeof(value) == TYPE_FLOAT) and is_finite(float(value))
