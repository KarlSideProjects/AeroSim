class_name CameraProfile
extends RefCounted

const SCHEMA_VERSION := 1
# Camera3D.fov is the vertical FOV under the default keep_aspect = KEEP_HEIGHT, so 150
# rendered a ~163 degree horizontal view at 16:9. On a flat monitor that suppresses the
# apparent forward translation the pilot needs to fly, while amplifying every attitude
# change. 90 vertical is ~121 horizontal, still wide, and readable. Both values remain
# pilot-adjustable from the in-flight camera panel.
const DEFAULT_CAMERA_ANGLE_DEG := 0.0
const DEFAULT_FOV_DEG := 90.0


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
