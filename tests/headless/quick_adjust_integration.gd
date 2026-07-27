extends SceneTree

const AirSimSession = preload("res://common/rpc/airsim_session.gd")
const FlightRuntime = preload("res://common/flight/flight_runtime.gd")
const HardwareConfig = preload("res://common/flight/hardware_config.gd")
const InputProfiles = preload("res://common/flight/input_profiles.gd")
const SettingsStore = preload("res://common/flight/settings_store.gd")
const GspServer = preload("res://common/gsp/gsp_server.gd")
const Px4SitlBridge = preload("res://common/rpc/px4_sitl_bridge.gd")

var _failures: Array[String] = []
var _server: GspServer


func _init() -> void:
    await _run()


func _run() -> void:
    var profile: Dictionary = InputProfiles.QuickAdjustProfile.default_profile()
    _expect(profile.get("slots", []).size() == 8, "Quick Adjust exposes exactly eight slots")
    var binding := {
        "parameter": "simpleflight.rate_p",
        "binding_type": "key_pair",
        "negative_key": KEY_Q,
        "positive_key": KEY_E,
        "mode": "relative",
        "subset_min": 0.6,
        "subset_max": 1.4,
        "deadzone": 0.05,
        "step": 0.01,
        "rate_limit": 30.0,
    }
    profile["slots"][0] = binding

    var runtime := FlightRuntime.new()
    runtime.native = ClassDB.instantiate("AeroSimNative")
    runtime.airsim_session = AirSimSession.new(240)
    runtime._airsim_vehicle_names = ["DroneA", "DroneB"]
    runtime._airsim_vehicle_name = "DroneA"
    runtime.settings_store = SettingsStore.new("user://quick-adjust-integration.json")
    var hardware := HardwareConfig.new()
    runtime._gsp_tuning_registry = hardware.tuning_registry()
    runtime._gsp_tuning_registry_hash = hardware.tuning_registry_hash()
    _expect(runtime.native != null and hardware.initialize_tuning(runtime), "native tuning initializes")
    if runtime.native != null:
        var ineligible := profile.duplicate(true)
        ineligible.slots[1] = binding.duplicate(true)
        ineligible.slots[1].parameter = "simpleflight.angle_p"
        _expect(not bool(runtime.validate_quick_adjust_profile(ineligible).get("ok", false)), "ineligible gain is rejected")
        var inverted := profile.duplicate(true)
        inverted.slots[0].subset_min = 1.0
        inverted.slots[0].subset_max = 0.5
        _expect(not bool(runtime.validate_quick_adjust_profile(inverted).get("ok", false)), "inverted subset is rejected")
        var conflict := profile.duplicate(true)
        conflict.slots[0].negative_key = KEY_P
        _expect(not bool(runtime.validate_quick_adjust_profile(conflict).get("ok", false)), "flight-control key conflict is rejected")
        runtime.px4_sitl_bridge = Px4SitlBridge.new()
        runtime.px4_sitl_bridge._set_state("connected", true, "test authority")
        _expect(String(runtime.configure_quick_adjust(profile, false).get("error", "")) == "external_authority", "external authority rejects Quick Adjust")
        runtime.px4_sitl_bridge = null
        var axis_profile := profile.duplicate(true)
        axis_profile.slots[0] = binding.duplicate(true)
        axis_profile.slots[0].binding_type = "axis"
        axis_profile.slots[0].device = 0
        axis_profile.slots[0].axis = 4
        axis_profile.slots[0].mode = "absolute"
        _expect(bool(runtime.configure_quick_adjust(axis_profile, false).get("ok", false)), "valid axis binding is accepted")
        runtime.screen = "flight"
        runtime._unhandled_input(_axis_event(0, 4, 1.0))
        runtime._apply_quick_adjust_inputs(1.0 / 240.0)
        runtime._apply_gsp_tuning_requests(0)
        _expect(float(runtime.native.call("flight_tuning_configuration").get("simpleflight.rate_p", 0.0)) > 1.0,
                "axis input commits through the native tuning path")
        var configured: Dictionary = runtime.configure_quick_adjust(profile)
        _expect(bool(configured.get("ok", false)), "valid key-pair binding is accepted")
        runtime.screen = "flight"
        runtime._unhandled_input(_key_event(KEY_E, true))
        runtime._apply_quick_adjust_inputs(1.0 / 240.0)
        runtime._apply_gsp_tuning_requests(0)
        var tuning: Dictionary = runtime.native.call("flight_tuning_configuration")
        _expect(float(tuning.get("simpleflight.rate_p", 0.0)) > 0.6, "key-pair input commits through native tuning")
        runtime.quick_adjust_status_label = Label.new()
        var cursor_mode := Input.mouse_mode
        runtime._refresh_quick_adjust_hud()
        _expect(runtime.quick_adjust_status_label.visible and String(runtime.quick_adjust_status_label.text).contains("simpleflight.rate_p") and
                Input.mouse_mode == cursor_mode, "HUD shows Quick Adjust without changing cursor capture")
        runtime.gsp_tuning_results()
        runtime.gsp_tuning_request(7, 8, 41, "simpleflight.rate_p", 0.8, "panel", -1)
        runtime.gsp_tuning_request(-1, -1, 42, "simpleflight.angle_p", 1.2, "quick_adjust", 3)
        runtime._apply_gsp_tuning_requests(2)
        var mixed_results: Array = runtime.gsp_tuning_results()
        var mixed_changes: Array = mixed_results[0].get("commit_changes", []) if not mixed_results.is_empty() else []
        var mixed_rate: Dictionary = {}
        var mixed_angle: Dictionary = {}
        for mixed_change_value in mixed_changes:
            var mixed_change: Dictionary = mixed_change_value
            if mixed_change.get("parameter", "") == "simpleflight.rate_p":
                mixed_rate = mixed_change
            elif mixed_change.get("parameter", "") == "simpleflight.angle_p":
                mixed_angle = mixed_change
        _expect(mixed_results.size() == 2 and mixed_results[0].get("source", "") == "mixed" and
                int(mixed_results[0].get("commit_request_seq", -1)) == -1 and
                not mixed_results[0].has("quick_adjust_slot") and mixed_rate.get("source", "") == "panel" and
                int(mixed_rate.get("request_seq", -1)) == 41 and mixed_angle.get("source", "") == "quick_adjust" and
                int(mixed_angle.get("request_seq", -1)) == 42 and int(mixed_angle.get("quick_adjust_slot", -1)) == 3,
                "mixed tuning commit preserves each parameter winner provenance")
        runtime.gsp_tuning_request(7, 8, 50, "simpleflight.rate_p", 0.9, "panel", -1)
        runtime.gsp_tuning_request(7, 8, 51, "simpleflight.rate_p", 1.0, "panel", -1)
        runtime._apply_gsp_tuning_requests(3)
        var same_key_results: Array = runtime.gsp_tuning_results()
        var same_key_change: Dictionary = {}
        if not same_key_results.is_empty():
            var same_key_changes: Array = same_key_results[0].get("commit_changes", [])
            if not same_key_changes.is_empty():
                same_key_change = same_key_changes[0]
        _expect(same_key_results.size() == 2 and int(same_key_change.get("request_seq", -1)) == 51 and
                float(same_key_change.get("committed_value", 0.0)) == 1.0,
                "same-key tuning winner is the last request")
        runtime.native.call("stage_flight_tuning", "simpleflight.rate_p", 0.6)
        runtime.native.call("commit_flight_tuning", 4)
        var response_profile := profile.duplicate(true)
        response_profile.slots[0].mode = "absolute"
        _expect(bool(runtime.configure_quick_adjust(response_profile, false).get("ok", false)),
                "response regression uses the production Quick Adjust binding")
        runtime._unhandled_input(_key_event(KEY_E, false))
        runtime._quick_adjust_next_allowed_usec[0] = 0
        runtime._unhandled_input(_key_event(KEY_E, true))
        runtime._apply_quick_adjust_inputs(1.0 / 240.0)
        var before_boundary: Dictionary = runtime.native.call("flight_tuning_configuration")
        _expect(is_equal_approx(float(before_boundary.get("simpleflight.rate_p", 0.0)), 0.6),
                "Quick Adjust has no native effect before the physics boundary")
        runtime._apply_gsp_tuning_requests(5)
        var after_boundary: Dictionary = runtime.native.call("flight_tuning_configuration")
        _expect(is_equal_approx(float(after_boundary.get("simpleflight.rate_p", 0.0)), 1.4),
                "Quick Adjust commits its staged value at the next physics boundary")

        var baseline_response_native = ClassDB.instantiate("AeroSimNative")
        var adjusted_response_native = ClassDB.instantiate("AeroSimNative")
        baseline_response_native.call("initialize_flight_tuning", "simpleflight.rate_p", 0.6)
        adjusted_response_native.call("initialize_flight_tuning", "simpleflight.rate_p", 1.4)
        var baseline_response_runtime := FlightRuntime.new()
        var adjusted_response_runtime := FlightRuntime.new()
        baseline_response_runtime.native = baseline_response_native
        adjusted_response_runtime.native = adjusted_response_native
        _expect(hardware.apply_to_runtime(baseline_response_runtime, "res://config/drones/5_inch_6s.json") and
                hardware.apply_to_runtime(adjusted_response_runtime, "res://config/drones/5_inch_6s.json"),
                "native response fixtures use the hardware configuration")
        baseline_response_native.call("arm_flight_control", 0.0)
        adjusted_response_native.call("arm_flight_control", 0.0)
        var baseline_response: PackedFloat64Array = baseline_response_native.call("step_acro_mode", 240, 1000, 0.5, 0.5, 0.0, 0.0, 1.0, 1.0, 0.0)
        var adjusted_response: PackedFloat64Array = adjusted_response_native.call("step_acro_mode", 240, 1000, 0.5, 0.5, 0.0, 0.0, 1.0, 1.0, 0.0)
        var response_difference := false
        for response_index in baseline_response.size():
            response_difference = response_difference or baseline_response[response_index] != adjusted_response[response_index]
        _expect(baseline_response.size() == adjusted_response.size() and baseline_response.size() > 0 and response_difference,
                "one native response tick observes the committed Quick Adjust change")
        runtime._unhandled_input(_key_event(KEY_E, false))

        var restarted := FlightRuntime.new()
        restarted.settings_store = SettingsStore.new("user://quick-adjust-integration.json")
        var restarted_settings: Dictionary = restarted.settings_store.load_document()
        _expect(bool(restarted_settings.get("ok", false)) and restarted_settings.document.quick_adjust.slots[0].parameter == "simpleflight.rate_p", "validated bindings survive restart")

        _server = GspServer.new()
        root.add_child(_server)
        _server.set_identity_provider(Callable(runtime, "gsp_identity_snapshot"))
        _server.set_tuning_request_provider(Callable(runtime, "gsp_tuning_request"))
        _server.set_tuning_result_provider(Callable(runtime, "gsp_tuning_results"))
        _server.set_quick_adjust_request_provider(Callable(runtime, "gsp_quick_adjust_request"))
        var started: Dictionary = _server.start()
        _server.set_process(false)
        _expect(bool(started.get("ok", false)), "Quick Adjust GSP server starts")
        var first_client := WebSocketPeer.new()
        var second_client := WebSocketPeer.new()
        if bool(started.get("ok", false)):
            await _connect_and_auth(first_client, int(started.port), String(started.token))
            await _connect_and_auth(second_client, int(started.port), String(started.token))
            _expect(not (await _next_message_type(first_client, "hello", 240)).is_empty(), "Quick Adjust origin receives hello")
            _expect(not (await _next_message_type(second_client, "hello", 240)).is_empty(), "Quick Adjust observer receives hello")
            first_client.send_text(JSON.stringify({"v": 2, "t": "set_quick_adjust", "seq": 1, "d": {"profile": profile}}))
            var profile_ack := await _next_message_type(first_client, "quick_adjust_ack", 240)
            _expect(bool(profile_ack.get("d", {}).get("ok", false)), "panel Quick Adjust profile receives correlated ACK")
            runtime.native.call("stage_flight_tuning", "simpleflight.rate_p", 0.6)
            runtime.native.call("commit_flight_tuning", 1)
            runtime._quick_adjust_next_allowed_usec[0] = 0
            runtime._unhandled_input(_key_event(KEY_E, true))
            runtime._apply_quick_adjust_inputs(1.0 / 240.0)
            runtime._apply_gsp_tuning_requests(1)
            _server.poll()
            var first_commit := await _next_message_type(first_client, "tuning_commit", 240)
            var second_commit := await _next_message_type(second_client, "tuning_commit", 240)
            _expect(first_commit.get("d", {}).get("source", "") == "quick_adjust" and int(first_commit.get("d", {}).get("quick_adjust_slot", -1)) == 0,
                    "Quick Adjust commit identifies its source and slot")
            _expect(int(first_commit.get("d", {}).get("commit_id", -1)) == int(second_commit.get("d", {}).get("commit_id", -2)),
                    "Quick Adjust commit is broadcast to every panel")
            runtime._unhandled_input(_key_event(KEY_E, false))
            first_client.close()
            second_client.close()
            _server.stop()

    _finish()


func _key_event(keycode: Key, pressed: bool) -> InputEventKey:
    var event := InputEventKey.new()
    event.keycode = keycode
    event.physical_keycode = keycode
    event.pressed = pressed
    return event


func _axis_event(device: int, axis: JoyAxis, value: float) -> InputEventJoypadMotion:
    var event := InputEventJoypadMotion.new()
    event.device = device
    event.axis = axis
    event.axis_value = value
    return event


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


func _expect(condition: bool, message: String) -> void:
    if not condition:
        _failures.append(message)


func _finish() -> void:
    DirAccess.remove_absolute("user://quick-adjust-integration.json")
    if _failures.is_empty():
        print("Quick Adjust integration: PASS")
        quit(0)
        return
    for failure in _failures:
        push_error(failure)
    print("Quick Adjust integration: FAIL")
    quit(1)
