extends SceneTree

const AirSimSession = preload("res://common/rpc/airsim_session.gd")
const FlightRuntime = preload("res://common/flight/flight_runtime.gd")
const GspPresetStore = preload("res://common/gsp/gsp_preset_store.gd")
const GspServer = preload("res://common/gsp/gsp_server.gd")
const HardwareConfig = preload("res://common/flight/hardware_config.gd")
const InputProfiles = preload("res://common/flight/input_profiles.gd")
const SettingsStore = preload("res://common/flight/settings_store.gd")

var _runtime: FlightRuntime
var _server: GspServer
var _client := WebSocketPeer.new()
var _failures: Array[String] = []


func _init() -> void:
    await _run()


func _run() -> void:
    _runtime = FlightRuntime.new()
    _runtime.native = ClassDB.instantiate("AeroSimNative")
    _runtime.airsim_session = AirSimSession.new(240)
    _runtime._airsim_vehicle_names = ["DroneA", "DroneB"]
    _runtime._airsim_vehicle_name = "DroneA"
    _runtime.settings_store = SettingsStore.new("user://gsp-replay-integration.json")
    var hardware := HardwareConfig.new()
    _runtime._gsp_tuning_registry = hardware.tuning_registry()
    _runtime._gsp_tuning_registry_hash = hardware.tuning_registry_hash()
    _expect(_runtime.native != null and hardware.initialize_tuning(_runtime) and
            hardware.apply_to_runtime(_runtime, "res://config/drones/5_inch_6s.json"),
            "replay integration initializes the real native runtime")
    if _runtime.native == null:
        _finish()
        return

    var migration_name := "ws-replay-%d" % Time.get_ticks_usec()
    var stale_values: Dictionary = {}
    var active_values: Dictionary = _runtime.native.call("flight_tuning_configuration")
    for descriptor_value in _runtime._gsp_tuning_registry:
        var descriptor: Dictionary = descriptor_value
        stale_values[String(descriptor.key)] = active_values.get(String(descriptor.key), descriptor.default)
    stale_values["simpleflight.rate_p"] = 99.0
    var migration_saved := GspPresetStore.new().save_preset(migration_name, stale_values, "old-registry", "ws-test")
    _expect(bool(migration_saved.get("ok", false)), "real preset store saves the migration fixture")

    _server = GspServer.new()
    root.add_child(_server)
    _server.set_identity_provider(Callable(_runtime, "gsp_identity_snapshot"))
    _server.set_tuning_request_provider(Callable(_runtime, "gsp_tuning_request"))
    _server.set_tuning_result_provider(Callable(_runtime, "gsp_tuning_results"))
    _server.set_quick_adjust_request_provider(Callable(_runtime, "gsp_quick_adjust_request"))
    _server.set_preset_request_provider(Callable(_runtime, "gsp_preset_request"))
    _server.set_marker_request_provider(Callable(_runtime, "gsp_marker_request"))
    _server.set_simulation_request_provider(Callable(_runtime, "gsp_simulation_request"))
    var started: Dictionary = _server.start()
    _server.set_process(false)
    _expect(bool(started.get("ok", false)), "real replay GSP server starts")
    if not bool(started.get("ok", false)):
        _finish()
        return
    await _connect_and_auth(_client, int(started.port), String(started.token))
    _expect(not (await _next_message_type(_client, "hello", 240)).is_empty(), "real replay client authenticates")

    var config_json := _runtime._replay_canonical_json(_runtime.native.call("replay_vehicle_config_manifest"))
    var config_hash := String(_runtime.native.call("replay_manifest_hash", config_json))
    var begin: Dictionary = _runtime.native.call(
            "begin_complete_replay_recording", 250, "ws-replay-settings", "DroneA", config_hash, config_json, 0,
            "DroneB", config_hash, config_json, 0)
    _expect(bool(begin.get("ok", false)), "authenticated integration starts authoritative replay")
    _runtime._replay_recording_active = bool(begin.get("ok", false))
    _runtime._replay_authoritative_physics_tick = 0
    var atmosphere := {
        "rain": 0.0,
        "atmosphere": _runtime.native.call("wind_configuration"),
        "atmosphere_air_density_kg_m3": float(_runtime.native.call("body_drag_configuration").get("air_density_kg_m3", 1.225)),
    }
    _expect(bool(_runtime.native.call("record_replay_environment", 0, _runtime._replay_canonical_json(atmosphere)).get("ok", false)),
            "authoritative replay captures its environment baseline")

    _runtime.paused = false
    _expect(_client.send_text(JSON.stringify({
        "v": 2, "t": "set_tuning", "seq": 1,
        "d": {"parameter": "simpleflight.rate_p", "value": 1.11}
    })) == OK, "authenticated transient panel commit sends")
    _server.poll()
    _runtime._apply_gsp_tuning_requests(1)
    var transient_ack := await _next_message_type(_client, "tuning_ack", 240)
    _expect(bool(transient_ack.get("d", {}).get("changed", false)), "transient panel commit is acknowledged")

    _expect(_client.send_text(JSON.stringify({
        "v": 2, "t": "set_tuning_batch", "seq": 2,
        "d": {"changes": [{"parameter": "simpleflight.rate_p", "value": 1.22}]}
    })) == OK, "authenticated final panel commit sends")
    _server.poll()
    _runtime._apply_gsp_tuning_requests(2)
    var final_ack := await _next_message_type(_client, "tuning_ack", 240)
    _expect(bool(final_ack.get("d", {}).get("changed", false)), "final panel commit is acknowledged")

    var profile: Dictionary = InputProfiles.QuickAdjustProfile.default_profile()
    profile.slots[0] = {
        "parameter": "simpleflight.rate_p", "binding_type": "key_pair", "negative_key": KEY_Q, "positive_key": KEY_E,
        "axis": 0, "device": 0,
        "mode": "absolute", "subset_min": 0.6, "subset_max": 1.4, "deadzone": 0.05, "step": 0.01, "rate_limit": 30.0,
    }
    _expect(_client.send_text(JSON.stringify({"v": 2, "t": "set_quick_adjust", "seq": 3, "d": {"profile": profile}})) == OK,
            "authenticated persisted Quick Adjust binding sends")
    _server.poll()
    var binding_ack := await _next_message_type(_client, "quick_adjust_ack", 240)
    _expect(bool(binding_ack.get("d", {}).get("ok", false)), "Quick Adjust binding is persisted and acknowledged")
    _runtime.screen = "flight"
    _runtime._quick_adjust_next_allowed_usec[0] = 0
    _runtime._unhandled_input(_key_event(KEY_E, true))
    _runtime._apply_quick_adjust_inputs(1.0 / 240.0)
    _runtime._apply_gsp_tuning_requests(4)
    _runtime._unhandled_input(_key_event(KEY_E, false))
    _server.poll()
    var quick_commit := await _next_message_type(_client, "tuning_commit", 240)
    _expect(String(quick_commit.get("d", {}).get("source", "")) == "quick_adjust" and
            int(quick_commit.get("d", {}).get("quick_adjust_slot", -1)) == 0,
            "Quick Adjust input commits through the real tuning path")

    _expect(_client.send_text(JSON.stringify({"v": 2, "t": "preview_preset_migration", "seq": 4,
            "d": {"name": migration_name}})) == OK, "authenticated preset migration preview sends")
    _server.poll()
    var preview := await _next_message_type(_client, "preset_ack", 240)
    var preview_data: Dictionary = preview.get("d", {})
    _expect(bool(preview_data.get("ok", false)) and not String(preview_data.get("migration_id", "")).is_empty(),
            "preset migration preview is real and authoritative")
    _expect(_client.send_text(JSON.stringify({"v": 2, "t": "apply_preset_migration", "seq": 5,
            "d": {"name": migration_name, "migration_id": preview_data.get("migration_id", ""), "confirmed": true}})) == OK,
            "confirmed preset migration commit sends")
    _server.poll()
    _runtime._apply_gsp_tuning_requests(5)
    var migration_ack := await _next_message_type(_client, "tuning_ack", 240)
    _expect(String(migration_ack.get("d", {}).get("source", "")) == "preset" and
            bool(migration_ack.get("d", {}).get("ok", false)),
            "confirmed preset migration uses the atomic preset commit path")

    _expect(_client.send_text(JSON.stringify({"v": 2, "t": "sim_cmd", "seq": 6,
            "d": {"cmd": "pause", "args": {}}})) == OK, "supported sim_cmd sends")
    _server.poll()
    var sim_ack := await _next_message_type(_client, "sim_cmd_ack", 240)
    _expect(bool(sim_ack.get("d", {}).get("ok", false)), "supported sim_cmd receives a reliable ACK")
    _expect(_client.send_text(JSON.stringify({"v": 2, "t": "mark", "seq": 7,
            "d": {"label": "ws-authoritative", "note": "ordered marker"}})) == OK, "authenticated marker sends")
    _server.poll()
    var marker_ack := await _next_message_type(_client, "mark_ack", 240)
    _expect(bool(marker_ack.get("d", {}).get("ok", false)), "authenticated marker is acknowledged")

    await _rejected_marker(started, String(started.token))
    await _rejected_simulation(started, String(started.token))
    await _rejected_tuning(started, String(started.token))

    var finish: Dictionary = _runtime.native.call("finish_complete_replay_recording", 100000, "ws-replay")
    _runtime._replay_recording_active = false
    var serialized := String(finish.get("serialized", ""))
    var root_value = JSON.parse_string(serialized)
    var events: Array = root_value.get("events", []) if typeof(root_value) == TYPE_DICTIONARY else []
    _expect(bool(finish.get("ok", false)) and int(root_value.get("schema_version", 0)) == 5, "finished WS recording is schema v5")
    _expect(_ordered_replay_events_are_exact(events, atmosphere, profile, transient_ack, final_ack, quick_commit, migration_ack),
            "loaded replay retains the exact ordered event sequence and input values")
    var replay: Dictionary = _runtime.native.call(
            "replay_complete_session", serialized, "ws-replay-settings", config_hash, config_hash,
            _runtime.native.call("replay_vehicle_config_manifest"), _runtime.native.call("replay_vehicle_config_manifest"))
    _expect(bool(replay.get("ok", false)), "finished authenticated recording loads and replays: %s" % JSON.stringify(replay))
    var jsonl := String(_runtime.native.call("derive_replay_session_jsonl", serialized, "ws-replay-settings"))
    _expect(_derived_jsonl_matches(jsonl, events), "derived JSONL exactly matches the successfully loaded replay")
    var persisted_store := SettingsStore.new("user://gsp-replay-integration.json")
    var persisted_profile: Dictionary = persisted_store.load_document().get("document", {}).get("quick_adjust", {})
    _expect(_runtime._replay_canonical_value(persisted_profile) == _runtime._replay_canonical_value(profile),
            "persisted Quick Adjust profile reloads exactly")
    _runtime_failure_probe(config_json, config_hash, profile)
    _server.stop()
    _finish()


