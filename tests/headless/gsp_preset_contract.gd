extends SceneTree

const GspPresetStore = preload("res://common/gsp/gsp_preset_store.gd")
const GspServer = preload("res://common/gsp/gsp_server.gd")
const HardwareConfig = preload("res://common/flight/hardware_config.gd")
const FlightRuntime = preload("res://common/flight/flight_runtime.gd")

var _failures: Array[String] = []


func _init() -> void:
    var store := GspPresetStore.new()
    _remove_known(["contract", "runtime_contract"])
    _expect(GspPresetStore.validate_name("race_01").get("ok", false), "ASCII preset names are accepted")
    for invalid_name in ["", ".", "..", "../escape", "race/name", "race\\name", "rаce", "x".repeat(65)]:
        _expect(not bool(GspPresetStore.validate_name(invalid_name).get("ok", false)),
                "invalid preset name is rejected: %s" % invalid_name)

    var saved := store.save_preset("contract", {"simpleflight.rate_p": 1.2, "simpleflight.rate_i": 0.03},
            "registry-a", "test-sim", "contract note")
    _expect(bool(saved.get("ok", false)), "preset metadata saves atomically")
    var retrieved := store.retrieve_preset("contract")
    _expect(bool(retrieved.get("ok", false)) and retrieved.get("preset", {}).get("name", "") == "contract" and
            retrieved.get("preset", {}).get("values", {}).get("simpleflight.rate_p", 0.0) == 1.2 and
            retrieved.get("preset", {}).get("note", "") == "contract note",
            "preset metadata round-trips included values and note")
    var listed_names: Array = []
    for preset_value in store.list_presets().get("presets", []):
        listed_names.append(String(preset_value.get("name", "")))
    _expect("contract" in listed_names, "preset listing is fixed-directory scoped")
    _expect(GspServer.validate_list_presets_message(JSON.stringify({"v": 2, "t": "list_presets", "seq": 1, "d": {}}), 0).get("ok", false),
            "GSP accepts a valid preset list request")
    _expect(GspServer.validate_load_preset_message(JSON.stringify({"v": 2, "t": "load_preset", "seq": 1, "d": {"name": "../escape"}}), 0).get("ok", false) == false,
            "GSP rejects traversal before preset path construction")
    _expect(GspServer.validate_save_preset_message(JSON.stringify({"v": 2, "t": "save_preset", "seq": 1, "d": {"name": "rаce"}}), 0).get("ok", false) == false,
            "GSP rejects Unicode lookalike names at the trust boundary")

    var changes := GspPresetStore.diff_values(
            {"zero": 0.0, "same": 1.0, "positive": 2.0, "sign": 1.0},
            {"zero": 1.0, "same": 1.0, "positive": 3.0, "sign": -1.0})
    _expect(changes.size() == 3, "diff contains changes only")
    var by_key := {}
    for change_value in changes:
        by_key[change_value.parameter] = change_value
    _expect(by_key.zero.percentage == null and by_key.zero.percentage_status == "zero_baseline" and
            by_key.sign.percentage == null and by_key.sign.percentage_status == "sign_change" and
            is_equal_approx(float(by_key.positive.percentage), 50.0),
            "zero and sign-changing percentage baselines stay explicit and finite")

    var runtime := FlightRuntime.new()
    runtime.native = ClassDB.instantiate("AeroSimNative")
    var hardware := HardwareConfig.new()
    runtime._gsp_tuning_registry = hardware.tuning_registry()
    runtime._gsp_tuning_registry_hash = hardware.tuning_registry_hash()
    _expect(runtime.native != null and hardware.initialize_tuning(runtime), "preset runtime uses canonical tuning registry")
    if runtime.native != null:
        var runtime_saved: Dictionary = runtime.gsp_save_preset("runtime_contract")
        _expect(bool(runtime_saved.get("ok", false)),
                "runtime saves active registry values: %s" % JSON.stringify(runtime_saved))
        runtime.paused = true
        _expect(bool(runtime.gsp_tuning_request(-1, -1, 1, "simpleflight.rate_p", 1.2).get("ok", false)),
                "test mutation uses normal GSP tuning request")
        var before_load: Dictionary = runtime.native.call("flight_tuning_configuration")
        var loaded: Dictionary = runtime.gsp_load_preset(-1, -1, 2, "runtime_contract")
        var after_load: Dictionary = runtime.native.call("flight_tuning_configuration")
        _expect(bool(loaded.get("ok", false)) and float(after_load.get("simpleflight.rate_p", -1.0)) == 0.6 and
                int(after_load.get("commit_id", -1)) > int(before_load.get("commit_id", -2)),
                "preset load commits through the native tuning path: %s" % JSON.stringify(loaded))
        _expect(bool(runtime.gsp_tuning_request(-1, -1, 3, "simpleflight.rate_p", 1.2).get("ok", false)) and
                runtime.gsp_compare_presets("", "runtime_contract").get("changes", []).size() == 1,
                "current-versus-preset diff reports changed values only")

    var panel := FileAccess.open("res://common/gsp/gsp_panel.html", FileAccess.READ)
    var panel_text := panel.get_as_text() if panel != null else ""
    for required in ["list_presets", "save_preset", "retrieve_preset", "load_preset", "compare_presets",
            "preset-diff", "registry_hash", "created_at", "percentage_status"]:
        _expect(panel_text.contains(required), "panel supports %s" % required)

    _cleanup()
    if _failures.is_empty():
        print("GSP preset contract: PASS")
        quit(0)
        return
    for failure in _failures:
        push_error(failure)
    print("GSP preset contract: FAIL")
    quit(1)


func _expect(condition: bool, message: String) -> void:
    if not condition:
        _failures.append(message)


func _cleanup() -> void:
    _remove_known(["contract", "runtime_contract"])


func _remove_known(names: Array) -> void:
    for name in names:
        var path := GspPresetStore.preset_path(String(name))
        if not path.is_empty():
            DirAccess.remove_absolute(path)
