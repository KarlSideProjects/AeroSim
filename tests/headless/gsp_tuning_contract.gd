extends SceneTree

const HardwareConfig = preload("res://common/flight/hardware_config.gd")
const GspServer = preload("res://common/gsp/gsp_server.gd")
const InputProfiles = preload("res://common/flight/input_profiles.gd")

var _failures: Array[String] = []

func _init() -> void:
    var hardware := HardwareConfig.new()
    var registry := hardware.tuning_registry()
    var serialized_once := hardware.tuning_registry_serialization()
    var serialized_twice := hardware.tuning_registry_serialization()
    var broad_hashing := HashingContext.new()
    broad_hashing.start(HashingContext.HASH_SHA256)
    broad_hashing.update(JSON.stringify(hardware.current).to_utf8_buffer())
    var broad_hash := broad_hashing.finish().hex_encode()
    _expect(serialized_once == serialized_twice and
            hardware.tuning_registry_hash().length() == 64 and hardware.tuning_registry_hash() != broad_hash,
            "canonical tuning serialization is deterministic and distinct from the broad config hash")
    _expect(registry.size() == 4, "Hardware schema exposes the initial four tuning descriptors")
    _expect(InputProfiles.QuickAdjustProfile.default_profile().slots.size() == 8, "Quick Adjust exposes eight binding slots")
    if registry.size() == 4:
        var descriptor: Dictionary = registry[0]
        for key in ["key", "type", "default", "min", "max", "step", "unit", "group", "owner", "apply_timing", "quick_adjust_eligible"]:
            _expect(descriptor.has(key), "tuning descriptor includes %s" % key)
    _expect(GspServer.validate_set_tuning_message(JSON.stringify({
        "v": 2, "t": "set_tuning", "seq": 1,
        "d": {"parameter": "simpleflight.rate_p", "value": 1.25}
    }), 0).get("ok", false), "valid tuning request is accepted")
    var batch := GspServer.validate_set_tuning_batch_message(JSON.stringify({
        "v": 2, "t": "set_tuning_batch", "seq": 1,
        "d": {"changes": [
            {"parameter": "simpleflight.rate_p", "value": 1.25},
            {"parameter": "simpleflight.rate_i", "value": 0.03}
        ]}
    }), 0)
    _expect(bool(batch.get("ok", false)), "valid tuning batch is accepted")
    _expect(GspServer.apply_timing_contract("next_physics_step", false, false).get("state") == "pending" and
            GspServer.apply_timing_contract("next_physics_step", true, false).get("mutates_now", false) and
            GspServer.apply_timing_contract("immediate", false, false).get("mutates_now", false) and
            not GspServer.apply_timing_contract("restart_required", false, false).get("mutates_now", true),
            "apply timing reports pending, immediate, and restart-required behavior honestly")
    _expect(not GspServer.validate_set_tuning_message(JSON.stringify({
        "v": 2, "t": "set_tuning", "seq": 1,
        "d": {"parameter": "simpleflight.rate_p", "value": {}}
    }), 0).get("ok", false), "malformed tuning data is rejected")
    var quick_profile := InputProfiles.QuickAdjustProfile.default_profile()
    quick_profile.slots[0] = {
        "parameter": "simpleflight.rate_p", "binding_type": "key_pair", "negative_key": KEY_Q, "positive_key": KEY_E,
        "mode": "relative", "subset_min": 0.6, "subset_max": 1.4, "deadzone": 0.05, "step": 0.01, "rate_limit": 30.0
    }
    var quick_message := GspServer.validate_set_quick_adjust_message(JSON.stringify({
        "v": 2, "t": "set_quick_adjust", "seq": 1, "d": {"profile": quick_profile}
    }), 0)
    _expect(bool(quick_message.get("ok", false)), "valid Quick Adjust profile is accepted")
    quick_profile.slots.resize(7)
    _expect(not bool(InputProfiles.QuickAdjustProfile.validate_profile(quick_profile).get("ok", false)), "Quick Adjust rejects non-eight-slot profiles")
    var panel := FileAccess.open("res://common/gsp/gsp_panel.html", FileAccess.READ)
    var panel_text := panel.get_as_text() if panel != null else ""
    _expect(panel_text.contains("registry.parameters"), "panel renders registry descriptors")
    _expect(panel_text.contains(".type = \"range\""), "panel renders schema-driven sliders")
    _expect(panel_text.contains("set_tuning_batch"), "panel supports schema-driven tuning batches")
    _expect(panel_text.contains("set_tuning"), "panel sends generic tuning requests")
    _expect(panel_text.contains("set_quick_adjust") and panel_text.contains("renderQuickAdjust") and panel_text.contains("rate_limit"),
            "panel configures registry-driven Quick Adjust slots")
    _expect(panel_text.contains("function cancelTransient") and panel_text.contains("cancelTransient(controls)"),
            "panel final sends cancel an outstanding transient timer")
    _expect(panel_text.contains("function rawTuningValue") and not panel_text.contains("function tuningValue"),
            "panel sends finite raw input for native clamp and quantization")
    _expect(not panel_text.contains("var parameterKey"), "panel does not introduce a hard-coded parameter key")
    if _failures.is_empty():
        print("GSP tuning contract: PASS")
        quit(0)
    else:
        for failure in _failures:
            push_error(failure)
        print("GSP tuning contract: FAIL")
        quit(1)

func _expect(condition: bool, message: String) -> void:
    if not condition:
        _failures.append(message)