func _ordered_replay_events_are_exact(events: Array, atmosphere: Dictionary, profile: Dictionary,
        transient_ack: Dictionary, final_ack: Dictionary, quick_commit: Dictionary, migration_ack: Dictionary) -> bool:
    var transient_change: Dictionary = transient_ack.get("d", {}).get("changes", [])[0]
    var final_change: Dictionary = final_ack.get("d", {}).get("changes", [])[0]
    var quick_change: Dictionary = quick_commit.get("d", {}).get("changes", [])[0]
    var migration_changes: Array = migration_ack.get("d", {}).get("changes", [])
    var expected: Array[Dictionary] = [
        {"timestamp_us": 0, "physics_tick": 0, "event_order": 0, "type": "environment",
            "state": JSON.parse_string(_runtime._replay_canonical_json(atmosphere))},
        _expected_tuning_event(1, transient_ack, transient_change, "panel", -1),
        _expected_tuning_event(2, final_ack, final_change, "panel", -1),
        {"timestamp_us": 0, "physics_tick": 0, "event_order": 3, "type": "quick_adjust_binding",
            "profile": JSON.parse_string(_runtime._replay_canonical_json(profile))},
        _expected_tuning_event(4, quick_commit, quick_change, "quick_adjust", 0),
        _expected_tuning_event(5, migration_ack, migration_changes[0], "preset", -1),
        _expected_tuning_event(6, migration_ack, migration_changes[1], "preset", -1),
        _expected_tuning_event(7, migration_ack, migration_changes[2], "preset", -1),
        _expected_tuning_event(8, migration_ack, migration_changes[3], "preset", -1),
        {"timestamp_us": 0, "physics_tick": 0, "event_order": 9, "type": "simulation_time", "operation": "pause", "value": 0},
        {"timestamp_us": 0, "physics_tick": 0, "event_order": 10, "type": "marker", "label": "ws-authoritative", "note": "ordered marker"},
    ]
    if events.size() != expected.size():
        return false
    for index in expected.size():
        var actual: Dictionary = events[index]
        for key in expected[index]:
            if typeof(expected[index][key]) == TYPE_FLOAT:
                if not is_equal_approx(float(actual.get(key, NAN)), float(expected[index][key])):
                    return false
            elif actual.get(key, null) != expected[index][key]:
                return false
    return true


