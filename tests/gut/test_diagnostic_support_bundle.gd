extends GutTest

const Bundle = preload("res://common/diagnostics/diagnostic_support_bundle.gd")

var output_path := "user://aerosim-diagnostic-support-bundle-test.zip"


func after_each() -> void:
    DirAccess.remove_absolute(output_path)
    DirAccess.remove_absolute("%s.tmp" % output_path)


func _context() -> Dictionary:
    return {
        "build": {"hash": "abc123", "app_version": "0.1.0"},
        "platform": {"distribution": "Ubuntu", "version": "26.04"},
        "gpu": {"vendor": "NVIDIA", "name": "Test GPU", "api": "Vulkan"},
        "controller": {
            "connected": true,
            "known": true,
            "confirmed": true,
            "usb_vendor_id": 1118,
            "usb_product_id": 654,
            "mapping": {
                "profile_schema_version": 1,
                "axis_for_role": {"roll": 0, "pitch": 1, "yaw": 2, "throttle": 3},
                "reversed_for_role": {"roll": false, "pitch": true, "yaw": false, "throttle": false},
                "arm_button": 0,
                "mode_button": 3,
                "deadzone": 0.08,
            },
        },
        "license": {"status": "offline_grace_valid", "offline_grace_remaining_seconds": 120},
        "last_error_code": "controller_disconnected",
    }


func _sample(index: int) -> Dictionary:
    return {
        "roll": 0.1,
        "pitch": -0.2,
        "yaw": 0.3,
        "throttle": 0.4,
        "arm": index % 2 == 0,
        "mode": index % 3 == 0,
    }


func test_document_is_allowlisted_and_bounded_to_recent_named_data() -> void:
    var bundle = Bundle.new()
    for index in range(250):
        bundle.record_event("event_%03d" % index, float(index))
    for index in range(200):
        bundle.record_raw_sample(245.0 + float(index) / 30.0, _sample(index))

    var document: Dictionary = bundle.build_document(_context(), 251.6666)

    assert_true(bundle.audit_document(document).ok)
    assert_eq(document.keys(), ["schema_version", "build", "platform", "gpu", "controller", "license", "last_error_code", "events", "raw_samples"])
    assert_eq(document.events.size(), 200)
    assert_eq(document.events[0].code, "event_050")
    assert_eq(document.raw_samples.size(), 150)
    assert_eq(document.controller.mapping.schema_version, 1)
    assert_eq(document.controller.mapping.button_roles, {"arm": 0, "mode": 3})
    assert_eq(document.license, {"state": "offline_grace_valid", "remaining_seconds": 120})
    assert_true(float(document.raw_samples[0].time_seconds) < 0.0)
    assert_true(float(document.raw_samples.back().time_seconds) <= 0.0)
    assert_false(document.raw_samples[0].has("wall_clock"))


func test_audit_rejects_unknown_types_and_secret_or_pii_canaries() -> void:
    var bundle = Bundle.new()
    var unknown: Dictionary = bundle.build_document(_context(), 0.0)
    unknown["future"] = true
    assert_false(bundle.audit_document(unknown).ok)

    var wrong_type: Dictionary = bundle.build_document(_context(), 0.0)
    wrong_type["controller"]["connected"] = "true"
    assert_false(bundle.audit_document(wrong_type).ok)

    var canary: Dictionary = bundle.build_document(_context(), 0.0)
    canary["build"]["hash"] = "eyJhbGciOiJSUzI1NiJ9.canary.signature"
    assert_false(bundle.audit_document(canary).ok)

    var pii: Dictionary = bundle.build_document(_context(), 0.0)
    pii["platform"]["version"] = "/home/alice/aerosim"
    assert_false(bundle.audit_document(pii).ok)


func test_checked_in_schema_has_the_same_allowlisted_root() -> void:
    var schema: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://config/diagnostic_support_schema.json"))
    assert_true(typeof(schema) == TYPE_DICTIONARY)
    assert_eq(schema.properties.keys(), ["schema_version", "build", "platform", "gpu", "controller", "license", "last_error_code", "events", "raw_samples"])
    assert_false(schema.additionalProperties)


func test_export_is_one_member_and_failure_leaves_no_zip() -> void:
    var bundle = Bundle.new()
    bundle.record_event("startup", 10.0)
    var exported: Dictionary = bundle.export_bundle(output_path, _context(), 10.0)
    assert_true(exported.ok, exported.get("error", ""))

    var reader := ZIPReader.new()
    assert_eq(reader.open(output_path), OK)
    assert_eq(reader.get_files().size(), 1)
    assert_true(reader.get_files().has("support.json"))
    var parsed: Variant = JSON.parse_string(reader.read_file("support.json").get_string_from_utf8())
    reader.close()
    assert_true(typeof(parsed) == TYPE_DICTIONARY)
    assert_eq(parsed.events[0].code, "startup")

    var oversized := _context()
    oversized.build.hash = "x".repeat(256 * 1024)
    var rejected_path := "%s.oversized.zip" % output_path
    var stale_temp := FileAccess.open("%s.tmp" % rejected_path, FileAccess.WRITE)
    stale_temp.store_string("stale")
    stale_temp.close()
    var rejected: Dictionary = bundle.export_bundle(rejected_path, oversized, 10.0)
    assert_false(rejected.ok)
    assert_false(FileAccess.file_exists("%s.tmp" % rejected_path))
    assert_false(FileAccess.file_exists(rejected_path))
    assert_true(FileAccess.file_exists(output_path))
    DirAccess.remove_absolute(rejected_path)
