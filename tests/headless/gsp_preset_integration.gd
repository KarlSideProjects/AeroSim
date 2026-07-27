extends SceneTree

const AirSimSession = preload("res://common/rpc/airsim_session.gd")
const FlightRuntime = preload("res://common/flight/flight_runtime.gd")
const GspPresetStore = preload("res://common/gsp/gsp_preset_store.gd")
const GspServer = preload("res://common/gsp/gsp_server.gd")
const HardwareConfig = preload("res://common/flight/hardware_config.gd")

var _runtime: FlightRuntime
var _server: GspServer
var _origin := WebSocketPeer.new()
var _observer := WebSocketPeer.new()
var _failures: Array[String] = []
var _created_names: Array[String] = []
var _name_counter := 0


func _init() -> void:
    await _run()


func _run() -> void:
    _runtime = FlightRuntime.new()
    _runtime.native = ClassDB.instantiate("AeroSimNative")
    _runtime.airsim_session = AirSimSession.new(240)
    _runtime._airsim_vehicle_name = "DroneA"
    _runtime._airsim_vehicle_names = ["DroneA"]
    var hardware := HardwareConfig.new()
    _runtime._gsp_tuning_registry = hardware.tuning_registry()
    _runtime._gsp_tuning_registry_hash = hardware.tuning_registry_hash()
    _expect(_runtime.native != null and hardware.initialize_tuning(_runtime), "preset integration initializes native tuning")
    if _runtime.native == null:
        _finish()
        return

    var baseline_name := _new_name("integration")
    var second_name := _new_name("integration-second")
    var migration_name := _new_name("integration-migration")
    _expect(not baseline_name.is_empty() and not second_name.is_empty() and not migration_name.is_empty() and
            baseline_name != second_name and baseline_name != migration_name and second_name != migration_name,
            "integration allocates distinct collision-safe preset names")
    var active_values: Dictionary = _runtime.native.call("flight_tuning_configuration")
    var migration_values: Dictionary = {}
    for descriptor_value in _runtime._gsp_tuning_registry:
        var descriptor: Dictionary = descriptor_value
        var key := String(descriptor.get("key", ""))
        migration_values[key] = active_values.get(key, descriptor.get("default", 0.0))
    migration_values.erase("simpleflight.rate_i")
    migration_values["obsolete.parameter"] = 9.0
    migration_values["simpleflight.rate_p"] = 99.0
    var expected_migration_values := {
        "simpleflight.rate_p": 2.0,
        "simpleflight.angle_p": 15.0,
        "simpleflight.rate_i": 0.02,
        "simpleflight.rate_d": 0.005,
    }
    var migration_saved := GspPresetStore.new().save_preset(migration_name, migration_values, "old-registry", "test-sim")
    if bool(migration_saved.get("ok", false)):
        _remember_created(migration_name)
    _expect(bool(migration_saved.get("ok", false)), "mismatched preset fixture saves for migration preview")
    _server = GspServer.new()
    root.add_child(_server)
    _server.set_identity_provider(Callable(_runtime, "gsp_identity_snapshot"))
    _server.set_tuning_request_provider(Callable(_runtime, "gsp_tuning_request"))
    _server.set_tuning_result_provider(Callable(_runtime, "gsp_tuning_results"))
    _server.set_preset_request_provider(Callable(_runtime, "gsp_preset_request"))
    var started: Dictionary = _server.start()
    _server.set_process(false)
    _expect(bool(started.get("ok", false)), "preset GSP server starts")
    if not bool(started.get("ok", false)):
        _finish()
        return

    await _connect_and_auth(_origin, int(started.port), String(started.token))
    await _connect_and_auth(_observer, int(started.port), String(started.token))
    _expect(not (await _next_message_type(_origin, "hello", 240)).is_empty(), "origin receives hello")
    _expect(not (await _next_message_type(_observer, "hello", 240)).is_empty(), "observer receives hello")

    _expect(_origin.send_text(JSON.stringify({"v": 2, "t": "save_preset", "seq": 1,
            "d": {"name": baseline_name, "note": "first"}})) == OK,
            "preset save request sends")
    _server.poll()
    var saved: Dictionary = await _next_message_type(_origin, "preset_ack", 240)
    if bool(saved.get("d", {}).get("ok", false)):
        _remember_created(baseline_name)
    _expect(bool(saved.get("d", {}).get("ok", false)) and
            saved.get("d", {}).get("preset", {}).get("name", "") == baseline_name,
            "preset save returns metadata")

    _expect(_origin.send_text(JSON.stringify({"v": 2, "t": "retrieve_preset", "seq": 2,
            "d": {"name": baseline_name}})) == OK,
            "preset retrieve request sends")
    _server.poll()
    var retrieved: Dictionary = await _next_message_type(_origin, "preset_ack", 240)
    _expect(retrieved.get("d", {}).get("preset", {}).get("note", "") == "first" and
            retrieved.get("d", {}).get("preset", {}).get("registry_hash", "") == _runtime._gsp_tuning_registry_hash,
            "preset retrieve preserves metadata and registry hash")

    _runtime.paused = true
    _expect(bool(_runtime.gsp_tuning_request(-1, -1, 1, "simpleflight.rate_p", 1.2).get("ok", false)),
            "integration mutates current through tuning authority")
    _expect(_origin.send_text(JSON.stringify({"v": 2, "t": "save_preset", "seq": 3,
            "d": {"name": second_name, "note": "second"}})) == OK,
            "second preset save request sends through the authenticated peer")
    _server.poll()
    var second_saved: Dictionary = await _next_message_type(_origin, "preset_ack", 240)
    if bool(second_saved.get("d", {}).get("ok", false)):
        _remember_created(second_name)
    var baseline_rate := float(saved.get("d", {}).get("preset", {}).get("values", {}).get("simpleflight.rate_p", -1.0))
    var second_rate := float(second_saved.get("d", {}).get("preset", {}).get("values", {}).get("simpleflight.rate_p", -1.0))
    _expect(bool(second_saved.get("d", {}).get("ok", false)) and baseline_rate != second_rate,
            "second preset saves a distinct changed tuning value")
    _expect(_origin.send_text(JSON.stringify({"v": 2, "t": "compare_presets", "seq": 4,
            "d": {"left": baseline_name, "right": second_name}})) == OK,
            "preset comparison request sends through the authenticated peer")
    _server.poll()
    var comparison: Dictionary = await _next_message_type(_origin, "preset_ack", 240)
    var comparison_data: Dictionary = comparison.get("d", {})
    var comparison_changes: Array = comparison_data.get("changes", [])
    var comparison_change: Dictionary = comparison_changes[0] if comparison_changes.size() == 1 else {}
    var percentage = comparison_change.get("percentage", null)
    _expect(comparison_data.get("operation", "") == "compare_presets" and
            int(comparison_data.get("request_seq", -1)) == 4 and
            bool(comparison_data.get("ok", false)) and comparison_changes.size() == 1 and
            comparison_change.get("parameter", "") == "simpleflight.rate_p" and
            comparison_change.has("percentage") and comparison_change.get("percentage_status", "") == "finite" and
            typeof(percentage) in [TYPE_INT, TYPE_FLOAT] and is_finite(float(percentage)),
            "real backend preset comparison returns an acknowledged changed-only finite percentage row")
    _runtime.paused = false
    var before_preview: Dictionary = _runtime.native.call("flight_tuning_configuration")
    _expect(_origin.send_text(JSON.stringify({"v": 2, "t": "preview_preset_migration", "seq": 5,
            "d": {"name": migration_name}})) == OK,
            "migration preview request sends through the authenticated peer")
    _server.poll()
    var preview: Dictionary = await _next_message_type(_origin, "preset_ack", 240)
    var preview_data: Dictionary = preview.get("d", {})
    var after_preview: Dictionary = _runtime.native.call("flight_tuning_configuration")
    _expect(bool(preview_data.get("ok", false)) and String(preview_data.get("migration_id", "")).length() >= 64 and
            preview_data.get("removed", []).size() == 1 and preview_data.get("missing", []).size() == 1 and
            preview_data.get("out_of_range", []).size() == 1 and
            float(preview_data.out_of_range[0].get("original_value", 0.0)) == 99.0 and
            float(preview_data.out_of_range[0].get("corrected_value", 0.0)) == 2.0 and
            int(after_preview.get("commit_id", -1)) == int(before_preview.get("commit_id", -2)) and
            float(after_preview.get("simpleflight.rate_p", -1.0)) == float(before_preview.get("simpleflight.rate_p", -2.0)),
            "migration preview classifies all changes without mutating native active memory")

    var stale_values: Dictionary = migration_values.duplicate(true)
    stale_values["simpleflight.rate_p"] = 1.1
    _expect(bool(GspPresetStore.new().save_preset(migration_name, stale_values, "old-registry", "test-sim").get("ok", false)),
            "migration fixture changes after preview")
    _expect(_origin.send_text(JSON.stringify({"v": 2, "t": "apply_preset_migration", "seq": 6,
            "d": {"name": migration_name, "migration_id": preview_data.get("migration_id", ""), "confirmed": true}})) == OK,
            "stale migration apply request sends")
    _server.poll()
    var stale_apply: Dictionary = await _next_message_type(_origin, "tuning_ack", 240)
    var after_stale_apply: Dictionary = _runtime.native.call("flight_tuning_configuration")
    _expect(stale_apply.get("d", {}).get("error", "") == "migration_stale" and
            int(after_stale_apply.get("commit_id", -1)) == int(before_preview.get("commit_id", -2)),
            "stale migration identifier is rejected without a commit")

    var fresh_values: Dictionary = migration_values.duplicate(true)
    fresh_values["simpleflight.rate_p"] = 99.0
    _expect(bool(GspPresetStore.new().save_preset(migration_name, fresh_values, "old-registry", "test-sim").get("ok", false)),
            "fresh migration fixture restores the previewed content")
    _expect(_origin.send_text(JSON.stringify({"v": 2, "t": "preview_preset_migration", "seq": 7,
            "d": {"name": migration_name}})) == OK,
            "fresh migration preview request sends")
    _server.poll()
    var fresh_preview: Dictionary = await _next_message_type(_origin, "preset_ack", 240)
    var fresh_preview_data: Dictionary = fresh_preview.get("d", {})
    var before_apply: Dictionary = _runtime.native.call("flight_tuning_configuration")
    _expect(_origin.send_text(JSON.stringify({"v": 2, "t": "apply_preset_migration", "seq": 8,
            "d": {"name": migration_name, "migration_id": fresh_preview_data.get("migration_id", ""), "confirmed": true}})) == OK,
            "confirmed migration apply request sends")
    _server.poll()
    var early_migration_ack := await _next_message_type(_origin, "tuning_ack", 20)
    _expect(early_migration_ack.is_empty() and
            int(_runtime.native.call("flight_tuning_configuration").get("commit_id", -1)) == int(before_apply.get("commit_id", -2)),
            "confirmed migration apply defers its atomic commit to the physics boundary")
    _runtime._apply_gsp_tuning_requests(10)
    _server.poll()
    var migration_ack: Dictionary = await _next_message_type(_origin, "tuning_ack", 240)
    var migration_commit: Dictionary = await _next_message_type(_origin, "tuning_commit", 240)
    var observer_migration_commit: Dictionary = await _next_message_type(_observer, "tuning_commit", 240)
    var migration_ack_data: Dictionary = migration_ack.get("d", {})
    var migration_commit_data: Dictionary = migration_commit.get("d", {})
    var observer_migration_commit_data: Dictionary = observer_migration_commit.get("d", {})
    var migration_rate_p_change: Dictionary = {}
    for change_value in migration_ack_data.get("changes", []):
        if String(change_value.get("parameter", "")) == "simpleflight.rate_p":
            migration_rate_p_change = change_value
            break
    _expect(bool(migration_ack_data.get("ok", false)) and String(migration_ack_data.get("source", "")) == "preset" and
            migration_ack_data.get("committed_values", {}) == expected_migration_values and
            migration_commit_data.get("committed_values", {}) == expected_migration_values and
            float(migration_rate_p_change.get("requested_value", 0.0)) == 99.0 and
            float(migration_rate_p_change.get("committed_value", 0.0)) == 2.0 and
            bool(migration_rate_p_change.get("clamped", false)) and
            int(migration_commit_data.get("commit_id", -1)) == int(observer_migration_commit_data.get("commit_id", -2)) and
            String(observer_migration_commit_data.get("source", "")) == "preset",
            "confirmed migration stages requested values, preserves clamp provenance, and broadcasts the authoritative preset commit")

    _expect(_origin.send_text(JSON.stringify({"v": 2, "t": "apply_preset_migration", "seq": 9,
            "d": {"name": migration_name, "migration_id": "wrong-migration-id", "confirmed": true}})) == OK,
            "wrong migration identifier request sends on the existing peer")
    _server.poll()
    var wrong_migration_ack: Dictionary = await _next_message_type(_origin, "tuning_ack", 240)
    _expect(String(wrong_migration_ack.get("d", {}).get("error", "")) == "migration_wrong" and
            _origin.get_ready_state() == WebSocketPeer.STATE_OPEN,
            "wrong migration identifier is a business error and keeps the peer connected")
    _expect(_origin.send_text(JSON.stringify({"v": 2, "t": "apply_preset_migration", "seq": 10,
            "d": {"name": migration_name, "migration_id": fresh_preview_data.get("migration_id", ""), "confirmed": true}})) == OK,
            "reused migration identifier request sends on the existing peer")
    _server.poll()
    var reused_migration_ack: Dictionary = await _next_message_type(_origin, "tuning_ack", 240)
    _expect(String(reused_migration_ack.get("d", {}).get("error", "")) == "migration_reused" and
            _origin.get_ready_state() == WebSocketPeer.STATE_OPEN,
            "reused migration identifier is a business error and keeps the peer connected")
    _expect(_origin.send_text(JSON.stringify({"v": 2, "t": "retrieve_preset", "seq": 11,
            "d": {"name": migration_name}})) == OK,
            "peer accepts a subsequent preset request after migration business errors")
    _server.poll()
    var after_error_retrieve: Dictionary = await _next_message_type(_origin, "preset_ack", 240)
    _expect(bool(after_error_retrieve.get("d", {}).get("ok", false)),
            "peer remains usable after wrong and reused migration identifiers")

    _runtime.paused = true
    _expect(bool(_runtime.gsp_tuning_request(-1, -1, 20, "simpleflight.rate_p", 0.6).get("ok", false)),
            "competition fixture moves active tuning away from the migration target")
    _runtime.paused = false
    _expect(_origin.send_text(JSON.stringify({"v": 2, "t": "preview_preset_migration", "seq": 12,
            "d": {"name": migration_name}})) == OK,
            "same-tick barrier migration preview sends")
    _server.poll()
    var barrier_preview: Dictionary = await _next_message_type(_origin, "preset_ack", 240)
    var barrier_id := String(barrier_preview.get("d", {}).get("migration_id", ""))
    var ordinary_descriptor: Dictionary = _runtime._gsp_tuning_registry[1]
    var ordinary_key := String(ordinary_descriptor.get("key", ""))
    var ordinary_before := float(_runtime.native.call("flight_tuning_configuration").get(ordinary_key, ordinary_descriptor.get("default", 0.0)))
    var ordinary_step := float(ordinary_descriptor.get("step", 0.01))
    var ordinary_value := ordinary_before + ordinary_step
    if ordinary_value > float(ordinary_descriptor.get("max", ordinary_value)):
        ordinary_value = ordinary_before - ordinary_step
    _expect(_observer.send_text(JSON.stringify({"v": 2, "t": "set_tuning", "seq": 1,
            "d": {"parameter": ordinary_key, "value": ordinary_value}})) == OK,
            "same-tick ordinary tuning request sends from the observer peer")
    _expect(_observer.send_text(JSON.stringify({"v": 2, "t": "set_tuning", "seq": 2,
            "d": {"parameter": "simpleflight.rate_p", "value": 1.1}})) == OK,
            "same-tick ordinary request for a previewed key sends from the observer peer")
    _server.poll()
    _expect(_origin.send_text(JSON.stringify({"v": 2, "t": "apply_preset_migration", "seq": 13,
            "d": {"name": migration_name, "migration_id": barrier_id, "confirmed": true}})) == OK,
            "same-tick migration barrier request sends from the origin peer")
    _server.poll()
    _runtime._apply_gsp_tuning_requests(12)
    _server.poll()
    var barrier_migration_ack: Dictionary = await _next_message_type(_origin, "tuning_ack", 240)
    var ordinary_origin_commit: Dictionary = await _next_message_type(_origin, "tuning_commit", 240)
    var barrier_origin_commit: Dictionary = await _next_message_type(_origin, "tuning_commit", 240)
    var ordinary_ack_one: Dictionary = await _next_message_type(_observer, "tuning_ack", 240)
    var ordinary_ack_two: Dictionary = await _next_message_type(_observer, "tuning_ack", 240)
    var ordinary_observer_commit: Dictionary = await _next_message_type(_observer, "tuning_commit", 240)
    var barrier_observer_commit: Dictionary = await _next_message_type(_observer, "tuning_commit", 240)
    var barrier_migration_data: Dictionary = barrier_migration_ack.get("d", {})
    var ordinary_origin_commit_data: Dictionary = ordinary_origin_commit.get("d", {})
    var barrier_origin_commit_data: Dictionary = barrier_origin_commit.get("d", {})
    var ordinary_observer_commit_data: Dictionary = ordinary_observer_commit.get("d", {})
    var barrier_observer_commit_data: Dictionary = barrier_observer_commit.get("d", {})
    _expect(bool(barrier_migration_data.get("ok", false)) and String(barrier_migration_data.get("source", "")) == "preset" and
            barrier_migration_data.get("committed_values", {}) == expected_migration_values and
            barrier_origin_commit_data.get("committed_values", {}) == expected_migration_values and
            String(barrier_origin_commit_data.get("source", "")) == "preset" and
            int(barrier_origin_commit_data.get("commit_id", -1)) == int(barrier_observer_commit_data.get("commit_id", -2)) and
            int(barrier_origin_commit_data.get("commit_id", -1)) > int(ordinary_origin_commit_data.get("commit_id", -2)) and
            int(barrier_origin_commit_data.get("commit_id", -1)) > 0 and
            String(ordinary_origin_commit_data.get("source", "")) != "preset" and
            String(ordinary_observer_commit_data.get("source", "")) != "preset" and
            float(ordinary_observer_commit_data.get("committed_values", {}).get(ordinary_key, 0.0)) == ordinary_value and
            bool(ordinary_ack_one.get("d", {}).get("ok", false)) and bool(ordinary_ack_two.get("d", {}).get("ok", false)),
            "migration is a separate same-tick authoritative commit with exact preview values; ordinary requests flush separately before it")

    var before_load: Dictionary = _runtime.native.call("flight_tuning_configuration")
    _expect(_origin.send_text(JSON.stringify({"v": 2, "t": "load_preset", "seq": 14,
            "d": {"name": baseline_name}})) == OK,
            "active preset load request sends")
    _server.poll()
    var before_boundary: Dictionary = _runtime.native.call("flight_tuning_configuration")
    var early_ack := await _next_message_type(_origin, "tuning_ack", 20)
    _expect(early_ack.is_empty() and float(before_boundary.get("simpleflight.rate_p", -1.0)) == 2.0 and
            int(before_boundary.get("commit_id", -1)) == int(before_load.get("commit_id", -2)),
            "active preset load has no immediate mutation or acknowledgement")

    _runtime._apply_gsp_tuning_requests(11)
    _server.poll()
    var load_ack: Dictionary = await _next_message_type(_origin, "tuning_ack", 240)
    var origin_commit: Dictionary = await _next_message_type(_origin, "tuning_commit", 240)
    var observer_commit: Dictionary = await _next_message_type(_observer, "tuning_commit", 240)
    var load_data: Dictionary = load_ack.get("d", {})
    var origin_commit_data: Dictionary = origin_commit.get("d", {})
    var observer_commit_data: Dictionary = observer_commit.get("d", {})
    _expect(bool(load_data.get("ok", false)) and int(load_data.get("request_seq", -1)) == 14 and
            String(load_data.get("source", "")) == "preset" and
            int(origin_commit_data.get("commit_id", -1)) > 0 and
            int(origin_commit_data.get("commit_id", -1)) == int(observer_commit_data.get("commit_id", -2)) and
            String(origin_commit_data.get("source", "")) == "preset" and
            String(observer_commit_data.get("source", "")) == "preset" and
            float(_runtime.native.call("flight_tuning_configuration").get("simpleflight.rate_p", -1.0)) == 0.6,
            "active preset load correlates origin ACK and broadcasts one source-tagged commit to both peers")

    _expect(_origin.send_text(JSON.stringify({"v": 2, "t": "list_presets", "seq": 15, "d": {}})) == OK,
            "preset list request sends")
    _server.poll()
    var listed: Dictionary = await _next_message_type(_origin, "preset_ack", 240)
    var listed_names: Array = []
    for preset_value in listed.get("d", {}).get("presets", []):
        listed_names.append(String(preset_value.get("name", "")))
    _expect(baseline_name in listed_names, "preset list returns only fixed-directory presets")

    _server.stop()
    _finish()


