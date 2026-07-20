class_name QualityProfile
extends RefCounted

const SCHEMA_VERSION := 1
const DEFAULT_RENDER_SCALE := 1.0
const MIN_RENDER_SCALE := 0.50
const MAX_RENDER_SCALE := 1.00
const RENDER_SCALE_STEP := 0.05
const FIELD_NAMES := ["schema_version", "render_scale"]


static func default_profile() -> Dictionary:
    return {"schema_version": SCHEMA_VERSION, "render_scale": DEFAULT_RENDER_SCALE}


static func validate_profile(candidate: Variant) -> Dictionary:
    if typeof(candidate) != TYPE_DICTIONARY:
        return {"ok": false, "error": "quality profile must be an object"}
    var source: Dictionary = candidate
    for key in source.keys():
        if not FIELD_NAMES.has(key):
            return {"ok": false, "error": "unknown quality field: %s" % key}
    for key in FIELD_NAMES:
        if not source.has(key):
            return {"ok": false, "error": "missing quality field: %s" % key}
    if typeof(source["schema_version"]) not in [TYPE_INT, TYPE_FLOAT] or not is_equal_approx(float(source["schema_version"]), float(SCHEMA_VERSION)):
        return {"ok": false, "error": "unsupported quality schema_version"}
    if typeof(source["render_scale"]) not in [TYPE_INT, TYPE_FLOAT] or not is_finite(float(source["render_scale"])):
        return {"ok": false, "error": "render_scale must be a finite number"}

    var value := float(source["render_scale"])
    var tick := roundi((value - MIN_RENDER_SCALE) / RENDER_SCALE_STEP)
    if tick < 0 or tick > 10 or not is_equal_approx(value, MIN_RENDER_SCALE + tick * RENDER_SCALE_STEP):
        return {"ok": false, "error": "render_scale must be between 0.50 and 1.00 in 0.05 steps"}
    var canonical_scale := MIN_RENDER_SCALE + tick * RENDER_SCALE_STEP
    return {
        "ok": true,
        "error": "",
        "profile": {"schema_version": SCHEMA_VERSION, "render_scale": canonical_scale},
    }
