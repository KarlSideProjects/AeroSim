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
    _runtime._set_replay_physics_tick(0)
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
    var advanced_tick: Dictionary = _runtime.native.call("set_replay_physics_tick", 3)
    _runtime._replay_authoritative_physics_tick = 3
    var regressed_tick: Dictionary = _runtime.native.call("set_replay_physics_tick", 2)
    _expect(bool(advanced_tick.get("ok", false)) and not bool(regressed_tick.get("ok", true)),
            "native replay tick binding propagates regression failure")

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
            "d": {"operation": "pause"}})) == OK, "supported sim_cmd sends")
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
    _expect(_ordered_replay_events_are_exact(events), "loaded replay retains exact ordered ticks, orders, types, and inputs")
    var replay: Dictionary = _runtime.native.call(
            "replay_complete_session", serialized, "ws-replay-settings", config_hash, config_hash,
            _runtime.native.call("replay_vehicle_config_manifest"), _runtime.native.call("replay_vehicle_config_manifest"))
    _expect(bool(replay.get("ok", false)), "finished authenticated recording loads and replays: %s" % JSON.stringify(replay))
    var jsonl := String(_runtime.native.call("derive_replay_session_jsonl", serialized, "ws-replay-settings"))
    _expect(jsonl.contains("\"schema_version\":5") and jsonl.contains("\"physics_tick\"") and
            jsonl.contains("\"event_order\"") and not jsonl.contains("ingest"),
            "derived JSONL is output-only and exposes authoritative order facts")
    _server.stop()
    _finish()


func _ordered_replay_events_are_exact(events: Array) -> bool:
    var seen_types := {}
    var previous_tick := 0
    var previous_order := 0
    var has_previous := false
    var same_tick_distinct := false
    var previous_type := ""
    for event_value in events:
        var event: Dictionary = event_value
        var tick := int(event.get("physics_tick", -1))
        var order := int(event.get("event_order", -1))
        var event_type := String(event.get("type", ""))
        if tick < 0 or order < 0 or (has_previous and tick < previous_tick) or \
                (has_previous and tick == previous_tick and order != previous_order + 1) or \
                (has_previous and tick > previous_tick and order != 0):
            return false
        if has_previous and tick == previous_tick and event_type != previous_type:
            same_tick_distinct = true
        seen_types[event_type] = true
        previous_tick = tick
        previous_order = order
        previous_type = event_type
        has_previous = true
        if event_type == "tuning" and String(event.get("source", "")) == "panel" and \
                is_equal_approx(float(event.get("committed_value", -1.0)), 1.11):
            seen_types["panel_transient"] = true
        if event_type == "tuning" and String(event.get("source", "")) == "panel" and \
                is_equal_approx(float(event.get("committed_value", -1.0)), 1.22):
            seen_types["panel_final"] = true
        if event_type == "tuning" and String(event.get("source", "")) == "quick_adjust" and int(event.get("quick_adjust_slot", -1)) == 0:
            seen_types["quick_adjust_commit"] = true
        if event_type == "tuning" and String(event.get("source", "")) == "preset":
            seen_types["preset_commit"] = true
        if event_type == "quick_adjust_binding":
            seen_types["quick_adjust_binding"] = true
        if event_type == "simulation_time" and String(event.get("operation", "")) == "pause":
            seen_types["sim_pause"] = true
        if event_type == "marker" and String(event.get("label", "")) == "ws-authoritative" and String(event.get("note", "")) == "ordered marker":
            seen_types["marker"] = true
    return seen_types.has("environment") and seen_types.has("panel_transient") and seen_types.has("panel_final") and \
            seen_types.has("quick_adjust_binding") and seen_types.has("quick_adjust_commit") and seen_types.has("preset_commit") and \
            seen_types.has("sim_pause") and seen_types.has("marker") and same_tick_distinct


func _rejected_marker(started: Dictionary, token: String) -> void:
    var client := WebSocketPeer.new()
    await _connect_and_auth(client, int(started.port), token)
    await _next_message_type(client, "hello", 240)
    client.send_text(JSON.stringify({"v": 2, "t": "mark", "seq": 1, "d": {"label": " \t\n"}}))
    for _attempt in 20:
        _server.poll()
        client.poll()
        await process_frame
    _expect(client.get_ready_state() == WebSocketPeer.STATE_CLOSED, "whitespace marker is rejected without a replay append")


func _rejected_simulation(started: Dictionary, token: String) -> void:
    var client := WebSocketPeer.new()
    await _connect_and_auth(client, int(started.port), token)
    await _next_message_type(client, "hello", 240)
    client.send_text(JSON.stringify({"v": 2, "t": "sim_cmd", "seq": 1, "d": {"operation": "shell"}}))
    for _attempt in 20:
        _server.poll()
        client.poll()
        await process_frame
    _expect(client.get_ready_state() == WebSocketPeer.STATE_CLOSED, "unsupported sim_cmd is rejected without a replay append")


func _rejected_tuning(started: Dictionary, token: String) -> void:
    var client := WebSocketPeer.new()
    await _connect_and_auth(client, int(started.port), token)
    await _next_message_type(client, "hello", 240)
    client.send_text(JSON.stringify({"v": 2, "t": "set_tuning", "seq": 1,
            "d": {"parameter": "unknown.parameter", "value": 1.0}}))
    _server.poll()
    var ack := await _next_message_type(client, "tuning_ack", 240)
    _expect(String(ack.get("d", {}).get("error", "")) == "unknown_parameter", "rejected tuning is acknowledged without a replay append")


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
