class_name LanguageProfile
extends RefCounted

const SCHEMA_VERSION := 1
const DEFAULT_LOCALE := "en"
const SUPPORTED_LOCALES := ["en", "zh_TW"]


static func default_profile() -> Dictionary:
    return {"schema_version": SCHEMA_VERSION, "locale": DEFAULT_LOCALE}


static func validate_profile(candidate: Variant) -> Dictionary:
    if typeof(candidate) != TYPE_DICTIONARY:
        return {"ok": false, "error": "language must be an object"}
    var source: Dictionary = candidate
    for key in source.keys():
        if key != "locale" and key != "schema_version":
            return {"ok": false, "error": "language profile fields are invalid"}
    if not source.has("locale"):
        return {"ok": false, "error": "language profile fields are invalid"}
    if source.has("schema_version") and (typeof(source["schema_version"]) != TYPE_INT or int(source["schema_version"]) != SCHEMA_VERSION):
        return {"ok": false, "error": "unsupported language schema_version"}
    if typeof(source["locale"]) != TYPE_STRING or not SUPPORTED_LOCALES.has(source["locale"]):
        return {"ok": false, "error": "unsupported language locale"}
    return {"ok": true, "error": "", "profile": {"schema_version": SCHEMA_VERSION, "locale": source["locale"]}}