func _connect_and_auth(client: WebSocketPeer, port: int, token: String) -> void:
    client.handshake_headers = PackedStringArray(["Origin: null"])
    client.connect_to_url("ws://127.0.0.1:%d" % port)
    for _attempt in 240:
        _server.poll()
        client.poll()
        if client.get_ready_state() == WebSocketPeer.STATE_OPEN:
            break
        await process_frame
    client.send_text(JSON.stringify({"v": 2, "t": "auth", "seq": 0, "d": {"token": token}}))


func _next_message_type(client: WebSocketPeer, message_type: String, attempts: int) -> Dictionary:
    for _attempt in attempts:
        _server.poll()
        client.poll()
        while client.get_available_packet_count() > 0:
            var packet := client.get_packet()
            if not client.was_string_packet():
                continue
            var parsed = JSON.parse_string(packet.get_string_from_utf8())
            if typeof(parsed) == TYPE_DICTIONARY and String(parsed.get("t", "")) == message_type:
                return parsed
        await process_frame
    return {}


func _new_name(prefix: String) -> String:
    var store := GspPresetStore.new()
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


func _expect(condition: bool, message: String) -> void:
    if not condition:
        _failures.append(message)


func _finish() -> void:
    _server.stop()
    _origin.close()
    _observer.close()
    for name in _created_names:
        var path := GspPresetStore.preset_path(name)
        if not path.is_empty():
            DirAccess.remove_absolute(path)
    if _failures.is_empty():
        print("GSP preset integration: PASS")
        quit(0)
        return
    for failure in _failures:
        push_error(failure)
    print("GSP preset integration: FAIL")
    quit(1)
