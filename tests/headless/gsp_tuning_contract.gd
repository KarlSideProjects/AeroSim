extends SceneTree

const HardwareConfig = preload("res://common/flight/hardware_config.gd")
const GspServer = preload("res://common/gsp/gsp_server.gd")

var _failures: Array[String] = []

func _init() -> void:
    var hardware := HardwareConfig.new()
    var registry := hardware.tuning_registry()
    _expect(registry.size() == 1, "Hardware schema exposes exactly one tuning descriptor")
    if registry.size() == 1:
        var descriptor: Dictionary = registry[0]
        for key in ["key", "type", "default", "min", "max", "step", "unit", "group", "owner", "apply_timing", "quick_adjust_eligible"]:
            _expect(descriptor.has(key), "tuning descriptor includes %s" % key)
    _expect(GspServer.validate_set_tuning_message(JSON.stringify({
        "v": 2, "t": "set_tuning", "seq": 1,
        "d": {"parameter": "simpleflight.rate_p", "value": 1.25}
    }), 0).get("ok", false), "valid tuning request is accepted")
    _expect(not GspServer.validate_set_tuning_message(JSON.stringify({
        "v": 2, "t": "set_tuning", "seq": 1,
        "d": {"parameter": "simpleflight.rate_p", "value": {}}
    }), 0).get("ok", false), "malformed tuning data is rejected")
    var panel := FileAccess.open("res://common/gsp/gsp_panel.html", FileAccess.READ)
    var panel_text := panel.get_as_text() if panel != null else ""
    _expect(panel_text.contains("registry.parameters"), "panel renders registry descriptors")
    _expect(panel_text.contains("set_tuning"), "panel sends generic tuning requests")
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