func _expected_tuning_event(event_order: int, ack: Dictionary, change: Dictionary, source: String, slot: int) -> Dictionary:
    var expected := {"timestamp_us": 0, "physics_tick": 0, "event_order": event_order, "type": "tuning",
        "vehicle": "DroneA", "request_seq": int(change.get("request_seq", ack.get("d", {}).get("request_seq", 0))),
        "commit_id": int(ack.get("d", {}).get("commit_id", 0)), "parameter": String(change.get("parameter", "")),
        "requested_value": float(change.get("requested_value", 0.0)), "committed_value": float(change.get("committed_value", 0.0)),
        "clamped": bool(change.get("clamped", false)), "source": source}
    if slot >= 0:
        expected["quick_adjust_slot"] = slot
    return expected


func _derived_jsonl_matches(jsonl: String, events: Array) -> bool:
    var rows := jsonl.strip_edges().split("\n")
    if rows.size() != events.size():
        return false
    for index in rows.size():
        var row = JSON.parse_string(rows[index])
        if typeof(row) != TYPE_DICTIONARY or int(row.get("schema_version", 0)) != 5 or \
                int(row.get("physics_tick", -1)) != int(events[index].get("physics_tick", -1)) or \
                int(row.get("event_order", -1)) != int(events[index].get("event_order", -1)) or \
                row.get("event", {}) != events[index]:
            return false
    return true


