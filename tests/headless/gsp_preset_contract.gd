extends SceneTree

const GspPresetStore = preload("res://common/gsp/gsp_preset_store.gd")
const GspServer = preload("res://common/gsp/gsp_server.gd")
const HardwareConfig = preload("res://common/flight/hardware_config.gd")
const FlightRuntime = preload("res://common/flight/flight_runtime.gd")

var _failures: Array[String] = []
var _created_names: Array[String] = []
var _name_counter := 0


func _init() -> void:
    var store := GspPresetStore.new()
    var contract_name := _new_name(store, "contract")
    var tampered_name := _new_name(store, "tampered")
    var wrong_schema_name := _new_name(store, "wrong-schema")
    var schema_float_name := _new_name(store, "schema-float")
    var oversized_name := _new_name(store, "oversized")
    var malformed_name := _new_name(store, "malformed")
    var nonfinite_name := _new_name(store, "nonfinite")
    var runtime_name := _new_name(store, "runtime")
    var mismatch_name := _new_name(store, "mismatch")
    var truncated_name := _new_name(store, "truncated")
    var unknown_name := _new_name(store, "unknown")
    var ordered_name := _new_name(store, "ordered")
    var capability_name := _new_name(store, "capability")
    _expect(GspPresetStore.validate_name("race_01").get("ok", false), "ASCII preset names are accepted")
    for valid_name in ["-", "_", "-leading", "_leading", "x".repeat(64)]:
        _expect(bool(GspPresetStore.validate_name(valid_name).get("ok", false)),
                "valid ASCII preset name is accepted: %s" % valid_name)
    for invalid_name in ["", ".", "..", "../escape", "/absolute", "race/name", "race\\name", "rаce", "x".repeat(65)]:
        _expect(not bool(GspPresetStore.validate_name(invalid_name).get("ok", false)),
                "invalid preset name is rejected: %s" % invalid_name)

    var saved := store.save_preset(contract_name, {"simpleflight.rate_p": 1.2, "simpleflight.rate_i": 0.03},
            "registry-a", "test-sim", "contract note")
    if bool(saved.get("ok", false)):
        _remember_created(contract_name)
    _expect(bool(saved.get("ok", false)), "preset metadata saves atomically")
    var retrieved := store.retrieve_preset(contract_name)
    _expect(bool(retrieved.get("ok", false)) and retrieved.get("preset", {}).get("name", "") == contract_name and
            retrieved.get("preset", {}).get("values", {}).get("simpleflight.rate_p", 0.0) == 1.2 and
            retrieved.get("preset", {}).get("note", "") == "contract note",
            "preset metadata round-trips included values and note")
    _expect(int(retrieved.get("preset", {}).get("schema_version", -1)) == GspPresetStore.SCHEMA_VERSION,
            "preset metadata records the supported schema version")
    var overwritten := store.save_preset(contract_name, {"simpleflight.rate_p": 1.3, "simpleflight.rate_i": 0.04},
            "registry-b", "test-sim-2", "updated note")
    var overwritten_result := store.retrieve_preset(contract_name)
    _expect(bool(overwritten.get("ok", false)) and bool(overwritten_result.get("ok", false)) and
            float(overwritten_result.preset.values.get("simpleflight.rate_p", 0.0)) == 1.3 and
            overwritten_result.preset.note == "updated note",
            "saving an existing preset atomically overwrites its valid contents")
    _write_preset(tampered_name, JSON.stringify({
        "schema_version": 1,
        "name": tampered_name,
        "created_at": "now",
        "registry_hash": "registry-a",
        "sim_version": "test-sim",
        "values": {"simpleflight.rate_p": 1.0},
        "unexpected": true,
    }))
    _expect(not bool(store.retrieve_preset(tampered_name).get("ok", false)),
            "tampered preset with an unknown root field is rejected")
    _write_preset(wrong_schema_name, JSON.stringify({
        "schema_version": 2,
        "name": wrong_schema_name,
        "created_at": "now",
        "registry_hash": "registry-a",
        "sim_version": "test-sim",
        "values": {"simpleflight.rate_p": 1.0},
    }))
    _expect(not bool(store.retrieve_preset(wrong_schema_name).get("ok", false)),
            "unsupported preset schema is rejected")
    _write_preset(schema_float_name, JSON.stringify({
        "schema_version": 1.0,
        "name": schema_float_name,
        "created_at": "now",
        "registry_hash": "registry-a",
        "sim_version": "test-sim",
        "values": {"simpleflight.rate_p": 1.0},
    }))
    _expect(bool(store.retrieve_preset(schema_float_name).get("ok", false)),
            "JSON-parsed schema version 1.0 is accepted")
    var schema_fraction_name := _new_name(store, "schema-fraction")
    _write_preset(schema_fraction_name, JSON.stringify({
        "schema_version": 1.9,
        "name": schema_fraction_name,
        "created_at": "now",
        "registry_hash": "registry-a",
        "sim_version": "test-sim",
        "values": {"simpleflight.rate_p": 1.0},
    }))
    _expect(not bool(store.retrieve_preset(schema_fraction_name).get("ok", false)),
            "fractional unsupported schema version is rejected")
    _write_preset(oversized_name, "x".repeat(GspPresetStore.MAX_FILE_BYTES + 1))
    _expect(not bool(store.retrieve_preset(oversized_name).get("ok", false)),
            "oversized preset input is rejected before parsing")
    _write_preset(malformed_name, "{not-json")
    _expect(not bool(store.retrieve_preset(malformed_name).get("ok", false)),
            "malformed preset JSON is rejected")
    _write_preset(nonfinite_name, "{\"schema_version\":1,\"name\":\"%s\",\"created_at\":\"now\",\"registry_hash\":\"registry-a\",\"sim_version\":\"test-sim\",\"values\":{\"simpleflight.rate_p\":1e999}}" % nonfinite_name)
    _expect(not bool(store.retrieve_preset(nonfinite_name).get("ok", false)),
            "non-finite preset values are rejected")
    _expect(not bool(store.save_preset(contract_name, {"simpleflight.rate_p": 1.0}, "registry-a", "test-sim", "你".repeat(200)).get("ok", false)),
            "preset notes are bounded by UTF-8 bytes")
    var listed_names: Array = []
    for preset_value in store.list_presets().get("presets", []):
        listed_names.append(String(preset_value.get("name", "")))
    _expect(contract_name in listed_names, "preset listing is fixed-directory scoped")
    _expect(GspServer.validate_list_presets_message(JSON.stringify({"v": 2, "t": "list_presets", "seq": 1, "d": {}}), 0).get("ok", false),
            "GSP accepts a valid preset list request")
    _expect(GspServer.validate_load_preset_message(JSON.stringify({"v": 2, "t": "load_preset", "seq": 1, "d": {"name": "../escape"}}), 0).get("ok", false) == false,
            "GSP rejects traversal before preset path construction")
    _expect(GspServer.validate_save_preset_message(JSON.stringify({"v": 2, "t": "save_preset", "seq": 1, "d": {"name": "rаce"}}), 0).get("ok", false) == false,
            "GSP rejects Unicode lookalike names at the trust boundary")
    var migration_preview_message := JSON.stringify({"v": 2, "t": "preview_preset_migration", "seq": 1, "d": {"name": "race_01"}})
    var migration_apply_message := JSON.stringify({"v": 2, "t": "apply_preset_migration", "seq": 2, "d": {"name": "race_01", "migration_id": "opaque", "confirmed": true}})
    _expect(GspServer.validate_preset_message(migration_preview_message, 0, "preview_preset_migration").get("ok", false),
            "GSP accepts a migration preview request")
    _expect(GspServer.validate_preset_message(migration_apply_message, 1, "apply_preset_migration").get("ok", false),
            "GSP accepts only explicitly confirmed migration apply requests")
    _expect(not GspServer.validate_preset_message(JSON.stringify({"v": 2, "t": "apply_preset_migration", "seq": 2,
            "d": {"name": "race_01", "migration_id": "opaque", "confirmed": false}}), 1, "apply_preset_migration").get("ok", false),
            "GSP rejects migration apply without explicit confirmation")

    var migration_classification := GspPresetStore.classify_migration(
            {"removed.parameter": 8.0, "bounded.parameter": 99.0},
            [{"key": "bounded.parameter", "default": 2.0, "min": 0.0, "max": 10.0, "step": 0.1},
            {"key": "missing.parameter", "default": 3.0, "min": 0.0, "max": 10.0, "step": 0.1}])
    _expect(bool(migration_classification.get("ok", false)) and
            migration_classification.get("removed", []).size() == 1 and
            migration_classification.get("missing", []).size() == 1 and
            migration_classification.get("out_of_range", []).size() == 1 and
            float(migration_classification.out_of_range[0].get("original_value", -1.0)) == 99.0 and
            float(migration_classification.out_of_range[0].get("corrected_value", -1.0)) == 10.0 and
            float(migration_classification.values.get("bounded.parameter", -1.0)) == 10.0 and
            float(migration_classification.values.get("missing.parameter", -1.0)) == 3.0 and
            not migration_classification.values.has("removed.parameter"),
            "migration classification removes obsolete keys, fills defaults, and clamps with both values visible")

    var changes := GspPresetStore.diff_values(
            {"zero": 0.0, "same": 1.0, "positive": 2.0, "negative": -2.0, "sign": 1.0, "target_zero": 2.0, "tiny": 1.0, "tiny_sign": 1e-308, "overflow": 1e-10, "delta_overflow": -1e308},
            {"zero": 1.0, "same": 1.0, "positive": 3.0, "negative": -3.0, "sign": -1.0, "target_zero": 0.0, "tiny": 1.0 + 1e-12, "tiny_sign": -1e-308, "overflow": 1e308, "delta_overflow": 1e308})
    _expect(changes.size() == 9, "diff contains exact changes only, including tiny real changes")
    var by_key := {}
    for change_value in changes:
        by_key[change_value.parameter] = change_value
    var tiny_change: Dictionary = by_key.get("tiny", {})
    _expect(by_key.zero.percentage == null and by_key.zero.percentage_status == "zero_baseline" and
            by_key.sign.percentage == null and by_key.sign.percentage_status == "sign_change" and
            is_equal_approx(float(by_key.positive.percentage), 50.0) and
            is_equal_approx(float(by_key.negative.percentage), -50.0) and
            is_equal_approx(float(by_key.target_zero.percentage), -100.0) and
            tiny_change.has("percentage") and tiny_change.percentage_status == "finite" and
            is_finite(float(tiny_change.percentage)) and
            by_key.get("tiny_sign", {}).get("percentage", 0.0) == null and by_key.get("tiny_sign", {}).get("percentage_status", "") == "sign_change" and
            by_key.get("overflow", {}).get("percentage", 0.0) == null and by_key.get("overflow", {}).get("percentage_status", "") == "unrepresentable" and
            by_key.get("delta_overflow", {}).get("absolute", 0.0) == null and by_key.get("delta_overflow", {}).get("absolute_status", "") == "unrepresentable" and
            by_key.get("delta_overflow", {}).get("percentage", 0.0) == null and by_key.get("delta_overflow", {}).get("percentage_status", "") == "unrepresentable",
            "zero, sign-changing, tiny-opposite-sign, target-zero, and overflow cases stay explicit and finite")
    var one_sided_changes := GspPresetStore.diff_values({"only_left": 1.0}, {"only_right": 2.0})
    _expect(one_sided_changes.size() == 2 and one_sided_changes[0].percentage_status == "missing_value" and
            one_sided_changes[1].percentage_status == "missing_value",
            "one-sided diff keys remain explicit instead of becoming a false empty diff")

    var runtime := FlightRuntime.new()
    runtime.native = ClassDB.instantiate("AeroSimNative")
    var hardware := HardwareConfig.new()
    runtime._gsp_tuning_registry = hardware.tuning_registry()
    runtime._gsp_tuning_registry_hash = hardware.tuning_registry_hash()
    _expect(runtime.native != null and hardware.initialize_tuning(runtime), "preset runtime uses canonical tuning registry")
    if runtime.native != null:
        var runtime_saved: Dictionary = runtime.gsp_save_preset(runtime_name)
        if bool(runtime_saved.get("ok", false)):
            _remember_created(runtime_name)
        _expect(bool(runtime_saved.get("ok", false)),
                "runtime saves active registry values %s: %s" % [runtime_name, JSON.stringify(runtime_saved)])
        var mismatch_values: Dictionary = runtime_saved.get("preset", {}).get("values", {}).duplicate(true)
        var mismatch_saved := store.save_preset(mismatch_name, mismatch_values, "different-registry", "test-sim")
        if bool(mismatch_saved.get("ok", false)):
            _remember_created(mismatch_name)
        _expect(bool(mismatch_saved.get("ok", false)),
                "mismatched-registry preset fixture saves")
        var mismatch_before: Dictionary = runtime.native.call("flight_tuning_configuration")
        var mismatch_load: Dictionary = runtime.gsp_load_preset(-1, -1, 1, mismatch_name)
        var mismatch_after: Dictionary = runtime.native.call("flight_tuning_configuration")
        _expect(not bool(mismatch_load.get("ok", false)) and mismatch_load.get("error", "") == "registry_mismatch" and
                int(mismatch_after.get("commit_id", -1)) == int(mismatch_before.get("commit_id", -2)) and
                float(mismatch_after.get("simpleflight.rate_p", -1.0)) == float(mismatch_before.get("simpleflight.rate_p", -2.0)),
                "registry-mismatched load rejects without state or commit mutation")
        runtime.paused = true
        _expect(bool(runtime.gsp_tuning_request(-1, -1, 1, "simpleflight.rate_p", 1.2).get("ok", false)),
                "test mutation uses normal GSP tuning request")
        runtime.paused = false
        var before_load: Dictionary = runtime.native.call("flight_tuning_configuration")
        var loaded: Dictionary = runtime.gsp_load_preset(-1, -1, 2, runtime_name)
        var before_boundary: Dictionary = runtime.native.call("flight_tuning_configuration")
        runtime._apply_gsp_tuning_requests(9)
        var after_boundary: Dictionary = runtime.native.call("flight_tuning_configuration")
        _expect(bool(loaded.get("ok", false)) and bool(loaded.get("pending", false)) and
                float(before_boundary.get("simpleflight.rate_p", -1.0)) == 1.2 and
                float(after_boundary.get("simpleflight.rate_p", -1.0)) == 0.6 and
                int(after_boundary.get("commit_id", -1)) == int(before_load.get("commit_id", -2)) + 1,
                "active preset load remains unchanged until one atomic next-boundary commit: %s" % JSON.stringify(loaded))
        runtime.paused = true
        _expect(bool(runtime.gsp_tuning_request(-1, -1, 3, "simpleflight.rate_p", 1.2).get("ok", false)),
                "paused test mutation restores a changed active value")
        var immediate_before: Dictionary = runtime.native.call("flight_tuning_configuration")
        var immediate_load: Dictionary = runtime.gsp_load_preset(-1, -1, 4, runtime_name)
        var immediate_after: Dictionary = runtime.native.call("flight_tuning_configuration")
        _expect(bool(immediate_load.get("ok", false)) and not bool(immediate_load.get("pending", false)) and
                float(immediate_after.get("simpleflight.rate_p", -1.0)) == 0.6 and
                int(immediate_after.get("commit_id", -1)) == int(immediate_before.get("commit_id", -2)) + 1,
                "paused preset load commits immediately")
        var ordered_values := {}
        for index in range(runtime._gsp_tuning_registry.size() - 1, -1, -1):
            var descriptor: Dictionary = runtime._gsp_tuning_registry[index]
            var key := String(descriptor.get("key", ""))
            ordered_values[key] = float(immediate_after.get(key, 0.0))
        var ordered_saved: Dictionary = store.save_preset(ordered_name, ordered_values,
                runtime._gsp_tuning_registry_hash, "test-sim")
        if bool(ordered_saved.get("ok", false)):
            _remember_created(ordered_name)
        _expect(bool(ordered_saved.get("ok", false)), "reverse-ordered preset fixture saves")
        var truncated_values: Dictionary = runtime_saved.preset.values.duplicate(true)
        truncated_values.erase("simpleflight.rate_p")
        var truncated_saved := store.save_preset(truncated_name, truncated_values, runtime._gsp_tuning_registry_hash, "test-sim")
        if bool(truncated_saved.get("ok", false)):
            _remember_created(truncated_name)
        var unknown_values: Dictionary = runtime_saved.preset.values.duplicate(true)
        unknown_values["unknown.parameter"] = 1.0
        var unknown_saved := store.save_preset(unknown_name, unknown_values, runtime._gsp_tuning_registry_hash, "test-sim")
        if bool(unknown_saved.get("ok", false)):
            _remember_created(unknown_name)
        var malformed_before: Dictionary = runtime.native.call("flight_tuning_configuration")
        var truncated_load := runtime.gsp_load_preset(-1, -1, 5, truncated_name)
        var truncated_compare := runtime.gsp_compare_presets(truncated_name, "")
        var unknown_load := runtime.gsp_load_preset(-1, -1, 6, unknown_name)
        var malformed_after: Dictionary = runtime.native.call("flight_tuning_configuration")
        _expect(not bool(truncated_load.get("ok", false)) and not bool(truncated_compare.get("ok", false)) and
                not bool(unknown_load.get("ok", false)) and
                int(malformed_after.get("commit_id", -1)) == int(malformed_before.get("commit_id", -2)) and
                float(malformed_after.get("simpleflight.rate_p", -1.0)) == float(malformed_before.get("simpleflight.rate_p", -2.0)),
                "matching-hash incomplete or unknown key sets reject load and compare without mutation")
        var ordered_load: Dictionary = runtime.gsp_load_preset(-1, -1, 7, ordered_name)
        var ordered_changes: Array = ordered_load.get("changes", [])
        var registry_ordered := (
                bool(ordered_saved.get("ok", false)) and bool(ordered_load.get("ok", false)) and
                not ordered_changes.is_empty() and ordered_changes.size() == runtime._gsp_tuning_registry.size())
        for index in ordered_changes.size():
            if (index >= runtime._gsp_tuning_registry.size() or
                    String(ordered_changes[index].get("parameter", "")) != String(runtime._gsp_tuning_registry[index].get("key", ""))):
                registry_ordered = false
        _expect(registry_ordered, "preset save/load has non-empty changes in canonical registry order")
        _expect(bool(runtime.gsp_tuning_request(-1, -1, 6, "simpleflight.rate_p", 1.2).get("ok", false)) and
                runtime.gsp_compare_presets("", runtime_name).get("changes", []).size() == 1,
                "current-versus-preset diff reports changed values only")
        var capability_values: Dictionary = runtime_saved.preset.values.duplicate(true)
        var capability_saved := store.save_preset(capability_name, capability_values, "previous-registry", "test-sim")
        if bool(capability_saved.get("ok", false)):
            _remember_created(capability_name)
        _expect(bool(capability_saved.get("ok", false)), "migration capability fixture saves")
        var capability_preview: Dictionary = runtime.gsp_preview_preset_migration(capability_name)
        var migration_id := String(capability_preview.get("migration_id", ""))
        var unchanged_before_invalid: Dictionary = runtime.native.call("flight_tuning_configuration")
        var wrong_apply := runtime.gsp_apply_preset_migration(-1, -1, 10, capability_name, "wrong-id", true)
        var missing_apply := runtime.gsp_apply_preset_migration(-1, -1, 11, capability_name, "", true)
        _expect(wrong_apply.get("error", "") == "migration_wrong" and missing_apply.get("error", "") == "migration_missing" and
                int(runtime.native.call("flight_tuning_configuration").get("commit_id", -1)) == int(unchanged_before_invalid.get("commit_id", -2)),
                "wrong and missing migration identifiers are rejected read-only")
        runtime._gsp_migration_capabilities[0].expires_at_ms = 0
        var expired_apply := runtime.gsp_apply_preset_migration(-1, -1, 12, capability_name, migration_id, true)
        _expect(expired_apply.get("error", "") == "migration_expired", "expired migration identifier is rejected")
        var fresh_capability: Dictionary = runtime.gsp_preview_preset_migration(capability_name)
        var fresh_migration_id := String(fresh_capability.get("migration_id", ""))
        var unconfirmed_apply := runtime.gsp_apply_preset_migration(-1, -1, 13, capability_name, fresh_migration_id, false)
        _expect(unconfirmed_apply.get("error", "") == "migration_confirmation_required", "unconfirmed migration is rejected")
        var registry_stale_preview: Dictionary = runtime.gsp_preview_preset_migration(capability_name)
        var registry_stale_id := String(registry_stale_preview.get("migration_id", ""))
        var original_registry_hash := runtime._gsp_tuning_registry_hash
        runtime._gsp_tuning_registry_hash = "changed-registry"
        var registry_stale_apply := runtime.gsp_apply_preset_migration(-1, -1, 14, capability_name, registry_stale_id, true)
        runtime._gsp_tuning_registry_hash = original_registry_hash
        _expect(registry_stale_apply.get("error", "") == "migration_stale", "registry changes stale migration capability")
        var committed_migration := runtime.gsp_apply_preset_migration(-1, -1, 14, capability_name, fresh_migration_id, true)
        var reused_migration := runtime.gsp_apply_preset_migration(-1, -1, 15, capability_name, fresh_migration_id, true)
        _expect(bool(committed_migration.get("ok", false)) and reused_migration.get("error", "") == "migration_reused",
                "accepted migration capability is single-use")

    var panel := FileAccess.open("res://common/gsp/gsp_panel.html", FileAccess.READ)
    var panel_text := panel.get_as_text() if panel != null else ""
    for required in ["list_presets", "save_preset", "retrieve_preset", "load_preset", "compare_presets",
            "preview_preset_migration", "apply_preset_migration", "preset-diff", "migration-report",
            "registry_hash", "created_at", "percentage_status", "original_value", "corrected_value"]:
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
    for name in _created_names:
        var path := GspPresetStore.preset_path(name)
        if not path.is_empty():
            DirAccess.remove_absolute(path)


func _new_name(store: GspPresetStore, prefix: String) -> String:
    for _attempt in 100:
        _name_counter += 1
        var candidate := "%s-%d-%d-%d" % [prefix, OS.get_process_id(), Time.get_ticks_usec(), _name_counter]
        if candidate.length() > GspPresetStore.NAME_MAX_LENGTH:
            candidate = candidate.substr(0, GspPresetStore.NAME_MAX_LENGTH)
        var path := GspPresetStore.preset_path(candidate)
        if not path.is_empty() and not FileAccess.file_exists(path):
            return candidate
    return ""


func _remember_created(name: String) -> void:
    if not name.is_empty() and name not in _created_names:
        _created_names.append(name)


func _write_preset(name: String, contents: String) -> void:
    var path := GspPresetStore.preset_path(name)
    var file := FileAccess.open(path, FileAccess.WRITE)
    if file != null:
        file.store_string(contents)
        file.close()
        _remember_created(name)