func _rejected_marker(started: Dictionary, token: String) -> void:
    var client := WebSocketPeer.new()
    await _connect_and_auth(client, int(started.port), token)
    await _next_message_type(client, "hello", 240)
    client.send_text(JSON.stringify({"v": 2, "t": "mark", "seq": 1, "d": {"label": " \t\n"}}))
    for _attempt in 20:
        _server.poll()
        client.poll()
        await process_frame
    _expect(client.get_ready_state() == WebSocketPeer.STATE_CLOSED,
            "whitespace marker is rejected without a replay append")


func _rejected_simulation(started: Dictionary, token: String) -> void:
    var client := WebSocketPeer.new()
    await _connect_and_auth(client, int(started.port), token)
    await _next_message_type(client, "hello", 240)
    client.send_text(JSON.stringify({"v": 2, "t": "sim_cmd", "seq": 1, "d": {"cmd": "pause", "args": {"bad": true}}}))
    for _attempt in 20:
        _server.poll()
        client.poll()
        await process_frame
    _expect(client.get_ready_state() == WebSocketPeer.STATE_CLOSED,
            "malformed sim_cmd is rejected without a replay append")


func _rejected_tuning(started: Dictionary, token: String) -> void:
    var client := WebSocketPeer.new()
    await _connect_and_auth(client, int(started.port), token)
    await _next_message_type(client, "hello", 240)
    client.send_text(JSON.stringify({"v": 2, "t": "set_tuning", "seq": 1,
            "d": {"parameter": "unknown.parameter", "value": 1.0}}))
    _server.poll()
    var ack := await _next_message_type(client, "tuning_ack", 240)
    _expect(String(ack.get("d", {}).get("error", "")) == "unknown_parameter",
            "rejected tuning is acknowledged without a replay append")


func _runtime_failure_probe(config_json: String, config_hash: String, profile: Dictionary) -> void:
    var begin: Dictionary = _runtime.native.call(
            "begin_complete_replay_recording", 251, "ws-replay-failure", "DroneA", config_hash, config_json, 0,
            "DroneB", config_hash, config_json, 0)
    _expect(bool(begin.get("ok", false)), "failure probe starts a fresh native recording")
    _runtime._replay_recording_active = bool(begin.get("ok", false))
    _runtime._replay_recording_failed = false
    _runtime._replay_recording_failure = ""
    var original_settings_store = _runtime.settings_store
    _runtime.settings_store = null
    var persistence_failure := _runtime.configure_quick_adjust(profile, true)
    _expect(not bool(persistence_failure.get("ok", false)) and
            persistence_failure.get("error", "") == "replay_recording_failed" and
            _runtime._replay_recording_failed,
            "Quick Adjust persistence failure makes the active replay unrecoverable")
    _runtime.settings_store = original_settings_store
    var persistence_finish := _runtime._finish_complete_replay_recording("quick-adjust-persistence-failure")
    _expect(not bool(persistence_finish.get("ok", false)) and String(persistence_finish.get("serialized", "")).is_empty(),
            "Quick Adjust persistence failure cannot certify a replay")

    begin = _runtime.native.call(
            "begin_complete_replay_recording", 252, "ws-replay-tick-failure", "DroneA", config_hash, config_json, 0,
            "DroneB", config_hash, config_json, 0)
    _expect(bool(begin.get("ok", false)), "tick failure probe starts a fresh native recording")
    _runtime._replay_recording_active = bool(begin.get("ok", false))
    _runtime._replay_recording_failed = false
    _runtime._replay_recording_failure = ""
    _runtime._replay_authoritative_physics_tick = 1
    _expect(bool(_runtime.native.call("set_replay_physics_tick", 3).get("ok", false)),
            "failure probe establishes a later native tick")
    _runtime._physics_process(0.0)
    _expect(_runtime._replay_recording_failed, "physics tick failure latches the recording")
    var marker := _runtime.gsp_marker_request(1, 1, 1, "probe", "")
    _expect(not bool(marker.get("ok", false)),
            "marker does not ACK success after a latched replay failure")
    var paused_before := _runtime.paused
    var sim := _runtime.gsp_simulation_request(1, 1, 2, "resume")
    _expect(not bool(sim.get("ok", false)) and _runtime.paused == paused_before,
            "simulation does not mutate pause state after a latched replay failure")
    var quick := _runtime.configure_quick_adjust(profile, false)
    _expect(not bool(quick.get("ok", false)), "Quick Adjust does not ACK after a latched replay failure")
    var tuning := _runtime._commit_gsp_tuning_batch(1, 1, 3,
            [{"parameter": "simpleflight.rate_p", "value": 1.3}], 0)
    _expect(not bool(tuning.get("ok", false)), "committed tuning does not ACK after a latched replay failure")
    var finish := _runtime._finish_complete_replay_recording("failure-probe")
    _expect(not bool(finish.get("ok", false)) and String(finish.get("serialized", "")).is_empty(),
            "finish rejects and never certifies a failed replay")


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


func _key_event(keycode: int, pressed: bool) -> InputEventKey:
    var event := InputEventKey.new()
    event.keycode = keycode
    event.pressed = pressed
    return event


func _expect(condition: bool, message: String) -> void:
    if not condition:
        _failures.append(message)


func _finish() -> void:
    if _failures.is_empty():
        print("GSP replay integration: PASS")
        quit(0)
    else:
        for failure in _failures:
            push_error(failure)
        print("GSP replay integration: FAIL")
        quit(1)
