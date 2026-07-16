extends Node3D

const InputProfiles = preload("res://common/flight/input_profiles.gd")
const GamepadDeviceState = preload("res://common/flight/gamepad_device_state.gd")
const SettingsStoreScript = preload("res://common/flight/settings_store.gd")
const RatesProfile = preload("res://common/flight/rates_profile.gd")
const HardwareConfig = preload("res://common/flight/hardware_config.gd")
const StatusDiagramDebug = preload("res://common/flight/status_diagram_debug.gd")
const AirSimRpcServer = preload("res://common/rpc/airsim_rpc_server.gd")
const AirSimSettings = preload("res://common/rpc/airsim_settings.gd")
const AirSimSession = preload("res://common/rpc/airsim_session.gd")
const AirSimSensorSuite = preload("res://common/rpc/airsim_sensor_suite.gd")
const AirSimCameraSurface = preload("res://common/rpc/airsim_camera_surface.gd")
const AirSimCoordinateContract = preload("res://common/rpc/airsim_coordinate_contract.gd")
const SceneObjectCatalog = preload("res://common/rpc/scene_object_catalog.gd")
const EnvironmentState = preload("res://common/rpc/environment_state.gd")
const Px4SitlBridge = preload("res://common/rpc/px4_sitl_bridge.gd")
const FreeFlightMap = preload("res://common/maps/free_flight_map.gd")
const TimeTrialController = preload("res://common/flight/time_trial.gd")
const DEFAULT_HARDWARE_PRESET := "res://config/drones/5_inch_6s.json"
const DEFAULT_FREE_FLIGHT_MAP_ID := "industrial_yard"
const MAP_SCENE_PATHS := {
    "industrial_yard": "res://levels/free_flight/industrial_yard.tscn"
}
const SPAWN_POSITION := Vector3(-1.0, 0.0, 0.0)
const AIRSIM_GROUND_BODY_CLEARANCE_M := 0.25
const TAKEOFF_VELOCITY := Vector3(0.0, 6.0, 0.0)
const KEYBOARD_FLIGHT_THROTTLE := 0.75
const ANGLE_MAX_TILT_DEGREES := 30.0
const ANGLE_MAX_YAW_RATE_DPS := 180.0
const GAMEPAD_BUTTON_DEBOUNCE_MS := 50
const CHASE_CAMERA_OFFSET := Vector3(-3.0, 1.4, 2.2)
const KEY_HINTS_TEXT := "T Arm/Takeoff   P Pause   R Reset   C ACRO   H Alt Hold   Esc Exit"
const WIND_PRESETS := ["calm", "light", "moderate", "severe"]

@export var scene_steady_wind_mps := Vector3.ZERO

@onready var fallback_status_label: Label3D = %FallbackStatus
@onready var drone_body = get_node_or_null("DroneBody")
@onready var chase_camera := get_node_or_null("ChaseCamera") as Camera3D
@onready var secondary_drone_body = get_node_or_null("DroneBodySecondary")
@onready var secondary_chase_camera := get_node_or_null("ChaseCameraSecondary") as Camera3D

var native: Object
var airsim_session: AirSimSession
var airsim_rpc_server: AirSimRpcServer
var airsim_sensor_suite: AirSimSensorSuite
var px4_sitl_bridge: Px4SitlBridge
var airsim_camera_surface: AirSimCameraSurface
var scene_object_catalog: SceneObjectCatalog
var environment_state: EnvironmentState
var airsim_stop_file := ""
var loaded_map: Node3D
var loaded_map_id := ""
var loaded_map_wind_preset := "calm"
var selected_wind_preset := ""
var time_trial: TimeTrialController
var paused := false
var exit_requested := false
var quit_on_exit := true
var takeoff_requested := false
var reset_count := 0
var last_profile_status := ""
var main_menu_entries := ["Quick Fly", "Controller", "Drone", "Map", "Settings"]
var screen := "main_menu"
var last_error_message := ""
var last_collision_authority := -1
var collision_handoff_count := 0
var reset_hold_frames := 0
var flight_mode := "ANGLE"
var acro_roll_stick := 0.0
var acro_pitch_stick := 0.0
var acro_yaw_stick := 0.0
var dashboard_layout_mode := "compact"
var status_diagram: CanvasLayer
var main_menu_layer: CanvasLayer
var main_menu_entries_container: VBoxContainer
var settings_panel: Control
var settings_status_label: Label
var rates_panel: Control
var rates_status_label: Label
var rates_json_editor: TextEdit
var rates_diff_label: Label
var rates_curve_line: Line2D
var rates_curve_plot: Control
var rates_sliders: Dictionary = {}
var rates_slider_labels: Dictionary = {}
var rates_return_screen := "settings"
var controller_settings_panel: Control
var flight_hud_layer: CanvasLayer
var key_hints_label: Label
var arm_status_label: Label
var arm_takeoff_button: Button
var acro_mode_button: Button
var time_trial_status_label: Label
var pause_panel: Control
var finish_panel: Control
var finish_summary_label: Label
var session_gamepad_profile: InputProfiles.GamepadProfile
var session_gamepad_device_id := -1
var gamepad_device_state: GamepadDeviceState.DeviceState = GamepadDeviceState.DeviceState.new()
var controller_confirmation_panel: Control
var controller_confirmation_profile: InputProfiles.GamepadProfile
var controller_confirmation_device_id := -1
var confirmation_mapping_label: Label
var confirmation_axes_label: Label
var controller_settings_device_label: Label
var controller_settings_mapping_label: Label
var controller_settings_deadzone_label: Label
var controller_settings_button_status_label: Label
var controller_safety_panel: Control
var controller_safety_label: Label
var last_arm_button_press_ms := -1000000
var last_mode_button_press_ms := -1000000
var gamepad_button_time_source: Callable
var settings_store: RefCounted
var persisted_gamepad_profile: InputProfiles.GamepadProfile
var keyboard_fallback_explicitly_selected := false
var controller_safety_latched := false
var controller_reconnected := false
var disconnected_gamepad_device_id := -1
var _airsim_vehicle_name := ""
var _airsim_vehicle_names: Array[String] = []
var _dashboard_vehicle_name := ""
var _airsim_secondary_native: Object
var _replay_recording_active := false
var _replay_settings_manifest_hash := ""
var _replay_upper_config_manifest_hash := ""
var _replay_lower_config_manifest_hash := ""
var _replay_last_timestamp_us := 0
var _replay_epoch_offset_us := 0
var _replay_last_simulation_timestamp_us := 0
var _replay_epoch_pending := false
var _last_complete_replay_serialized := ""
var _replay_secondary_row := PackedFloat64Array()
var _airsim_vehicle_contexts: Dictionary = {}
var _airsim_secondary_a5_configuration: Dictionary = {}
var _secondary_collision_state_captured := false
var _secondary_collision_layer := 1
var _secondary_collision_mask := 1
var _secondary_collision_shapes: Array[Dictionary] = []
var _airsim_api_control := false
var _airsim_disarm_requested := false
var _airsim_command_state: Dictionary = {}
var _airsim_hold_controls: Dictionary = {}
var _airsim_command_remaining_frames := 0
var _airsim_last_velocity := Vector3.ZERO
var _airsim_linear_acceleration := Vector3.ZERO
var _airsim_last_body_angular_velocity := Vector3.ZERO
var _airsim_angular_acceleration := Vector3.ZERO
var _airsim_environment_catalog_loaded := false
var _px4_lockstep_sensor_pending := false
var _airsim_collision_seen := false
var _airsim_contact_this_frame := false
var _airsim_collision_normal := Vector3.ZERO
var _airsim_collision_point := Vector3.ZERO
var rates_profile: Dictionary = RatesProfile.default_profile()

func _ready() -> void:
    Input.joy_connection_changed.connect(_on_joy_connection_changed)
    settings_store = SettingsStoreScript.new()
    _load_player_settings()
    var startup_settings := _load_and_validate_airsim_settings()
    if startup_settings.is_empty():
        return
    _build_main_menu()
    _build_flight_hud()
    _build_status_diagram()
    native = ClassDB.instantiate("AeroSimNative")
    if native == null:
        push_error("AeroSimNative is not registered")
        return
    if drone_body != null:
        _reset_drone_body()
    airsim_session = AirSimSession.new(Engine.physics_ticks_per_second)
    airsim_rpc_server = AirSimRpcServer.new()
    airsim_sensor_suite = AirSimSensorSuite.new()
    airsim_camera_surface = AirSimCameraSurface.new()
    scene_object_catalog = SceneObjectCatalog.new()
    environment_state = EnvironmentState.new()
    add_child(scene_object_catalog)
    add_child(airsim_camera_surface)
    airsim_rpc_server.set_session(airsim_session, Callable(self, "respawn"))
    add_child(airsim_rpc_server)
    airsim_stop_file = _cold_start_arg("--airsim-stop-file")
    var configured_vehicles = startup_settings.get("Vehicles", {})
    if typeof(configured_vehicles) == TYPE_DICTIONARY:
        for configured_name in configured_vehicles.keys():
            _airsim_vehicle_names.append(String(configured_name))
    if _airsim_vehicle_names.size() > 0:
        _airsim_vehicle_name = _airsim_vehicle_names[0]
    _dashboard_vehicle_name = _airsim_vehicle_name
    if status_diagram != null:
        status_diagram.call("set_vehicle_names", _airsim_vehicle_names)
    _configure_airsim_vehicle_contexts()
    airsim_rpc_server.set_vehicle_backend(
        Callable(self, "_airsim_state"),
        Callable(self, "_airsim_command"),
        Callable(self, "_airsim_enable_api_control"),
        Callable(self, "_airsim_arm_disarm"),
        Callable(self, "_airsim_cancel_task"),
        Callable(self, "_airsim_task_complete")
    )
    airsim_rpc_server.set_sensor_backend(Callable(self, "_airsim_sensor"))
    airsim_rpc_server.set_scene_environment_backend(Callable(self, "_airsim_scene_object"), Callable(self, "_airsim_environment"))
    airsim_rpc_server.set_replay_handlers(Callable(self, "_record_replay_simulation_operation"), Callable(self, "_record_replay_async"))
    _load_scene_object_catalog()
    var rpc_result: Dictionary = airsim_rpc_server.start_with_settings(startup_settings)
    if not rpc_result.ok:
        push_error("AirSim RPC startup failed: %s" % rpc_result.error)
        airsim_rpc_server.stop()
        get_tree().quit(1)
        return
    else:
        _configure_px4_sitl_bridge()
        var sensor_result := airsim_sensor_suite.configure(airsim_rpc_server.settings, _airsim_vehicle_names if not _airsim_vehicle_names.is_empty() else [_airsim_vehicle_name])
        if not sensor_result.ok:
            push_error("AirSim sensor startup failed: %s" % sensor_result.error)
            airsim_rpc_server.stop()
            get_tree().quit(1)
            return
        _advance_airsim_sensors()
        airsim_camera_surface.configure(
            self,
            Callable(self, "_airsim_camera_source"),
            Callable(self, "_airsim_camera_vehicle"),
            airsim_session,
            airsim_rpc_server.settings,
            Callable(self, "_airsim_camera_origin"))
        airsim_rpc_server.set_camera_backend(Callable(airsim_camera_surface, "capture"))
    var hardware_config := HardwareConfig.new()
    if not hardware_config.apply_to_runtime(self, DEFAULT_HARDWARE_PRESET):
        last_error_message = hardware_config.last_error
        push_error("Default hardware preset failed: %s" % hardware_config.last_error)
    if not _configure_secondary_native(hardware_config):
        push_error("Named vehicle runtime setup failed: %s" % last_error_message)
        if airsim_rpc_server != null and airsim_rpc_server.is_running():
            airsim_rpc_server.stop()
        get_tree().quit(1)
        return
    _begin_complete_replay_recording(startup_settings)
    var ready_file := _cold_start_arg("--airsim-ready-file")
    if not ready_file.is_empty() and _airsim_vehicle_names.size() >= 2 and loaded_map == null:
        if not load_map(DEFAULT_FREE_FLIGHT_MAP_ID):
            push_error("AirSim default map setup failed: %s" % last_error_message)
            if airsim_rpc_server != null and airsim_rpc_server.is_running():
                airsim_rpc_server.stop()
            get_tree().quit(1)
            return
        screen = "preflight"
    _write_airsim_ready_marker(ready_file)
    update_fallback_status()
    _update_chase_camera()
    _refresh_flight_hud()
    call_deferred("_run_cold_start_probe")


func _validate_airsim_startup_settings(raw_settings: Dictionary) -> Dictionary:
    var validation: Dictionary = AirSimSettings.validate(raw_settings)
    if not bool(validation.get("ok", false)):
        return validation
    var vehicles: Dictionary = validation.get("settings", {}).get("Vehicles", {})
    if vehicles.size() == 2:
        var vehicle_names: Array = vehicles.keys()
        var secondary_name := String(vehicle_names[1])
        var secondary_settings: Dictionary = vehicles.get(secondary_name, {})
        if String(secondary_settings.get("VehicleType", "SimpleFlight")) == "PX4Multirotor":
            var error := "secondary named PX4Multirotor requires a second Px4SitlBridge; unsupported in this slice"
            validation["ok"] = false
            validation["error"] = error
            validation["errors"] = [error]
    return validation


func _load_and_validate_airsim_settings() -> Dictionary:
    var startup_settings := {
        "SettingsVersion": 1.2,
        "SimMode": "Multirotor",
        "ApiServerPort": int(_cold_start_arg("--airsim-rpc-port", str(AirSimRpcServer.DEFAULT_PORT))),
        "RpcEnabled": true,
    }
    var settings_path := _cold_start_arg("--airsim-settings-file")
    if not settings_path.is_empty():
        var settings_file := FileAccess.open(settings_path, FileAccess.READ)
        if settings_file == null:
            push_error("AirSim settings file could not be opened: %s" % settings_path)
            get_tree().quit(1)
            return {}
        var parsed_settings = JSON.parse_string(settings_file.get_as_text())
        settings_file.close()
        if typeof(parsed_settings) != TYPE_DICTIONARY:
            push_error("AirSim settings file must contain a JSON object")
            get_tree().quit(1)
            return {}
        startup_settings = parsed_settings

    var validation: Dictionary = _validate_airsim_startup_settings(startup_settings)
    if not validation.ok:
        last_error_message = String(validation.error)
        push_error("AirSim settings validation failed: %s" % last_error_message)
        get_tree().quit(1)
        return {}
    return validation.settings


func _configure_airsim_vehicle_contexts() -> void:
    _airsim_vehicle_contexts.clear()
    for name in _airsim_vehicle_names:
        _airsim_vehicle_contexts[String(name)] = {
            "api_control": false,
            "armed": false,
            "disarm_requested": true,
            "command_state": {},
            "hold_controls": {},
            "command_remaining_frames": 0,
            "last_velocity": Vector3.ZERO,
            "linear_acceleration": Vector3.ZERO,
            "last_body_angular_velocity": Vector3.ZERO,
            "angular_acceleration": Vector3.ZERO,
            "collision_seen": false,
            "contact_this_frame": false,
            "collision_normal": Vector3.ZERO,
            "collision_point": Vector3.ZERO,
        }


func _set_secondary_collision_enabled(enabled: bool) -> void:
    if secondary_drone_body == null:
        return
    if not _secondary_collision_state_captured:
        _secondary_collision_layer = secondary_drone_body.collision_layer
        _secondary_collision_mask = secondary_drone_body.collision_mask
        _secondary_collision_shapes.clear()
        for child in secondary_drone_body.get_children():
            if child is CollisionShape3D:
                _secondary_collision_shapes.append({"node": child, "disabled": child.disabled})
        _secondary_collision_state_captured = true
    secondary_drone_body.collision_layer = _secondary_collision_layer if enabled else 0
    secondary_drone_body.collision_mask = _secondary_collision_mask if enabled else 0
    for shape_state in _secondary_collision_shapes:
        var collision_shape = shape_state.get("node")
        if is_instance_valid(collision_shape):
            collision_shape.disabled = bool(shape_state.get("disabled", false)) if enabled else true


func _configure_secondary_native(hardware_config: RefCounted) -> bool:
    _set_secondary_collision_enabled(false)
    if _airsim_vehicle_names.size() < 2 or secondary_drone_body == null:
        return _airsim_vehicle_names.size() < 2
    _airsim_secondary_native = ClassDB.instantiate("AeroSimNative")
    if _airsim_secondary_native == null:
        last_error_message = "second named vehicle native runtime unavailable"
        return false
    var primary_native := native
    native = _airsim_secondary_native
    var applied_result: Variant = hardware_config.apply_to_runtime(self, DEFAULT_HARDWARE_PRESET)
    var applied: bool = bool(applied_result)
    native = primary_native
    if not applied:
        last_error_message = "second named vehicle hardware preset failed: %s" % hardware_config.last_error
        return false
    if not _sync_secondary_a5_model():
        return false
    _set_secondary_collision_enabled(true)
    secondary_drone_body.visible = true
    if secondary_chase_camera != null:
        secondary_chase_camera.current = false
    return true


func _replay_timestamp_for_simulation_us(simulation_timestamp_us: int) -> int:
    if _replay_epoch_pending:
        var frame_interval_us := maxi(1, int(round(1_000_000.0 / float(airsim_session.physics_hz))) if airsim_session != null and airsim_session.physics_hz > 0 else 1)
        if simulation_timestamp_us <= _replay_last_simulation_timestamp_us:
            _replay_epoch_offset_us = maxi(
                _replay_epoch_offset_us,
                _replay_last_timestamp_us + frame_interval_us - simulation_timestamp_us)
        _replay_epoch_pending = false
    _replay_last_simulation_timestamp_us = simulation_timestamp_us
    _replay_last_timestamp_us = maxi(_replay_last_timestamp_us, simulation_timestamp_us + _replay_epoch_offset_us)
    return _replay_last_timestamp_us


func _replay_timestamp_for_recorded_frame(timestamp_us: int) -> int:
    if _replay_epoch_pending:
        var frame_interval_us := maxi(1, int(round(1_000_000.0 / float(airsim_session.physics_hz))) if airsim_session != null and airsim_session.physics_hz > 0 else 1)
        timestamp_us = maxi(timestamp_us, _replay_last_timestamp_us + frame_interval_us)
        _replay_epoch_pending = false
        _replay_last_timestamp_us = timestamp_us
    else:
        _replay_last_timestamp_us = maxi(_replay_last_timestamp_us, timestamp_us + _replay_epoch_offset_us)
    return _replay_last_timestamp_us


func _replay_timestamp_us() -> int:
    var simulation_timestamp_us := int(round((airsim_session.simulation_time_seconds if airsim_session != null else 0.0) * 1_000_000.0))
    return _replay_timestamp_for_simulation_us(simulation_timestamp_us)


func _replay_frame_timestamp_us() -> int:
    if airsim_session == null or airsim_session.physics_hz <= 0:
        return _replay_timestamp_us()
    var next_timestamp_us := int(round((airsim_session.simulation_time_seconds + 1.0 / float(airsim_session.physics_hz)) * 1_000_000.0))
    # This is a look-ahead value for the post-step checkpoint. Do not commit
    # it yet: the command/contact record for this frame still belongs at the
    # current frame start and is recorded later in _physics_process.
    return next_timestamp_us + _replay_epoch_offset_us


func _replay_manifest_hash(payload: String) -> String:
    var hashing := HashingContext.new()
    if hashing.start(HashingContext.HASH_SHA256) != OK:
        return ""
    hashing.update(payload.to_utf8_buffer())
    return hashing.finish().hex_encode()


func _replay_canonical_value(value: Variant) -> Variant:
    if value is Vector3:
        return [_replay_canonical_value(value.x), _replay_canonical_value(value.y), _replay_canonical_value(value.z)]
    if value is Dictionary:
        var sorted_keys: Array = value.keys()
        sorted_keys.sort()
        var sorted: Dictionary = {}
        for key in sorted_keys:
            sorted[key] = _replay_canonical_value(value[key])
        return sorted
    if value is Array:
        var normalized: Array = []
        for item in value:
            normalized.append(_replay_canonical_value(item))
        return normalized
    if value is float and is_equal_approx(value, round(value)):
        return int(round(value))
    return value


func _replay_canonical_json(value: Variant) -> String:
    return JSON.stringify(_replay_canonical_value(value))


func _begin_complete_replay_recording(startup_settings: Dictionary) -> void:
    _replay_recording_active = false
    _replay_last_timestamp_us = 0
    _replay_epoch_offset_us = 0
    _replay_last_simulation_timestamp_us = 0
    _replay_epoch_pending = false
    if native == null or _airsim_vehicle_names.size() != 2 or _airsim_secondary_native == null:
        return
    if not native.has_method("begin_complete_replay_recording") or not native.has_method("replay_vehicle_config_manifest"):
        push_error("Complete replay recording hooks are unavailable")
        return
    var settings_json := JSON.stringify(startup_settings)
    var upper_config_json := _replay_canonical_json(native.call("replay_vehicle_config_manifest"))
    var lower_config_json := _replay_canonical_json(_airsim_secondary_native.call("replay_vehicle_config_manifest"))
    _replay_settings_manifest_hash = _replay_manifest_hash(settings_json)
    _replay_upper_config_manifest_hash = _replay_manifest_hash(upper_config_json)
    _replay_lower_config_manifest_hash = _replay_manifest_hash(lower_config_json)
    if _replay_settings_manifest_hash.is_empty() or _replay_upper_config_manifest_hash.is_empty() or _replay_lower_config_manifest_hash.is_empty():
        push_error("Complete replay recording manifest hashing failed")
        return
    var result: Dictionary = native.call(
        "begin_complete_replay_recording",
        0,
        _replay_settings_manifest_hash,
        String(_airsim_vehicle_names[0]),
        _replay_upper_config_manifest_hash,
        upper_config_json,
        2 if px4_sitl_bridge != null else 0,
        String(_airsim_vehicle_names[1]),
        _replay_lower_config_manifest_hash,
        lower_config_json,
        0)
    if not bool(result.get("ok", false)):
        push_error("Complete replay recording could not start: %s" % String(result.get("diagnostic_message", "unknown error")))
        return
    _replay_recording_active = true


func _finish_complete_replay_recording(reason: String) -> Dictionary:
    if not _replay_recording_active or native == null:
        return {"ok": false, "error": "complete replay recording is inactive"}
    var result: Dictionary = native.call("finish_complete_replay_recording", _replay_timestamp_us(), reason)
    _replay_recording_active = false
    if bool(result.get("ok", false)):
        _last_complete_replay_serialized = String(result.get("serialized", ""))
        if not _last_complete_replay_serialized.is_empty():
            DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("user://replays"))
            var replay_file := FileAccess.open("user://replays/last_complete_replay.json", FileAccess.WRITE)
            if replay_file == null:
                push_error("Complete replay recording could not be persisted")
            else:
                replay_file.store_string(_last_complete_replay_serialized)
                replay_file.close()
    else:
        push_error("Complete replay recording could not finish: %s" % String(result.get("diagnostic_message", "unknown error")))
    return result


func complete_replay_recording() -> String:
    return _last_complete_replay_serialized


func _record_replay_command(vehicle_name: String, controls: Dictionary, timestamp_us: int = -1) -> void:
    if not _replay_recording_active or native == null:
        return
    var mode := String(controls.get("mode", "ANGLE"))
    var recorded_timestamp_us := _replay_timestamp_us() if timestamp_us < 0 else _replay_timestamp_for_recorded_frame(timestamp_us)
    var result: Dictionary
    if native.has_method("record_replay_mode_command"):
        result = native.call(
            "record_replay_mode_command",
            recorded_timestamp_us,
            vehicle_name,
            mode,
            float(controls.get("throttle", 0.0)),
            float(controls.get("acro_roll", controls.get("roll", 0.0))) if mode == "ACRO" else float(controls.get("roll", 0.0)),
            float(controls.get("acro_pitch", controls.get("pitch", 0.0))) if mode == "ACRO" else float(controls.get("pitch", 0.0)),
            float(controls.get("acro_yaw", controls.get("yaw_rate", 0.0))) if mode == "ACRO" else float(controls.get("yaw_rate", 0.0)),
            _acro_rate("rc_rate"),
            _acro_rate("super_rate"),
            _acro_rate("expo"),
            float(controls.get("altitude_m", 0.0)),
            0)
    else:
        result = native.call(
            "record_replay_command",
            recorded_timestamp_us,
            vehicle_name,
            float(controls.get("throttle", 0.0)),
            float(controls.get("roll", 0.0)),
            float(controls.get("pitch", 0.0)),
            float(controls.get("yaw_rate", 0.0)),
            0)
    if not bool(result.get("ok", false)):
        push_error("Complete replay command recording failed: %s" % String(result.get("diagnostic_message", "unknown error")))


func _record_replay_actuator_command(vehicle_name: String, actuator_outputs: PackedFloat32Array, timestamp_us: int) -> void:
    if not _replay_recording_active or native == null or actuator_outputs.size() < 4:
        return
    var result: Dictionary = native.call(
        "record_replay_actuator_command",
        _replay_timestamp_for_recorded_frame(timestamp_us),
        vehicle_name,
        clampf(float(actuator_outputs[0]), 0.0, 1.0),
        clampf(float(actuator_outputs[1]), 0.0, 1.0),
        clampf(float(actuator_outputs[2]), 0.0, 1.0),
        clampf(float(actuator_outputs[3]), 0.0, 1.0),
        2)
    if not bool(result.get("ok", false)):
        push_error("Complete replay actuator recording failed: %s" % String(result.get("diagnostic_message", "unknown error")))


func _record_replay_collision(vehicle_name: String, body, authority: int = 1, timestamp_us: int = -1) -> void:
    if not _replay_recording_active or native == null or body == null or not body.contact_seen:
        return
    var result: Dictionary = native.call(
        "record_replay_collision",
        _replay_timestamp_us() if timestamp_us < 0 else _replay_timestamp_for_recorded_frame(timestamp_us),
        vehicle_name,
        true,
        body.contact_normal.x,
        body.contact_normal.y,
        body.contact_normal.z,
        body.contact_impulse.x,
        body.contact_impulse.y,
        body.contact_impulse.z,
        0.0,
        body.linear_velocity.x,
        body.linear_velocity.y,
        body.linear_velocity.z,
        body.angular_velocity.x,
        body.angular_velocity.y,
        body.angular_velocity.z,
        _kinetic(body.linear_velocity, body.angular_velocity),
        true,
        authority)
    if not bool(result.get("ok", false)):
        push_error("Complete replay collision recording failed: %s" % String(result.get("diagnostic_message", "unknown error")))


func _record_replay_scene_object(operation: int, snapshot: Dictionary) -> void:
    if not _replay_recording_active or native == null or snapshot.is_empty():
        return
    var position: Vector3 = snapshot.get("position", Vector3.ZERO)
    var orientation: Quaternion = snapshot.get("orientation", Quaternion.IDENTITY)
    var result: Dictionary = native.call(
        "record_replay_scene_object",
        _replay_timestamp_us(),
        operation,
        String(snapshot.get("name", "")),
        String(snapshot.get("asset_id", "")),
        position,
        orientation)
    if not bool(result.get("ok", false)):
        push_error("Complete replay scene recording failed: %s" % String(result.get("diagnostic_message", "unknown error")))


func _record_replay_environment(state: Dictionary) -> void:
    if not _replay_recording_active or native == null:
        return
    var result: Dictionary = native.call("record_replay_environment", _replay_timestamp_us(), JSON.stringify(state))
    if not bool(result.get("ok", false)):
        push_error("Complete replay environment recording failed: %s" % String(result.get("diagnostic_message", "unknown error")))


func _record_replay_checkpoint(timestamp_us: int, upper_row: PackedFloat64Array) -> void:
    if not _replay_recording_active or native == null or upper_row.size() < 17 or _replay_secondary_row.size() < 17:
        return
    var result: Dictionary = native.call("record_replay_checkpoint", timestamp_us, upper_row, _replay_secondary_row)
    if not bool(result.get("ok", false)):
        push_error("Complete replay checkpoint recording failed: %s" % String(result.get("diagnostic_message", "unknown error")))


func _record_replay_simulation_operation(operation: int, value: float) -> void:
    if not _replay_recording_active or native == null:
        return
    var result: Dictionary = native.call("record_replay_simulation_operation", _replay_timestamp_us(), operation, value)
    if not bool(result.get("ok", false)):
        push_error("Complete replay simulation recording failed: %s" % String(result.get("diagnostic_message", "unknown error")))
    elif operation == 4 or operation == 5:
        _replay_epoch_pending = true


func _record_replay_async(simulation_time_seconds: float, vehicle_name: String, command_id: String, method: String, lifecycle: int) -> void:
    if not _replay_recording_active or native == null:
        return
    var timestamp_us := _replay_timestamp_for_simulation_us(int(round(simulation_time_seconds * 1_000_000.0)))
    var result: Dictionary = native.call("record_replay_async_command", timestamp_us, vehicle_name, command_id, method, lifecycle)
    if not bool(result.get("ok", false)):
        push_error("Complete replay async recording failed: %s" % String(result.get("diagnostic_message", "unknown error")))


func _replay_json_safe(value: Variant) -> Variant:
    if value is Vector3:
        return [value.x, value.y, value.z]
    if value is Dictionary:
        var result: Dictionary = {}
        for key in value:
            result[key] = _replay_json_safe(value[key])
        return result
    if value is Array:
        var result: Array = []
        for item in value:
            result.append(_replay_json_safe(item))
        return result
    return value


func replay_complete_session(serialized: String, expected_settings_manifest_hash: String, expected_upper_config_manifest_hash: String, expected_lower_config_manifest_hash: String) -> Dictionary:
    if native == null or not native.has_method("replay_complete_session"):
        return {"ok": false, "error": "native replay runtime is unavailable"}
    _replay_recording_active = false
    var parsed = JSON.parse_string(serialized)
    if typeof(parsed) != TYPE_DICTIONARY or typeof(parsed.get("events")) != TYPE_ARRAY or typeof(parsed.get("vehicles")) != TYPE_ARRAY:
        return {"ok": false, "error": "replay world payload is malformed"}
    var parsed_vehicles: Array = parsed.get("vehicles", [])
    if parsed_vehicles.size() != 2:
        return {"ok": false, "error": "replay requires exactly two vehicle manifests"}
    if _airsim_vehicle_names.size() != 2:
        return {"ok": false, "error": "runtime requires exactly two vehicle names for replay"}
    var expected_vehicle_hashes := [expected_upper_config_manifest_hash, expected_lower_config_manifest_hash]
    for index in 2:
        if typeof(parsed_vehicles[index]) != TYPE_DICTIONARY:
            return {"ok": false, "error": "replay vehicle manifest is malformed"}
        var vehicle: Dictionary = parsed_vehicles[index]
        if String(vehicle.get("name", "")) != String(_airsim_vehicle_names[index]):
            return {"ok": false, "error": "replay vehicle identity does not match runtime slot"}
        var config: Dictionary = vehicle.get("config", {})
        if String(vehicle.get("config_manifest_hash", "")) != String(expected_vehicle_hashes[index]) or _replay_manifest_hash(_replay_canonical_json(config)) != String(expected_vehicle_hashes[index]):
            return {"ok": false, "error": "replay vehicle config manifest integrity check failed"}
    for event in parsed.events:
        if typeof(event) != TYPE_DICTIONARY:
            return {"ok": false, "error": "replay event is malformed"}
        match String(event.get("type", "")):
            "scene_object":
                var position_values: Array = event.get("position", [])
                var orientation_values: Array = event.get("orientation", [])
                if position_values.size() != 3 or orientation_values.size() != 4 or scene_object_catalog == null:
                    return {"ok": false, "error": "replay scene object transform is malformed"}
                var position := Vector3(float(position_values[0]), float(position_values[1]), float(position_values[2]))
                var orientation := Quaternion(float(orientation_values[0]), float(orientation_values[1]), float(orientation_values[2]), float(orientation_values[3]))
                var operation := String(event.get("operation", ""))
                var world_result: Dictionary
                if operation == "spawn":
                    world_result = scene_object_catalog.create_named(String(event.get("name", "")), String(event.get("asset_id", "")), position, orientation)
                elif operation == "move":
                    world_result = scene_object_catalog.move_named(String(event.get("name", "")), position, orientation)
                elif operation == "destroy":
                    world_result = scene_object_catalog.destroy_named(String(event.get("name", "")))
                elif operation == "reset":
                    scene_object_catalog.reset()
                    world_result = {"ok": true}
                else:
                    return {"ok": false, "error": "unsupported replay scene operation"}
                if not bool(world_result.get("ok", false)):
                    return {"ok": false, "error": String(world_result.get("error", "replay scene application failed"))}
            "environment":
                var environment_result := _airsim_environment("simSetEnvironment", [event.get("state", {})])
                if not bool(environment_result.get("ok", false)):
                    return environment_result
            "simulation_time":
                if String(event.get("operation", "")) in ["reset", "respawn"]:
                    if scene_object_catalog != null:
                        scene_object_catalog.reset()
                    if environment_state != null:
                        _apply_environment_result(environment_state.reset())
    var native_result: Dictionary = native.call(
        "replay_complete_session", serialized, expected_settings_manifest_hash,
        expected_upper_config_manifest_hash, expected_lower_config_manifest_hash,
        native.call("replay_vehicle_config_manifest"),
        _airsim_secondary_native.call("replay_vehicle_config_manifest") if _airsim_secondary_native != null else {})
    if not bool(native_result.get("ok", false)):
        return native_result
    native_result["world_applied"] = true
    return native_result


func compare_complete_replay_sessions(expected_serialized: String, actual_serialized: String, expected_settings_manifest_hash: String) -> Dictionary:
    if native == null or not native.has_method("compare_complete_replay_sessions"):
        return {"ok": false, "error": "native replay comparison is unavailable"}
    return native.call("compare_complete_replay_sessions", expected_serialized, actual_serialized, expected_settings_manifest_hash)


func _secondary_body(vehicle_name: String):
    if _airsim_vehicle_names.size() > 1 and vehicle_name == String(_airsim_vehicle_names[1]):
        return secondary_drone_body
    return null


func _sync_secondary_a5_model() -> bool:
    if native == null or _airsim_secondary_native == null:
        return false
    if not native.has_method("a5_downwash_configuration") or not _airsim_secondary_native.has_method("set_a5_downwash_model"):
        last_error_message = "A5 downwash runtime hooks are unavailable"
        return false
    var configuration_result: Variant = native.call("a5_downwash_configuration")
    if typeof(configuration_result) != TYPE_DICTIONARY:
        last_error_message = "A5 downwash configuration is not a dictionary"
        return false
    var configuration: Dictionary = configuration_result
    if configuration == _airsim_secondary_a5_configuration:
        return true
    var enabled := bool(configuration.get("enabled", false))
    var prop_radius := float(configuration.get("prop_radius_m", 0.0))
    var coeff_1 := float(configuration.get("coeff_1", 0.0))
    var coeff_2 := float(configuration.get("coeff_2", 0.0))
    var coeff_3 := float(configuration.get("coeff_3", 0.0))
    if not enabled and prop_radius <= 0.0:
        _airsim_secondary_a5_configuration = configuration.duplicate(true)
        return true
    var apply_result: Variant = _airsim_secondary_native.call(
        "set_a5_downwash_model", enabled, prop_radius, coeff_1, coeff_2, coeff_3)
    if not bool(apply_result):
        last_error_message = "secondary A5 downwash model rejected validated configuration"
        return false
    _airsim_secondary_a5_configuration = configuration.duplicate(true)
    return true


func _is_primary_airsim_vehicle(vehicle_name: String) -> bool:
    return vehicle_name == _airsim_vehicle_name


func _load_player_settings() -> void:
    var result: Dictionary = settings_store.load_document()
    var saved = result.document.get("confirmed_gamepad")
    if saved != null:
        persisted_gamepad_profile = InputProfiles.GamepadProfile.from_persisted_dict(saved)
    var saved_rates = result.document.get("rates")
    if saved_rates != null:
        var rates_result: Dictionary = RatesProfile.validate_profile(saved_rates)
        if rates_result.ok:
            rates_profile = rates_result.profile
    if not result.ok and result.recovered:
        last_error_message = "Settings recovered to factory defaults: %s" % result.error


func _save_gamepad_profile(profile: InputProfiles.GamepadProfile) -> Dictionary:
    var loaded: Dictionary = settings_store.load_document()
    var document: Dictionary = loaded.document
    document["confirmed_gamepad"] = profile.to_persisted_dict()
    var result: Dictionary = settings_store.save_document(document)
    if result.ok:
        persisted_gamepad_profile = InputProfiles.GamepadProfile.from_persisted_dict(document["confirmed_gamepad"])
        keyboard_fallback_explicitly_selected = false
    return result


func _save_rates_profile(profile: Dictionary) -> Dictionary:
    var validation: Dictionary = RatesProfile.validate_profile(profile)
    if not validation.ok:
        return validation
    var loaded: Dictionary = settings_store.load_document()
    if not loaded.ok:
        return {"ok": false, "error": "cannot save rates while settings are unavailable: %s" % loaded.error}
    var document: Dictionary = loaded.document
    document["rates"] = validation.profile
    var result: Dictionary = settings_store.save_document(document)
    if result.ok:
        rates_profile = validation.profile
    return result

func _run_cold_start_probe() -> void:
    var report_path := _cold_start_report_path()
    if report_path.is_empty():
        return
    quick_fly()
    accept_fallback()
    await RenderingServer.frame_post_draw
    var screenshot_path := _cold_start_arg("--aerosim-cold-start-screenshot")
    var screenshot := get_viewport().get_texture().get_image()
    var screenshot_written := not screenshot_path.is_empty() and screenshot.save_png(screenshot_path) == OK
    var result := {
        "display_driver": DisplayServer.get_name(),
        "flyable": native != null and screen == "preflight" and not takeoff_requested and not paused and screenshot_written and _cold_start_frame_is_observable(screenshot),
        "frame_post_draw": true,
        "screen": screen,
        "screenshot": screenshot_path,
        "screenshot_written": screenshot_written,
    }
    var report := FileAccess.open(report_path, FileAccess.WRITE)
    if report == null:
        push_error("Cannot write cold-start report: %s" % report_path)
        get_tree().quit(1)
        return
    report.store_string(JSON.stringify(result))
    report.close()
    if bool(result["flyable"]):
        await get_tree().create_timer(float(_cold_start_arg("--aerosim-cold-start-visible-seconds", "3"))).timeout
    get_tree().quit(0 if bool(result["flyable"]) else 1)

func _cold_start_report_path() -> String:
    return _cold_start_arg("--aerosim-cold-start-report")

func _cold_start_arg(name: String, default_value := "") -> String:
    var args := OS.get_cmdline_user_args()
    for index in range(args.size() - 1):
        if args[index] == name:
            return args[index + 1]
    return default_value

func _cold_start_frame_is_observable(image: Image) -> bool:
    if image.is_empty():
        return false
    image.convert(Image.FORMAT_RGBA8)
    var counts := {}
    var max_count := 0
    var data := image.get_data()
    for offset in range(0, data.size(), 4):
        var color := (int(data[offset]) << 16) | (int(data[offset + 1]) << 8) | int(data[offset + 2])
        counts[color] = int(counts.get(color, 0)) + 1
        max_count = maxi(max_count, int(counts[color]))
    return float(max_count) / float(image.get_width() * image.get_height()) < 0.99

func _write_airsim_ready_marker(path: String) -> void:
    if path.is_empty():
        return
    var marker := FileAccess.open(path, FileAccess.WRITE)
    if marker == null:
        push_error("Cannot write AirSim readiness marker: %s" % path)
        return
    marker.store_string("ready")
    marker.close()

func _unhandled_input(event: InputEvent) -> void:
    if event is InputEventJoypadButton and _handle_gamepad_button(event):
        return
    if event.is_action_pressed("flight_takeoff") and screen in ["preflight", "flight"]:
        arm_and_takeoff()
    elif event.is_action_pressed("flight_pause") and screen == "flight":
        set_paused(not paused)
    elif event.is_action_pressed("flight_respawn"):
        respawn()
    elif event.is_action_pressed("flight_acro"):
        toggle_acro_mode()
    elif event.is_action_pressed("flight_altitude_hold"):
        toggle_altitude_hold()
    elif event.is_action_pressed("flight_exit"):
        request_exit()

func _process(_delta: float) -> void:
    if not airsim_stop_file.is_empty() and FileAccess.file_exists(airsim_stop_file):
        get_tree().quit()
        return
    if airsim_session != null and paused != airsim_session.is_paused():
        if not airsim_session.is_paused() and _airsim_lifecycle_stopped() and not airsim_session.is_explicit_step_active():
            airsim_session.set_paused(true)
        else:
            set_paused(airsim_session.is_paused(), false)
    _update_chase_camera()
    _refresh_controller_confirmation()
    _refresh_controller_settings()
    _refresh_flight_hud()

func _physics_process(delta: float) -> void:
    if reset_hold_frames > 0:
        reset_hold_frames -= 1
        if reset_hold_frames == 0 and drone_body != null and not paused:
            drone_body.freeze = false
            drone_body.sleeping = false
        return
    if paused:
        if airsim_session != null and not airsim_session.is_paused():
            set_paused(false, false)
        if paused:
            return
    # AirSim advances its session clock before stepping native physics below.
    # Commands and contacts therefore belong to this frame's native start time;
    # checkpoints use the post-step frame timestamp separately.
    var replay_timestamp_us := _replay_timestamp_us()
    var replay_frame_timestamp_us := _replay_frame_timestamp_us()
    _replay_secondary_row = PackedFloat64Array()
    if _airsim_secondary_native != null and secondary_drone_body != null and (airsim_session == null or not airsim_session.is_paused()):
        _step_secondary_airsim_vehicle(String(_airsim_vehicle_names[1]), replay_timestamp_us)
    if px4_sitl_bridge != null:
        px4_sitl_bridge.poll(Time.get_ticks_usec() / 1000000.0)
        if px4_sitl_bridge.state == "failed":
            last_error_message = px4_sitl_bridge.diagnostics().message
            set_paused(true, false)
            _advance_airsim_sensors()
            return
        if px4_sitl_bridge.state == "stale":
            last_error_message = px4_sitl_bridge.diagnostics().message
    var px4_lockstep_active := px4_sitl_bridge != null and px4_sitl_bridge.lockstep_active()
    if not px4_lockstep_active:
        _px4_lockstep_sensor_pending = false
    if px4_lockstep_active and not _px4_lockstep_sensor_pending:
        _publish_px4_lockstep_sensor_if_needed()
        _px4_lockstep_sensor_pending = true
    var session_advanced := true
    if airsim_session != null and not px4_lockstep_active:
        session_advanced = airsim_session.advance_frame()
        if not session_advanced and airsim_session.is_paused():
            set_paused(true, false)
            return
    if px4_sitl_bridge != null and not px4_lockstep_active:
        px4_sitl_bridge.publish_sensor_snapshot(_airsim_state(_airsim_vehicle_name).get("state", {}), airsim_session.simulation_time_seconds if airsim_session != null else 0.0)
    if native == null or paused or not takeoff_requested:
        if px4_lockstep_active and _px4_lockstep_sensor_pending:
            if airsim_session != null:
                session_advanced = airsim_session.advance_frame()
                if not session_advanced and airsim_session.is_paused():
                    set_paused(true, false)
                    return
            _publish_px4_lockstep_sensor_if_needed()
        _advance_airsim_sensors()
        return
    _airsim_contact_this_frame = false
    if px4_sitl_bridge == null and not native.call("flight_control_armed") and not _airsim_disarm_requested:
        native.call("arm_flight_control", 0.0)
    var throttle := _flight_throttle()
    var angle_roll := _angle_roll_degrees()
    var angle_pitch := _angle_pitch_degrees()
    var angle_yaw := _angle_yaw_rate_degrees_per_second()
    var acro_roll := _profile_axis("roll") if _has_active_gamepad_profile() else _acro_roll_stick()
    var acro_pitch := _profile_axis("pitch") if _has_active_gamepad_profile() else _acro_pitch_stick()
    var acro_yaw := _profile_axis("yaw") if _has_active_gamepad_profile() else _acro_yaw_stick()
    var airsim_controls := _airsim_controls_for_frame()
    if not airsim_controls.is_empty():
        throttle = float(airsim_controls.get("throttle", throttle))
        angle_roll = float(airsim_controls.get("roll", angle_roll))
        angle_pitch = float(airsim_controls.get("pitch", angle_pitch))
        angle_yaw = float(airsim_controls.get("yaw_rate", angle_yaw))
        acro_roll = float(airsim_controls.get("acro_roll", acro_roll))
        acro_pitch = float(airsim_controls.get("acro_pitch", acro_pitch))
        acro_yaw = float(airsim_controls.get("acro_yaw", acro_yaw))
        if airsim_controls.has("mode"):
            flight_mode = String(airsim_controls["mode"])
    if px4_sitl_bridge == null:
        _record_replay_command(_airsim_vehicle_name, {
            "mode": flight_mode,
            "throttle": throttle,
            "roll": angle_roll,
            "pitch": angle_pitch,
            "yaw_rate": angle_yaw,
            "acro_roll": acro_roll,
            "acro_pitch": acro_pitch,
            "acro_yaw": acro_yaw,
            "altitude_m": drone_body.global_position.y if drone_body != null else 0.0,
        }, replay_timestamp_us)
    var row: PackedFloat64Array
    if px4_sitl_bridge != null:
        var actuator_outputs := px4_sitl_bridge.actuator_outputs()
        if actuator_outputs.size() < 4:
            # PX4 needs a sensor frame before it can emit its first actuator
            # frame. Keep the transport ticking through that bootstrap window
            # instead of freezing the producer after the first HIL packet.
            last_error_message = "PX4 actuator output is pending"
            if px4_lockstep_active:
                if airsim_session != null:
                    session_advanced = airsim_session.advance_frame()
                    if not session_advanced and airsim_session.is_paused():
                        set_paused(true, false)
                        return
                _publish_px4_lockstep_sensor_if_needed()
            _advance_airsim_sensors()
            return
        _record_replay_actuator_command(_airsim_vehicle_name, actuator_outputs, replay_timestamp_us)
        var actuator_has_thrust := false
        for actuator in actuator_outputs:
            if absf(float(actuator)) > 0.05:
                actuator_has_thrust = true
                break
        if not actuator_has_thrust:
            # Keep the HIL vehicle stationary while PX4 is disarmed or in a
            # failsafe bootstrap. Advancing the native body with zero output
            # would make EKF2 lose its ground reference before takeoff.
            if drone_body != null:
                drone_body.freeze = true
                drone_body.sleeping = true
            last_error_message = "PX4 thrust output is pending"
            if px4_lockstep_active:
                if airsim_session != null:
                    session_advanced = airsim_session.advance_frame()
                    if not session_advanced and airsim_session.is_paused():
                        set_paused(true, false)
                        return
                _publish_px4_lockstep_sensor_if_needed()
            _advance_airsim_sensors()
            return
        if drone_body != null:
            drone_body.freeze = false
            drone_body.sleeping = false
            _sync_native_from_drone()
        row = native.call(
            "step_collision_px4_actuator_mode",
            Engine.physics_ticks_per_second,
            1000,
            clampf(actuator_outputs[0], 0.0, 1.0),
            clampf(actuator_outputs[1], 0.0, 1.0),
            clampf(actuator_outputs[2], 0.0, 1.0),
            clampf(actuator_outputs[3], 0.0, 1.0),
            drone_body != null and drone_body.contact_seen,
            drone_body.contact_normal.x if drone_body != null else 0.0,
            drone_body.contact_normal.y if drone_body != null else 0.0,
            drone_body.contact_normal.z if drone_body != null else 0.0,
            drone_body.contact_impulse.x if drone_body != null else 0.0,
            drone_body.contact_impulse.y if drone_body != null else 0.0,
            drone_body.contact_impulse.z if drone_body != null else 0.0,
            0.0,
            drone_body.linear_velocity.x if drone_body != null else 0.0,
            drone_body.linear_velocity.y if drone_body != null else 0.0,
            drone_body.linear_velocity.z if drone_body != null else 0.0,
            drone_body.angular_velocity.x if drone_body != null else 0.0,
            drone_body.angular_velocity.y if drone_body != null else 0.0,
            drone_body.angular_velocity.z if drone_body != null else 0.0,
            _kinetic(drone_body.linear_velocity, drone_body.angular_velocity) if drone_body != null else -1.0
        )
        if drone_body != null and drone_body.contact_seen:
            _record_replay_collision(_airsim_vehicle_name, drone_body, int(row[12]) if row.size() >= 13 else 0, replay_timestamp_us)
            collision_handoff_count += 1
            _airsim_contact_this_frame = true
            _airsim_collision_seen = true
            _airsim_collision_normal = drone_body.contact_normal
            _airsim_collision_point = drone_body.global_position
            drone_body.reset_contact()
    elif drone_body != null:
        _sync_native_from_drone()
        var energy_limit := _kinetic(drone_body.linear_velocity, drone_body.angular_velocity)
        if flight_mode == "ACRO":
            row = native.call(
                "step_collision_acro_mode",
                Engine.physics_ticks_per_second,
                1000,
                throttle,
                acro_roll,
                acro_pitch,
                acro_yaw,
                _acro_rate("rc_rate"),
                _acro_rate("super_rate"),
                _acro_rate("expo"),
                drone_body.contact_seen,
                drone_body.contact_normal.x,
                drone_body.contact_normal.y,
                drone_body.contact_normal.z,
                drone_body.contact_impulse.x,
                drone_body.contact_impulse.y,
                drone_body.contact_impulse.z,
                0.0,
                drone_body.linear_velocity.x,
                drone_body.linear_velocity.y,
                drone_body.linear_velocity.z,
                drone_body.angular_velocity.x,
                drone_body.angular_velocity.y,
                drone_body.angular_velocity.z,
                energy_limit
            )
        else:
            var step_method := "step_collision_altitude_hold_mode" if flight_mode == "ALTITUDE_HOLD" else "step_collision_angle_mode"
            row = native.call(
                step_method,
                Engine.physics_ticks_per_second,
                1000,
                throttle,
                angle_roll,
                angle_pitch,
                angle_yaw,
                drone_body.contact_seen,
                drone_body.contact_normal.x,
                drone_body.contact_normal.y,
                drone_body.contact_normal.z,
                drone_body.contact_impulse.x,
                drone_body.contact_impulse.y,
                drone_body.contact_impulse.z,
                0.0,
                drone_body.linear_velocity.x,
                drone_body.linear_velocity.y,
                drone_body.linear_velocity.z,
                drone_body.angular_velocity.x,
                drone_body.angular_velocity.y,
                drone_body.angular_velocity.z,
                energy_limit
            )
        if drone_body.contact_seen:
            _record_replay_collision(_airsim_vehicle_name, drone_body, int(row[12]) if row.size() >= 13 else 0, replay_timestamp_us)
            collision_handoff_count += 1
            _airsim_contact_this_frame = true
            _airsim_collision_seen = true
            _airsim_collision_normal = drone_body.contact_normal
            _airsim_collision_point = drone_body.global_position
        drone_body.reset_contact()
    else:
        if flight_mode == "ACRO":
            row = native.call("step_acro_mode", Engine.physics_ticks_per_second, 1000, throttle, acro_roll, acro_pitch, acro_yaw, _acro_rate("rc_rate"), _acro_rate("super_rate"), _acro_rate("expo"))
        else:
            var free_flight_method := "step_altitude_hold_mode" if flight_mode == "ALTITUDE_HOLD" else "step_angle_mode"
            row = native.call(free_flight_method, Engine.physics_ticks_per_second, 1000, throttle, angle_roll, angle_pitch, angle_yaw)
    if row.size() >= 13:
        last_collision_authority = int(row[12])
    if drone_body != null and row.size() >= 17:
        _record_replay_checkpoint(replay_frame_timestamp_us, row)
        drone_body.apply_native_state(
            Vector3(row[1], row[2], row[3]),
            Quaternion(row[4], row[5], row[6], row[7]),
            Vector3(row[8], row[9], row[10]),
            Vector3(row[14], row[15], row[16])
        )
    _advance_px4_path()
    if px4_lockstep_active:
        if airsim_session != null:
            session_advanced = airsim_session.advance_frame()
            if not session_advanced and airsim_session.is_paused():
                set_paused(true, false)
                return
        _publish_px4_lockstep_sensor_if_needed()
    if airsim_session != null and airsim_session.is_paused():
        set_paused(true, false)
    if not _airsim_command_state.is_empty() and _airsim_command_remaining_frames > 0:
        _airsim_command_remaining_frames -= 1
        if _airsim_command_remaining_frames == 0 and String(_airsim_command_state.get("method", "")) in ["moveByVelocity", "moveByVelocityZ", "moveByVelocityBodyFrame", "moveByVelocityZBodyFrame", "rotateByYawRate", "moveByAngleRatesThrottle"]:
            _airsim_hold_controls = _airsim_neutral_controls()
            _airsim_command_state.clear()
    if drone_body != null:
        _airsim_linear_acceleration = (drone_body.linear_velocity - _airsim_last_velocity) * float(Engine.physics_ticks_per_second)
        var body_angular_velocity: Vector3 = drone_body.global_transform.basis.inverse() * drone_body.angular_velocity
        _airsim_angular_acceleration = (body_angular_velocity - _airsim_last_body_angular_velocity) * float(Engine.physics_ticks_per_second)
        _airsim_last_body_angular_velocity = body_angular_velocity
    else:
        _airsim_linear_acceleration = Vector3.ZERO
        _airsim_angular_acceleration = Vector3.ZERO
    _airsim_last_velocity = drone_body.linear_velocity if drone_body != null else Vector3.ZERO
    if native != null and native.has_method("refresh_imu_sample"):
        native.call("refresh_imu_sample")
    if time_trial != null and drone_body != null:
        time_trial.advance(drone_body.global_position, 1.0 / float(Engine.physics_ticks_per_second))
    _advance_airsim_sensors()
    _update_status_diagram()


func _advance_airsim_sensors() -> void:
    if airsim_sensor_suite == null or airsim_session == null:
        return
    var names: Array = _airsim_vehicle_names if not _airsim_vehicle_names.is_empty() else [_airsim_vehicle_name]
    for name in names:
        var sensor_state := _airsim_state(String(name))
        if bool(sensor_state.get("ok", false)):
            airsim_sensor_suite.advance(airsim_session.simulation_time_seconds, String(name), sensor_state.state)


func _step_secondary_airsim_vehicle(vehicle_name: String, replay_timestamp_us: int = -1) -> void:
    var context: Dictionary = _airsim_vehicle_contexts.get(vehicle_name, {})
    if context.is_empty() or not bool(context.get("api_control", false)) or not bool(context.get("armed", false)):
        return
    var body = _secondary_body(vehicle_name)
    if body == null or _airsim_secondary_native == null:
        return
    body.freeze = false
    body.sleeping = false
    _sync_named_native(body, _airsim_secondary_native)
    if not _sync_secondary_a5_model():
        return
    if _airsim_secondary_native.has_method("set_a5_downwash_source_position") and drone_body != null:
        _airsim_secondary_native.call(
            "set_a5_downwash_source_position",
            drone_body.global_position.x,
            drone_body.global_position.y,
            drone_body.global_position.z)
    var controls := _airsim_secondary_controls(context, body)
    controls["altitude_m"] = body.global_position.y
    _record_replay_command(vehicle_name, controls, replay_timestamp_us)
    var row: PackedFloat64Array
    if String(controls.get("mode", "ANGLE")) == "ACRO":
        row = _airsim_secondary_native.call(
            "step_collision_acro_mode",
            Engine.physics_ticks_per_second,
            1000,
            float(controls.get("throttle", 0.0)),
            float(controls.get("acro_roll", 0.0)),
            float(controls.get("acro_pitch", 0.0)),
            float(controls.get("acro_yaw", 0.0)),
            _acro_rate("rc_rate"),
            _acro_rate("super_rate"),
            _acro_rate("expo"),
            body.contact_seen,
            body.contact_normal.x,
            body.contact_normal.y,
            body.contact_normal.z,
            body.contact_impulse.x,
            body.contact_impulse.y,
            body.contact_impulse.z,
            0.0,
            body.linear_velocity.x,
            body.linear_velocity.y,
            body.linear_velocity.z,
            body.angular_velocity.x,
            body.angular_velocity.y,
            body.angular_velocity.z,
            _kinetic(body.linear_velocity, body.angular_velocity))
    elif String(controls.get("mode", "ANGLE")) == "ALTITUDE_HOLD":
        row = _airsim_secondary_native.call(
            "step_collision_altitude_hold_mode",
            Engine.physics_ticks_per_second,
            1000,
            float(controls.get("throttle", 0.0)),
            float(controls.get("roll", 0.0)),
            float(controls.get("pitch", 0.0)),
            float(controls.get("yaw_rate", 0.0)),
            body.contact_seen,
            body.contact_normal.x,
            body.contact_normal.y,
            body.contact_normal.z,
            body.contact_impulse.x,
            body.contact_impulse.y,
            body.contact_impulse.z,
            0.0,
            body.linear_velocity.x,
            body.linear_velocity.y,
            body.linear_velocity.z,
            body.angular_velocity.x,
            body.angular_velocity.y,
            body.angular_velocity.z,
            _kinetic(body.linear_velocity, body.angular_velocity))
    else:
        row = _airsim_secondary_native.call(
            "step_collision_angle_mode",
            Engine.physics_ticks_per_second,
            1000,
            float(controls.get("throttle", 0.0)),
            float(controls.get("roll", 0.0)),
            float(controls.get("pitch", 0.0)),
            float(controls.get("yaw_rate", 0.0)),
            body.contact_seen,
            body.contact_normal.x,
            body.contact_normal.y,
            body.contact_normal.z,
            body.contact_impulse.x,
            body.contact_impulse.y,
            body.contact_impulse.z,
            0.0,
            body.linear_velocity.x,
            body.linear_velocity.y,
            body.linear_velocity.z,
            body.angular_velocity.x,
            body.angular_velocity.y,
            body.angular_velocity.z,
            _kinetic(body.linear_velocity, body.angular_velocity))
    if row.size() >= 17:
        _replay_secondary_row = row
        body.apply_native_state(
            Vector3(row[1], row[2], row[3]),
            Quaternion(row[4], row[5], row[6], row[7]),
            Vector3(row[8], row[9], row[10]),
            Vector3(row[14], row[15], row[16]))
    if body.contact_seen:
        _record_replay_collision(vehicle_name, body, int(row[12]) if row.size() >= 13 else 0, replay_timestamp_us)
        context["collision_seen"] = true
        context["contact_this_frame"] = true
        context["collision_normal"] = body.contact_normal
        context["collision_point"] = body.global_position
    else:
        context["contact_this_frame"] = false
    body.reset_contact()
    if int(context.get("command_remaining_frames", 0)) > 0:
        context["command_remaining_frames"] = int(context["command_remaining_frames"]) - 1
    if int(context.get("command_remaining_frames", 0)) == 0:
        var method := String(context.get("command_state", {}).get("method", ""))
        if method in ["moveByVelocity", "moveByVelocityZ", "moveByVelocityBodyFrame", "moveByVelocityZBodyFrame", "rotateByYawRate", "moveByAngleRatesThrottle"]:
            context["hold_controls"] = _airsim_neutral_controls()
            context["command_state"] = {}
    context["linear_acceleration"] = (body.linear_velocity - context.get("last_velocity", Vector3.ZERO)) * float(Engine.physics_ticks_per_second)
    context["last_velocity"] = body.linear_velocity
    var body_angular_velocity: Vector3 = body.global_transform.basis.inverse() * body.angular_velocity
    context["angular_acceleration"] = (body_angular_velocity - context.get("last_body_angular_velocity", Vector3.ZERO)) * float(Engine.physics_ticks_per_second)
    context["last_body_angular_velocity"] = body_angular_velocity
    _airsim_vehicle_contexts[vehicle_name] = context
    if _airsim_secondary_native.has_method("refresh_imu_sample"):
        _airsim_secondary_native.call("refresh_imu_sample")


func _airsim_secondary_controls(context: Dictionary, body) -> Dictionary:
    var command_state: Dictionary = context.get("command_state", {})
    if command_state.is_empty():
        return context.get("hold_controls", _airsim_neutral_controls()).duplicate(true)
    var method := String(command_state.get("method", ""))
    var args: Array = command_state.get("args", [])
    match method:
        "takeoff":
            return _airsim_velocity_controls(Vector3(0.0, clampf((3.0 - body.global_position.y) * 1.5, -3.0, 3.0), 0.0), 0.0, null, body)
        "land":
            return _airsim_velocity_controls(Vector3(0.0, clampf(-body.global_position.y * 1.5, -3.0, 3.0), 0.0), 0.0, null, body)
        "hover":
            return _airsim_velocity_controls(Vector3.ZERO, 0.0, null, body)
        "moveByVelocity":
            return _airsim_velocity_controls(AirSimCoordinateContract.ned_direction_to_godot(Vector3(float(args[0]), float(args[1]), float(args[2]))), 0.0, args[5], body)
        "moveByVelocityZ":
            return _airsim_velocity_controls(AirSimCoordinateContract.ned_direction_to_godot(Vector3(float(args[0]), float(args[1]), 0.0)), (-float(args[2]) - body.global_position.y) * 4.0, args[5], body)
        "moveByVelocityBodyFrame":
            return _airsim_velocity_controls(body.global_transform.basis * AirSimCoordinateContract.frd_to_godot_body(Vector3(float(args[0]), float(args[1]), float(args[2]))), 0.0, args[5], body)
        "moveByVelocityZBodyFrame":
            return _airsim_velocity_controls(body.global_transform.basis * AirSimCoordinateContract.frd_to_godot_body(Vector3(float(args[0]), float(args[1]), 0.0)), (-float(args[2]) - body.global_position.y) * 4.0, args[5], body)
        "goHome":
            var home_delta: Vector3 = _spawn_position() - body.global_position
            var home_horizontal := Vector3(home_delta.x, 0.0, home_delta.z)
            var home_velocity := home_horizontal.normalized() * minf(home_horizontal.length() * 1.5, 4.0)
            home_velocity.y = clampf(home_delta.y * 4.0 - body.linear_velocity.y * 3.0, -8.0, 8.0)
            return _airsim_velocity_controls(home_velocity, 0.0, null, body)
        "moveToPosition", "moveOnPath":
            var target_ned: Vector3
            if method == "moveToPosition":
                target_ned = Vector3(float(args[0]), float(args[1]), float(args[2]))
            else:
                var path: Array = args[0]
                var waypoint_index := int(command_state.get("waypoint_index", 0))
                if waypoint_index >= path.size():
                    context["hold_controls"] = _airsim_neutral_controls()
                    context["command_state"] = {}
                    return context["hold_controls"].duplicate(true)
                var waypoint: Dictionary = path[waypoint_index]
                target_ned = Vector3(float(waypoint["x_val"]), float(waypoint["y_val"]), float(waypoint["z_val"]))
            var delta_world: Vector3 = AirSimCoordinateContract.ned_to_godot_world(target_ned, _spawn_position()) - body.global_position
            var command_speed := float(args[3]) if method == "moveToPosition" else float(args[1])
            if method == "moveOnPath" and delta_world.length() < 0.25:
                command_state["waypoint_index"] = int(command_state.get("waypoint_index", 0)) + 1
                context["command_state"] = command_state
            var yaw_mode: Variant = args[6] if method == "moveToPosition" else args[4]
            return _airsim_velocity_controls(delta_world.normalized() * minf(delta_world.length() * 2.0, command_speed), delta_world.y * 4.0, yaw_mode, body)
        "rotateToYaw":
            var target_yaw := AirSimCoordinateContract.ned_yaw_degrees_to_godot_radians(float(args[0]))
            var delta_yaw := wrapf(target_yaw - body.rotation.y, -PI, PI)
            var rotate_to_controls := _airsim_velocity_controls(Vector3.ZERO, 0.0, null, body)
            rotate_to_controls["yaw_rate"] = clampf(rad_to_deg(delta_yaw) * 3.0, -ANGLE_MAX_YAW_RATE_DPS, ANGLE_MAX_YAW_RATE_DPS)
            return rotate_to_controls
        "rotateByYawRate":
            var rotate_rate_controls := _airsim_velocity_controls(Vector3.ZERO, 0.0, null, body)
            rotate_rate_controls["yaw_rate"] = clampf(-float(args[0]), -ANGLE_MAX_YAW_RATE_DPS, ANGLE_MAX_YAW_RATE_DPS)
            return rotate_rate_controls
        "moveByAngleRatesThrottle":
            return {"mode": "ACRO", "throttle": float(args[3]), "acro_roll": _airsim_rate_stick(rad_to_deg(float(args[0])), _airsim_secondary_native), "acro_pitch": _airsim_rate_stick(rad_to_deg(float(args[1])), _airsim_secondary_native), "acro_yaw": _airsim_rate_stick(rad_to_deg(float(args[2])), _airsim_secondary_native)}
    return _airsim_neutral_controls()


func _sync_named_native(body: Object, target_native: Object) -> void:
    var q: Quaternion = body.global_transform.basis.get_rotation_quaternion()
    target_native.call(
        "sync_flight_state",
        body.global_position.x,
        body.global_position.y,
        body.global_position.z,
        q.x,
        q.y,
        q.z,
        q.w,
        body.linear_velocity.x,
        body.linear_velocity.y,
        body.linear_velocity.z,
        body.angular_velocity.x,
        body.angular_velocity.y,
        body.angular_velocity.z)


func _publish_px4_lockstep_sensor_if_needed() -> void:
    if px4_sitl_bridge == null:
        return
    var simulation_time := airsim_session.simulation_time_seconds if airsim_session != null else 0.0
    var diagnostics := px4_sitl_bridge.diagnostics()
    var last_sensor_time := float(diagnostics.get("last_sensor_time", -1.0))
    if last_sensor_time + 0.000001 >= simulation_time:
        return
    px4_sitl_bridge.publish_sensor_snapshot(_airsim_state(_airsim_vehicle_name).get("state", {}), simulation_time)

func request_takeoff() -> void:
    screen = "flight"
    flight_mode = "ANGLE"
    set_paused(false)
    takeoff_requested = true
    update_fallback_status()
    if drone_body != null:
        if not reset_to_spawn():
            return
        drone_body.freeze = false
        drone_body.sleeping = false
        drone_body.apply_native_state(drone_body.global_position, drone_body.global_transform.basis.get_rotation_quaternion(), TAKEOFF_VELOCITY, Vector3.ZERO)
    if time_trial != null:
        time_trial.start()
    _refresh_flight_hud()

func arm_and_takeoff() -> void:
    if controller_safety_latched:
        last_error_message = "Arm blocked: controller_resume_required"
        _refresh_flight_hud()
        return
    if native == null:
        last_error_message = "Quick Fly cannot arm: native runtime unavailable"
        screen = "error"
        _refresh_flight_hud()
        return
    if not _has_active_gamepad_profile() and not keyboard_fallback_explicitly_selected:
        last_error_message = "Arm blocked: keyboard_fallback_requires_confirmation"
        _refresh_flight_hud()
        return
    if _has_active_gamepad_profile() and not _profile_throttle_is_low():
        last_error_message = "Arm blocked: throttle_not_low"
        _refresh_flight_hud()
        return
    if px4_sitl_bridge != null:
        var px4_arm_result := px4_sitl_bridge.arm_disarm(true)
        if not px4_arm_result.ok:
            last_error_message = "PX4 arm failed: %s" % px4_arm_result.error
            _refresh_flight_hud()
            return
        request_takeoff()
        return
    if not native.call("flight_control_armed") and not native.call("arm_flight_control", 0.0):
        last_error_message = "Quick Fly cannot arm: %s" % native.call("flight_control_arm_reject_code")
        screen = "error"
        _refresh_flight_hud()
        return
    request_takeoff()

func request_exit() -> void:
    if airsim_rpc_server != null:
        airsim_rpc_server.cancel_pending_async_tasks("complete replay recording terminated")
    _finish_complete_replay_recording("exit")
    exit_requested = true
    takeoff_requested = false
    paused = true
    reset_hold_frames = 0
    _reset_airsim_flight_state()
    if native != null:
        native.call("reset_flight")
    if drone_body != null:
        drone_body.reset_contact()
        drone_body.freeze = true
    unload_map()
    screen = "main_menu"
    _refresh_flight_hud()
    if quit_on_exit:
        get_tree().quit()

func quick_fly() -> void:
    var device_id := _first_connected_device()
    var current_profile := InputProfiles.GamepadProfile.xbox_default(device_id, gamepad_device_state)
    if current_profile == null:
        session_gamepad_profile = null
        session_gamepad_device_id = -1
        if device_id < 0:
            _show_keyboard_fallback(InputProfiles.fallback_status([]))
        else:
            _show_keyboard_fallback("Unsupported controller; Xbox default profile is unavailable. KeyboardProfile fallback active (non-sim control)")
        return
    if session_gamepad_profile == null or session_gamepad_device_id != device_id:
        if persisted_gamepad_profile != null:
            session_gamepad_profile = InputProfiles.GamepadProfile.from_persisted_dict(persisted_gamepad_profile.to_persisted_dict())
            session_gamepad_device_id = device_id
            enter_preflight()
            return
        begin_controller_confirmation(device_id)
        return
    enter_preflight()

func begin_controller_confirmation(device_id: int = _first_connected_device()) -> void:
    var profile := InputProfiles.GamepadProfile.xbox_default(device_id, gamepad_device_state)
    if profile == null:
        session_gamepad_profile = null
        session_gamepad_device_id = -1
        _show_keyboard_fallback("Unsupported controller; Xbox default profile is unavailable. KeyboardProfile fallback active (non-sim control)")
        return
    controller_confirmation_device_id = device_id
    controller_confirmation_profile = profile
    screen = "controller_confirmation"
    if controller_confirmation_panel == null:
        _build_controller_confirmation()
    controller_confirmation_panel.show()
    _refresh_controller_confirmation()
    _refresh_flight_hud()

func accept_controller_confirmation() -> void:
    var profile := InputProfiles.GamepadProfile.xbox_default(controller_confirmation_device_id, gamepad_device_state)
    if profile == null:
        session_gamepad_profile = null
        session_gamepad_device_id = -1
        _show_keyboard_fallback("Unsupported controller; Xbox default profile is unavailable. KeyboardProfile fallback active (non-sim control)")
        return
    var save_result := _save_gamepad_profile(profile)
    if not save_result.ok:
        last_error_message = "Controller profile was not persisted: %s" % save_result.error
        screen = "error"
        _refresh_flight_hud()
        return
    session_gamepad_profile = profile
    session_gamepad_device_id = controller_confirmation_device_id
    controller_confirmation_panel.hide()
    enter_preflight()

func use_keyboard_fallback() -> void:
    session_gamepad_profile = null
    session_gamepad_device_id = -1
    keyboard_fallback_explicitly_selected = false
    if controller_confirmation_panel != null:
        controller_confirmation_panel.hide()
    _show_keyboard_fallback("KeyboardProfile fallback selected (non-sim control)")

func _show_keyboard_fallback(message: String) -> void:
    keyboard_fallback_explicitly_selected = false
    last_error_message = message
    screen = "fallback_prompt"
    _refresh_flight_hud()

func accept_fallback() -> void:
    if screen == "fallback_prompt":
        keyboard_fallback_explicitly_selected = true
        controller_safety_latched = false
        controller_reconnected = false
        disconnected_gamepad_device_id = -1
        enter_preflight()
        return
    last_error_message = "No fallback prompt is active"
    screen = "error"
    _refresh_flight_hud()

func enter_preflight() -> void:
    if not load_map(DEFAULT_FREE_FLIGHT_MAP_ID):
        screen = "error"
        _refresh_flight_hud()
        return
    screen = "preflight"
    exit_requested = false
    flight_mode = "ANGLE"
    takeoff_requested = false
    set_paused(false)
    update_fallback_status()
    _refresh_flight_hud()

func select_map(map_id: String, wind_preset: String) -> void:
    if map_id != DEFAULT_FREE_FLIGHT_MAP_ID or not WIND_PRESETS.has(wind_preset):
        return
    selected_wind_preset = wind_preset
    if environment_state != null:
        _apply_environment_result(environment_state.apply({
            "wind_preset": wind_preset,
            "steady_wind": scene_steady_wind_mps,
        }))
    elif native != null:
        native.call("configure_wind", {
            "preset": wind_preset,
            "steady_wind": scene_steady_wind_mps,
        })

func open_map_menu() -> void:
    if has_node("MapMenu"):
        return
    var layer := CanvasLayer.new()
    layer.name = "MapMenu"
    layer.layer = 20
    add_child(layer)
    var presets := VBoxContainer.new()
    presets.name = "WindPresets"
    layer.add_child(presets)
    for preset in WIND_PRESETS:
        var button := Button.new()
        button.name = preset.capitalize()
        button.text = preset.capitalize()
        button.pressed.connect(select_map.bind(DEFAULT_FREE_FLIGHT_MAP_ID, preset))
        presets.add_child(button)
    var environment_controls := VBoxContainer.new()
    environment_controls.name = "EnvironmentControls"
    environment_controls.position = Vector2(240.0, 0.0)
    layer.add_child(environment_controls)
    _add_environment_slider(environment_controls, "Rain", "rain", 0.0, 1.0, 0.05)
    _add_environment_slider(environment_controls, "Fog", "fog", 0.0, 1.0, 0.05)
    _add_environment_slider(environment_controls, "Time of day", "time_of_day", 0.0, 23.99, 0.25)


func _add_environment_slider(parent: VBoxContainer, label_text: String, key: String, minimum: float, maximum: float, step: float) -> void:
    if environment_state == null:
        return
    var label := Label.new()
    label.text = label_text
    parent.add_child(label)
    var slider := HSlider.new()
    slider.name = label_text.replace(" ", "")
    slider.min_value = minimum
    slider.max_value = maximum
    slider.step = step
    slider.value = float(environment_state.snapshot().get(key, minimum))
    slider.value_changed.connect(_set_environment_scalar.bind(key))
    parent.add_child(slider)


func _set_environment_scalar(value: float, key: String) -> void:
    if environment_state == null:
        return
    var update := {key: value}
    if key == "rain" or key == "fog":
        update["weather_enabled"] = true
    elif key == "time_of_day":
        update["time_of_day_enabled"] = true
        update["move_sun"] = true
    _apply_environment_result(environment_state.apply(update))

func respawn() -> void:
    if controller_safety_latched:
        last_error_message = "Respawn blocked: controller_resume_required"
        _refresh_flight_hud()
        return
    reset_count += 1
    _reset_airsim_flight_state()
    _airsim_disarm_requested = false
    screen = "flight"
    flight_mode = "ANGLE"
    takeoff_requested = true
    set_paused(false)
    if native != null:
        native.call("reset_flight")
        if native.has_method("disarm_flight_control"):
            native.call("disarm_flight_control")
    if px4_sitl_bridge != null:
        px4_sitl_bridge.stop()
        px4_sitl_bridge.start()
        _px4_lockstep_sensor_pending = false
    update_fallback_status()
    if not reset_to_spawn():
        return
    if time_trial != null:
        time_trial.start()
    if drone_body != null:
        # ponytail: short reset hold; replace with real throttle input state when controller profiles land.
        reset_hold_frames = 30
    _refresh_flight_hud()

func retry_time_trial() -> void:
    if loaded_map == null:
        enter_preflight()
        return
    respawn()

func change_map() -> void:
    _reset_airsim_flight_state()
    takeoff_requested = false
    set_paused(false)
    enter_preflight()

func load_map(map_id: String) -> bool:
    var maps := FreeFlightMap.new()
    var descriptor: Dictionary = maps.load_descriptor(map_id)
    if not maps.last_ok:
        return _set_map_error("Cannot load Free Flight map %s: %s" % [map_id, maps.last_error])
    var scene_path := str(MAP_SCENE_PATHS.get(map_id, ""))
    if scene_path.is_empty() or not ResourceLoader.exists(scene_path):
        return _set_map_error("Cannot load Free Flight map %s: scene is unavailable" % map_id)
    var scene := load(scene_path) as PackedScene
    if scene == null:
        return _set_map_error("Cannot load Free Flight map %s: scene failed to load" % map_id)
    var map_root := scene.instantiate() as Node3D
    if map_root == null:
        return _set_map_error("Cannot load Free Flight map %s: scene root must be Node3D" % map_id)
    unload_map()
    map_root.name = "LoadedMap"
    add_child(map_root)
    loaded_map = map_root
    loaded_map_id = map_id
    loaded_map_wind_preset = str(descriptor.wind_preset)
    if native != null:
        var applied_wind_preset := selected_wind_preset if not selected_wind_preset.is_empty() else str(descriptor.wind_preset)
        native.call("configure_wind", {
            "preset": applied_wind_preset,
            "steady_wind": scene_steady_wind_mps,
        })
    _configure_time_trial(map_root)
    return reset_to_spawn()

func reset_to_spawn() -> bool:
    if loaded_map == null:
        return _set_map_error("Cannot reset Free Flight: no map is loaded")
    var spawn := loaded_map.get_node_or_null("SpawnNorth") as Marker3D
    if spawn == null:
        return _set_map_error("Cannot reset Free Flight map %s: SpawnNorth is missing" % loaded_map_id)
    _record_replay_simulation_operation(5, 0.0)
    _airsim_last_velocity = Vector3.ZERO
    _airsim_linear_acceleration = Vector3.ZERO
    _airsim_last_body_angular_velocity = Vector3.ZERO
    _airsim_angular_acceleration = Vector3.ZERO
    if native != null:
        native.call("reset_flight")
    if drone_body != null:
        drone_body.reset_contact()
        drone_body.apply_native_state(spawn.global_position, spawn.global_transform.basis.get_rotation_quaternion(), Vector3.ZERO, Vector3.ZERO)
        drone_body.freeze = true
    if _airsim_secondary_native != null and secondary_drone_body != null:
        _airsim_secondary_native.call("reset_flight")
        secondary_drone_body.reset_contact()
        secondary_drone_body.apply_native_state(spawn.global_position + Vector3(1.0, 0.0, 0.0), spawn.global_transform.basis.get_rotation_quaternion(), Vector3.ZERO, Vector3.ZERO)
        secondary_drone_body.freeze = true
        _set_secondary_collision_enabled(_airsim_vehicle_names.size() > 1 and _airsim_secondary_native != null)
    _reset_secondary_kinematic_contexts()
    if time_trial != null:
        time_trial.reset()
    if scene_object_catalog != null:
        scene_object_catalog.reset()
    if environment_state != null:
        _apply_environment_result(environment_state.reset())
        var baseline_preset := selected_wind_preset if not selected_wind_preset.is_empty() else loaded_map_wind_preset
        _apply_environment_result(environment_state.apply({
            "wind_preset": baseline_preset,
            "steady_wind": scene_steady_wind_mps,
        }))
    return true

func _reset_secondary_kinematic_contexts() -> void:
    for name in _airsim_vehicle_contexts:
        var context: Dictionary = _airsim_vehicle_contexts[name]
        context["last_velocity"] = Vector3.ZERO
        context["linear_acceleration"] = Vector3.ZERO
        context["last_body_angular_velocity"] = Vector3.ZERO
        context["angular_acceleration"] = Vector3.ZERO
        _airsim_vehicle_contexts[name] = context

func _spawn_position() -> Vector3:
    if loaded_map != null:
        var spawn := loaded_map.get_node_or_null("SpawnNorth") as Marker3D
        if spawn != null:
            return spawn.global_position
    return SPAWN_POSITION

func unload_map() -> void:
    if scene_object_catalog != null:
        scene_object_catalog.reset()
    if loaded_map != null:
        remove_child(loaded_map)
        loaded_map.queue_free()
        loaded_map = null
    loaded_map_id = ""
    loaded_map_wind_preset = "calm"
    time_trial = null


func _load_scene_object_catalog() -> void:
    if scene_object_catalog == null:
        return
    var file := FileAccess.open("res://config/scene_object_catalog.json", FileAccess.READ)
    if file == null:
        push_error("Scene object catalog could not be opened")
        return
    var parsed = JSON.parse_string(file.get_as_text())
    file.close()
    if typeof(parsed) != TYPE_DICTIONARY:
        push_error("Scene object catalog must contain a JSON object")
        return
    var result: Dictionary = scene_object_catalog.load_from_dictionary(parsed)
    _airsim_environment_catalog_loaded = bool(result.ok)
    if not result.ok:
        push_error("Scene object catalog is invalid: %s" % result.error)


func _airsim_scene_object(method: String, params: Array) -> Dictionary:
    if not _airsim_environment_catalog_loaded or scene_object_catalog == null:
        return {"ok": false, "error": "scene object catalog is unavailable"}
    match method:
        "simListSceneObjects":
            if String(params[0]) != ".*":
                return {"ok": false, "error": "scene object regex filters are unsupported; use the default .* query"}
            return {"ok": true, "value": scene_object_catalog.list_named()}
        "simSpawnObject":
            if not bool(params[4]):
                return {"ok": false, "error": "physics_enabled=false is unsupported for catalog collision objects"}
            if params.size() == 6 and bool(params[5]):
                return {"ok": false, "error": "blueprint spawning is unsupported; use a catalog asset ID"}
            var pose_result: Dictionary = _parse_airsim_pose(params[2])
            if not pose_result.ok:
                return pose_result
            if not _unit_scale(params[3]):
                return {"ok": false, "error": "catalog objects only support unit scale"}
            var created: Dictionary = scene_object_catalog.create_named(
                String(params[0]), String(params[1]), pose_result.godot_position, pose_result.godot_orientation)
            if not created.ok:
                return created
            _record_replay_scene_object(0, created.object)
            return {"ok": true, "value": String(created.object.name)}
        "simGetObjectPose":
            var queried: Dictionary = scene_object_catalog.query_named(String(params[0]))
            if not queried.ok:
                return queried
            return {"ok": true, "value": _airsim_pose(queried.object.position, queried.object.orientation)}
        "simSetObjectPose":
            if not bool(params[2]):
                return {"ok": false, "error": "teleport=false sweep movement is unsupported for catalog collision objects"}
            var set_pose: Dictionary = _parse_airsim_pose(params[1])
            if not set_pose.ok:
                return set_pose
            var moved: Dictionary = scene_object_catalog.move_named(String(params[0]), set_pose.godot_position, set_pose.godot_orientation)
            if not moved.ok:
                return moved
            _record_replay_scene_object(1, moved.object)
            return {"ok": true, "value": true}
        "simDestroyObject":
            var destroy_snapshot: Dictionary = scene_object_catalog.query_named(String(params[0]))
            if not destroy_snapshot.ok:
                return destroy_snapshot
            var destroyed: Dictionary = scene_object_catalog.destroy_named(String(params[0]))
            if not destroyed.ok:
                return destroyed
            _record_replay_scene_object(2, destroy_snapshot.object)
            return {"ok": true, "value": true}
        "simGetSegmentationObjectID":
            var segmentation_query: Dictionary = scene_object_catalog.query_named(String(params[0]))
            if not segmentation_query.ok:
                return segmentation_query
            return {"ok": true, "value": int(segmentation_query.object.segmentation_id)}
        "simSetSegmentationObjectID":
            if bool(params[2]):
                return {"ok": false, "error": "segmentation regex matching is unsupported; use an exact catalog object name"}
            var segmentation_set: Dictionary = scene_object_catalog.query_named(String(params[0]))
            if not segmentation_set.ok:
                return segmentation_set
            if int(params[1]) != int(segmentation_set.object.segmentation_id):
                return {"ok": false, "error": "catalog segmentation IDs are immutable"}
            return {"ok": true, "value": true}
    return {"ok": false, "error": "unsupported scene object method: %s" % method}


func _airsim_environment(method: String, params: Array) -> Dictionary:
    if environment_state == null:
        return {"ok": false, "error": "environment state is unavailable"}
    match method:
        "simEnableWeather":
            var weather_result: Dictionary = environment_state.apply({"weather_enabled": bool(params[0])})
            return _apply_environment_result(weather_result)
        "simSetWeatherParameter":
            var weather_key := "rain" if int(params[0]) == 0 else "fog"
            var parameter_result: Dictionary = environment_state.apply({weather_key: float(params[1]), "weather_enabled": true})
            return _apply_environment_result(parameter_result)
        "simSetTimeOfDay":
            var time_result: Dictionary = environment_state.apply({
                "time_of_day_enabled": bool(params[0]),
                "start_datetime": String(params[1]),
                "is_start_datetime_dst": bool(params[2]),
                "celestial_clock_speed": float(params[3]),
                "update_interval_secs": float(params[4]),
                "move_sun": bool(params[5]),
            })
            return _apply_environment_result(time_result)
        "simSetEnvironment":
            var normalized: Dictionary = _normalize_environment_payload(params[0])
            if not normalized.ok:
                return normalized
            return _apply_environment_result(environment_state.apply(normalized.state))
        "simGetEnvironment":
            return {"ok": true, "value": _environment_rpc_snapshot(environment_state.snapshot())}
    return {"ok": false, "error": "unsupported environment method: %s" % method}


func _apply_environment_result(result: Dictionary) -> Dictionary:
    if not result.ok:
        return result
    if native != null:
        native.call("configure_wind", {
            "preset": String(result.state.wind_preset),
            "steady_wind": result.state.steady_wind,
        })
    _apply_environment_visuals(result.state)
    _record_replay_environment(_environment_rpc_snapshot(result.state))
    return {"ok": true, "value": _environment_rpc_snapshot(result.state)}


func _apply_environment_visuals(state: Dictionary) -> void:
    if loaded_map == null:
        return
    var world_environment := loaded_map.get_node_or_null("AeroSimEnvironment") as WorldEnvironment
    if world_environment == null:
        world_environment = WorldEnvironment.new()
        world_environment.name = "AeroSimEnvironment"
        loaded_map.add_child(world_environment)
    if world_environment.environment == null:
        world_environment.environment = Environment.new()
    var visual_environment: Environment = world_environment.environment
    visual_environment.fog_enabled = bool(state.get("weather_enabled", false)) and float(state.get("fog", 0.0)) > 0.0
    visual_environment.fog_density = float(state.get("fog", 0.0)) * 0.05
    if bool(state.get("time_of_day_enabled", false)) and bool(state.get("move_sun", true)):
        var sun := loaded_map.get_node_or_null("Sun") as DirectionalLight3D
        var sun_direction: Vector3 = state.get("sun_position", Vector3(0.0, 1.0, 0.0))
        if sun != null and sun_direction.length_squared() > 0.0:
            sun.rotation = Vector3(-asin(clampf(sun_direction.y, -1.0, 1.0)), atan2(sun_direction.x, sun_direction.z), 0.0)


func _normalize_environment_payload(raw: Dictionary) -> Dictionary:
    var state := raw.duplicate(true)
    for key in ["steady_wind", "sun_position"]:
        if state.has(key):
            var vector_result: Dictionary = _parse_vector3r(state[key])
            if not vector_result.ok:
                return vector_result
            state[key] = vector_result.value
    return {"ok": true, "state": state}


func _parse_airsim_pose(raw_pose: Dictionary) -> Dictionary:
    if not raw_pose.has("position") or not raw_pose.has("orientation"):
        return {"ok": false, "error": "pose requires position and orientation"}
    var position_result: Dictionary = _parse_vector3r(raw_pose.position)
    if not position_result.ok:
        return position_result
    var orientation = raw_pose.orientation
    if typeof(orientation) != TYPE_DICTIONARY:
        return {"ok": false, "error": "pose orientation must be a quaternion object"}
    for key in ["w_val", "x_val", "y_val", "z_val"]:
        if not orientation.has(key) or (typeof(orientation[key]) != TYPE_FLOAT and typeof(orientation[key]) != TYPE_INT) or not is_finite(float(orientation[key])):
            return {"ok": false, "error": "pose orientation contains an invalid quaternion"}
    var quaternion := Quaternion(float(orientation.x_val), float(orientation.y_val), float(orientation.z_val), float(orientation.w_val))
    if quaternion.length_squared() <= 0.0:
        return {"ok": false, "error": "pose orientation cannot be zero"}
    return {
        "ok": true,
        "godot_position": AirSimCoordinateContract.ned_to_godot_world(position_result.value),
        "godot_orientation": AirSimCoordinateContract.ned_orientation_to_godot(quaternion),
    }


func _parse_vector3r(raw_vector) -> Dictionary:
    if typeof(raw_vector) != TYPE_DICTIONARY:
        return {"ok": false, "error": "Vector3r must be an object"}
    for key in ["x_val", "y_val", "z_val"]:
        if not raw_vector.has(key) or (typeof(raw_vector[key]) != TYPE_FLOAT and typeof(raw_vector[key]) != TYPE_INT) or not is_finite(float(raw_vector[key])):
            return {"ok": false, "error": "Vector3r contains an invalid component"}
    return {"ok": true, "value": Vector3(float(raw_vector.x_val), float(raw_vector.y_val), float(raw_vector.z_val))}


func _airsim_pose(godot_position: Vector3, godot_orientation: Quaternion = Quaternion(0.0, 0.0, 0.0, 1.0)) -> Dictionary:
    var position := AirSimCoordinateContract.godot_world_to_ned(godot_position)
    var orientation := AirSimCoordinateContract.godot_orientation_to_ned(godot_orientation)
    return {
        "position": {"x_val": position.x, "y_val": position.y, "z_val": position.z},
        "orientation": {"w_val": orientation.w, "x_val": orientation.x, "y_val": orientation.y, "z_val": orientation.z},
    }


func _environment_rpc_snapshot(state: Dictionary) -> Dictionary:
    var result := state.duplicate(true)
    for key in ["steady_wind", "sun_position"]:
        var value: Vector3 = result[key]
        result[key] = {"x_val": value.x, "y_val": value.y, "z_val": value.z}
    return result


func _unit_scale(raw_scale: Dictionary) -> bool:
    var parsed: Dictionary = _parse_vector3r(raw_scale)
    return parsed.ok and parsed.value.is_equal_approx(Vector3.ONE)

func _configure_time_trial(map_root: Node3D) -> void:
    var route := map_root.get_node_or_null("TimeTrial") as Node3D
    var finish := route.get_node_or_null("Finish") as Marker3D if route != null else null
    if route == null or finish == null:
        time_trial = null
        return
    var checkpoints: Array[Vector3] = []
    for child in route.get_children():
        if child is Marker3D and child.name.begins_with("Checkpoint"):
            checkpoints.append((child as Marker3D).global_position)
    time_trial = TimeTrialController.new()
    time_trial.configure(checkpoints, finish.global_position, 2.5)
    time_trial.checkpoint_reached.connect(_on_trial_checkpoint_reached)
    time_trial.trial_finished.connect(_on_trial_finished)

func _on_trial_checkpoint_reached(_index: int, _total: int) -> void:
    _refresh_flight_hud()

func _on_trial_finished(elapsed_seconds: float) -> void:
    _reset_airsim_flight_state()
    takeoff_requested = false
    set_paused(true)
    screen = "finish"
    if finish_summary_label != null:
        finish_summary_label.text = "FINISH\nTime %0.2f s" % elapsed_seconds
    _refresh_flight_hud()

func _set_map_error(message: String) -> bool:
    last_error_message = message
    push_warning(message)
    return false

func _reset_airsim_flight_state() -> void:
    _airsim_api_control = false
    _airsim_disarm_requested = true
    _airsim_command_state.clear()
    _airsim_hold_controls.clear()
    _airsim_command_remaining_frames = 0
    _airsim_collision_seen = false
    _airsim_contact_this_frame = false
    _airsim_collision_normal = Vector3.ZERO
    _airsim_collision_point = Vector3.ZERO
    _airsim_last_velocity = Vector3.ZERO
    _airsim_last_body_angular_velocity = Vector3.ZERO
    _airsim_linear_acceleration = Vector3.ZERO
    _airsim_angular_acceleration = Vector3.ZERO
    if airsim_rpc_server != null:
        airsim_rpc_server.reset_vehicle_control_state()
    if px4_sitl_bridge != null:
        px4_sitl_bridge.arm_disarm(false)
        px4_sitl_bridge.stop()
        _px4_lockstep_sensor_pending = false
    if native != null and native.has_method("disarm_flight_control"):
        native.call("disarm_flight_control")
    if _airsim_secondary_native != null and _airsim_secondary_native.has_method("disarm_flight_control"):
        _airsim_secondary_native.call("disarm_flight_control")
    _reset_secondary_kinematic_contexts()
    for name in _airsim_vehicle_contexts:
        var context: Dictionary = _airsim_vehicle_contexts[name]
        context["api_control"] = false
        context["armed"] = false
        context["disarm_requested"] = true
        context["command_state"] = {}
        context["hold_controls"] = {}
        context["command_remaining_frames"] = 0
        context["collision_seen"] = false
        context["contact_this_frame"] = false
        context["collision_normal"] = Vector3.ZERO
        context["collision_point"] = Vector3.ZERO
        _airsim_vehicle_contexts[name] = context
    if airsim_sensor_suite != null and airsim_rpc_server != null:
        airsim_sensor_suite.configure(airsim_rpc_server.settings, _airsim_vehicle_names if not _airsim_vehicle_names.is_empty() else [_airsim_vehicle_name])

func update_fallback_status() -> void:
    last_profile_status = InputProfiles.fallback_status(gamepad_device_state.connected_joypads())
    if fallback_status_label != null:
        fallback_status_label.text = "%s | Mode: %s" % [last_profile_status, flight_mode]

func toggle_altitude_hold() -> void:
    if native == null or not takeoff_requested:
        return
    if flight_mode == "ALTITUDE_HOLD":
        flight_mode = "ANGLE"
    else:
        native.call("capture_altitude_hold")
        flight_mode = "ALTITUDE_HOLD"
    update_fallback_status()


func toggle_acro_mode() -> void:
    if native == null or not takeoff_requested or screen != "flight" or paused:
        return
    flight_mode = "ANGLE" if flight_mode == "ACRO" else "ACRO"
    update_fallback_status()
    _refresh_flight_hud()


func _acro_rate(key: String) -> float:
    return float(rates_profile.get(key, RatesProfile.default_profile().get(key, 0.0)))

func set_paused(value: bool, sync_session: bool = true) -> void:
    if not value and _airsim_lifecycle_stopped() and (airsim_session == null or not airsim_session.is_explicit_step_active()):
        return
    if paused != value and sync_session and _replay_recording_active and native != null:
        var replay_pause_result: Dictionary = native.call(
            "record_replay_simulation_operation", _replay_timestamp_us(), 0 if value else 1, 0.0)
        if not bool(replay_pause_result.get("ok", false)):
            push_error("Complete replay pause recording failed: %s" % String(replay_pause_result.get("diagnostic_message", "unknown error")))
    paused = value
    if sync_session and airsim_session != null:
        airsim_session.set_paused(value)
    if drone_body != null:
        drone_body.freeze = value
        drone_body.sleeping = value
    if secondary_drone_body != null:
        secondary_drone_body.freeze = value
        secondary_drone_body.sleeping = value

func _build_main_menu() -> void:
    var layer := CanvasLayer.new()
    layer.name = "MainMenu"
    main_menu_layer = layer
    add_child(layer)

    var entries := VBoxContainer.new()
    entries.name = "Entries"
    main_menu_entries_container = entries
    layer.add_child(entries)

    for entry in main_menu_entries:
        var button := Button.new()
        button.name = entry.replace(" ", "")
        button.text = entry
        entries.add_child(button)
        if entry == "Quick Fly":
            button.pressed.connect(quick_fly)
        elif entry == "Map":
            button.pressed.connect(open_map_menu)
        elif entry == "Controller":
            button.pressed.connect(begin_controller_confirmation)
        elif entry == "Settings":
            button.pressed.connect(show_settings)
    _build_settings_panel()
    _build_controller_settings_panel()
    _build_rates_panel()

func _build_settings_panel() -> void:
    var panel := PanelContainer.new()
    panel.name = "SettingsPanel"
    panel.set_anchors_preset(Control.PRESET_TOP_LEFT)
    panel.offset_left = 20.0
    panel.offset_top = 20.0
    panel.offset_right = 360.0
    panel.offset_bottom = 280.0
    settings_panel = panel
    main_menu_layer.add_child(panel)

    var rows := VBoxContainer.new()
    rows.name = "Rows"
    rows.add_theme_constant_override("separation", 6)
    panel.add_child(rows)

    var title := Label.new()
    title.text = "SETTINGS"
    rows.add_child(title)

    var controller_button := Button.new()
    controller_button.name = "Controller"
    controller_button.text = "CONTROLLER"
    controller_button.pressed.connect(show_controller_settings)
    rows.add_child(controller_button)

    var rates_button := Button.new()
    rates_button.name = "Rates"
    rates_button.text = "RATES"
    rates_button.pressed.connect(show_rates)
    rows.add_child(rates_button)

    var factory_reset_button := Button.new()
    factory_reset_button.name = "FactoryReset"
    factory_reset_button.text = "FACTORY RESET SETTINGS"
    factory_reset_button.pressed.connect(factory_reset_player_settings)
    rows.add_child(factory_reset_button)

    settings_status_label = Label.new()
    settings_status_label.name = "Status"
    settings_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    rows.add_child(settings_status_label)

    var back_button := Button.new()
    back_button.name = "Back"
    back_button.text = "BACK"
    back_button.pressed.connect(show_main_menu)
    rows.add_child(back_button)


func _build_rates_panel() -> void:
    var panel := PanelContainer.new()
    panel.name = "RatesPanel"
    panel.set_anchors_preset(Control.PRESET_TOP_LEFT)
    panel.offset_left = 20.0
    panel.offset_top = 20.0
    panel.offset_right = 760.0
    panel.offset_bottom = 700.0
    rates_panel = panel
    main_menu_layer.add_child(panel)

    var scroll := ScrollContainer.new()
    scroll.name = "Scroll"
    panel.add_child(scroll)
    var rows := VBoxContainer.new()
    rows.name = "Rows"
    rows.custom_minimum_size = Vector2(690.0, 0.0)
    rows.add_theme_constant_override("separation", 6)
    scroll.add_child(rows)

    var title := Label.new()
    title.text = "BETAFLIGHT RATES"
    rows.add_child(title)
    var disclaimer := Label.new()
    disclaimer.text = "SIM PROFILE: RC Rate / Super Rate / Expo affect ACRO mode only."
    disclaimer.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    rows.add_child(disclaimer)

    for setting in [
        {"key": "rc_rate", "title": "RC RATE", "max": 3.0},
        {"key": "super_rate", "title": "SUPER RATE", "max": 1.0},
        {"key": "expo", "title": "EXPO", "max": 1.0},
    ]:
        var key: String = setting.key
        var value_label := Label.new()
        value_label.name = "%sValue" % key.capitalize()
        rows.add_child(value_label)
        rates_slider_labels[key] = value_label
        var slider := HSlider.new()
        slider.name = "%sSlider" % key.capitalize()
        slider.min_value = 0.0
        slider.max_value = float(setting.max)
        slider.step = 0.01
        slider.value = _acro_rate(key)
        slider.value_changed.connect(_on_rates_slider_changed.bind(key))
        rows.add_child(slider)
        rates_sliders[key] = slider

    var curve_title := Label.new()
    curve_title.text = "RATE CURVE PREVIEW (degrees/second)"
    rows.add_child(curve_title)
    rates_curve_plot = Control.new()
    rates_curve_plot.name = "CurvePreview"
    rates_curve_plot.custom_minimum_size = Vector2(680.0, 170.0)
    rows.add_child(rates_curve_plot)
    var horizontal_axis := ColorRect.new()
    horizontal_axis.position = Vector2(10.0, 84.0)
    horizontal_axis.size = Vector2(660.0, 1.0)
    horizontal_axis.color = Color(0.35, 0.35, 0.35)
    rates_curve_plot.add_child(horizontal_axis)
    var vertical_axis := ColorRect.new()
    vertical_axis.position = Vector2(340.0, 10.0)
    vertical_axis.size = Vector2(1.0, 150.0)
    vertical_axis.color = Color(0.35, 0.35, 0.35)
    rates_curve_plot.add_child(vertical_axis)
    rates_curve_line = Line2D.new()
    rates_curve_line.name = "Curve"
    rates_curve_line.width = 2.0
    rates_curve_line.default_color = Color(0.2, 0.85, 0.95)
    rates_curve_plot.add_child(rates_curve_line)

    var json_title := Label.new()
    json_title.text = "JSON EXPORT / IMPORT"
    rows.add_child(json_title)
    rates_json_editor = TextEdit.new()
    rates_json_editor.name = "RatesJson"
    rates_json_editor.custom_minimum_size = Vector2(660.0, 110.0)
    rates_json_editor.text = RatesProfile.to_json(rates_profile)
    rates_json_editor.text_changed.connect(_on_rates_json_changed)
    rows.add_child(rates_json_editor)

    rates_diff_label = Label.new()
    rates_diff_label.name = "Diff"
    rates_diff_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    rows.add_child(rates_diff_label)
    rates_status_label = Label.new()
    rates_status_label.name = "Status"
    rates_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    rows.add_child(rates_status_label)

    var actions := HBoxContainer.new()
    actions.name = "Actions"
    rows.add_child(actions)
    var export_button := Button.new()
    export_button.name = "ExportJson"
    export_button.text = "EXPORT JSON"
    export_button.pressed.connect(_export_rates_json)
    actions.add_child(export_button)
    var import_button := Button.new()
    import_button.name = "ImportJson"
    import_button.text = "IMPORT & APPLY JSON"
    import_button.pressed.connect(_import_rates_json)
    actions.add_child(import_button)
    var reset_button := Button.new()
    reset_button.name = "ResetDefaults"
    reset_button.text = "RESET DEFAULTS"
    reset_button.pressed.connect(_reset_rates_defaults)
    actions.add_child(reset_button)
    var back_button := Button.new()
    back_button.name = "Back"
    back_button.text = "BACK"
    back_button.pressed.connect(_close_rates_panel)
    actions.add_child(back_button)


func _on_rates_slider_changed(value: float, key: String) -> void:
    var candidate: Dictionary = rates_profile.duplicate(true)
    candidate[key] = value
    var result: Dictionary = _save_rates_profile(candidate)
    if not result.ok:
        rates_status_label.text = "Rates save failed: %s" % result.error
        return
    rates_status_label.text = "Saved rates profile"
    if rates_json_editor != null:
        rates_json_editor.text = RatesProfile.to_json(rates_profile)
    _refresh_rates_panel()


func _export_rates_json() -> void:
    if rates_json_editor != null:
        rates_json_editor.text = RatesProfile.to_json(rates_profile)
    rates_status_label.text = "Exported current rates JSON to the editor"
    _refresh_rates_import_diff()


func _import_rates_json() -> void:
    if rates_json_editor == null:
        return
    var result: Dictionary = RatesProfile.from_json(rates_json_editor.text)
    if not result.ok:
        rates_status_label.text = "Import rejected: %s" % result.error
        _refresh_rates_import_diff()
        return
    var save_result: Dictionary = _save_rates_profile(result.profile)
    if not save_result.ok:
        rates_status_label.text = "Import save failed: %s" % save_result.error
        return
    rates_json_editor.text = RatesProfile.to_json(rates_profile)
    rates_status_label.text = "Imported and applied rates profile"
    _refresh_rates_import_diff()


func _reset_rates_defaults() -> void:
    var result: Dictionary = _save_rates_profile(RatesProfile.default_profile())
    if not result.ok:
        rates_status_label.text = "Rates reset failed: %s" % result.error
        return
    rates_json_editor.text = RatesProfile.to_json(rates_profile)
    rates_status_label.text = "Rates reset to defaults"
    _refresh_rates_import_diff()


func _on_rates_json_changed() -> void:
    _refresh_rates_import_diff()


func _refresh_rates_import_diff() -> void:
    if rates_json_editor == null or rates_diff_label == null:
        return
    var result: Dictionary = RatesProfile.from_json(rates_json_editor.text)
    if not result.ok:
        rates_diff_label.text = "BETAFLIGHT DIFF: invalid JSON (%s)" % result.error
        return
    var changes: Array[Dictionary] = RatesProfile.diff(rates_profile, result.profile)
    if changes.is_empty():
        rates_diff_label.text = "CURRENT vs BETAFLIGHT IMPORTED: no changes"
        return
    var lines := ["CURRENT vs BETAFLIGHT IMPORTED:"]
    for change in changes:
        lines.append("%s: %.2f -> %.2f" % [change.key, change.current, change.imported])
    rates_diff_label.text = "\n".join(lines)


func _refresh_rates_panel() -> void:
    if rates_panel == null:
        return
    for key in rates_sliders:
        var slider: HSlider = rates_sliders[key]
        var value := _acro_rate(key)
        if not is_equal_approx(slider.value, value):
            slider.set_value_no_signal(value)
        var label: Label = rates_slider_labels[key]
        label.text = "%s: %.2f" % [key.to_upper(), value]
    if rates_curve_line != null:
        _refresh_rates_curve()
    _refresh_rates_import_diff()


func _refresh_rates_curve() -> void:
    if native == null or not native.has_method("betaflight_rate_for_stick"):
        rates_curve_line.points = PackedVector2Array()
        return
    var rates := PackedFloat64Array()
    var maximum := 1000.0
    for index in range(17):
        var stick := -1.0 + float(index) / 8.0
        var rate := float(native.call("betaflight_rate_for_stick", stick, _acro_rate("rc_rate"), _acro_rate("super_rate"), _acro_rate("expo")))
        rates.append(rate)
        maximum = maxf(maximum, absf(rate))
    var points := PackedVector2Array()
    for index in range(rates.size()):
        var x := 10.0 + float(index) * 660.0 / 16.0
        var y := 84.0 - float(rates[index]) / maximum * 70.0
        points.append(Vector2(x, y))
    rates_curve_line.points = points

func _build_controller_settings_panel() -> void:
    var panel := PanelContainer.new()
    panel.name = "ControllerSettingsPanel"
    panel.set_anchors_preset(Control.PRESET_TOP_LEFT)
    panel.offset_left = 20.0
    panel.offset_top = 20.0
    panel.offset_right = 460.0
    panel.offset_bottom = 360.0
    controller_settings_panel = panel
    main_menu_layer.add_child(panel)

    var rows := VBoxContainer.new()
    rows.name = "Rows"
    rows.add_theme_constant_override("separation", 6)
    panel.add_child(rows)

    var title := Label.new()
    title.text = "CONTROLLER"
    rows.add_child(title)

    controller_settings_device_label = Label.new()
    controller_settings_device_label.name = "CurrentDevice"
    rows.add_child(controller_settings_device_label)

    controller_settings_mapping_label = Label.new()
    controller_settings_mapping_label.name = "FixedMapping"
    rows.add_child(controller_settings_mapping_label)

    controller_settings_deadzone_label = Label.new()
    controller_settings_deadzone_label.name = "Deadzone"
    rows.add_child(controller_settings_deadzone_label)

    controller_settings_button_status_label = Label.new()
    controller_settings_button_status_label.name = "ButtonStatus"
    rows.add_child(controller_settings_button_status_label)

    var reset_button := Button.new()
    reset_button.name = "ResetXboxDefault"
    reset_button.text = "RESET TO XBOX DEFAULT"
    reset_button.pressed.connect(reset_to_xbox_default)
    rows.add_child(reset_button)

    var back_button := Button.new()
    back_button.name = "Back"
    back_button.text = "BACK"
    back_button.pressed.connect(show_settings)
    rows.add_child(back_button)

func show_main_menu() -> void:
    screen = "main_menu"
    _refresh_flight_hud()

func show_settings() -> void:
    screen = "settings"
    _refresh_flight_hud()

func show_controller_settings() -> void:
    screen = "controller_settings"
    _refresh_controller_settings()
    _refresh_flight_hud()


func show_rates(return_screen: String = "settings") -> void:
    rates_return_screen = return_screen
    screen = "rates"
    if rates_json_editor != null:
        rates_json_editor.text = RatesProfile.to_json(rates_profile)
    _refresh_rates_import_diff()
    _refresh_flight_hud()


func _close_rates_panel() -> void:
    if rates_return_screen == "flight":
        screen = "flight"
        _refresh_flight_hud()
    else:
        show_settings()

func reset_to_xbox_default() -> void:
    begin_controller_confirmation(_first_connected_device())


func factory_reset_player_settings() -> void:
    var result: Dictionary = settings_store.factory_reset()
    if not result.ok:
        last_error_message = "Settings factory reset failed: %s" % result.error
        screen = "error"
        _refresh_flight_hud()
        return
    persisted_gamepad_profile = null
    rates_profile = RatesProfile.default_profile()
    if rates_json_editor != null:
        rates_json_editor.text = RatesProfile.to_json(rates_profile)
    last_error_message = "Settings reset to factory defaults"
    screen = "settings"
    _refresh_flight_hud()

func _build_controller_confirmation() -> void:
    var panel := PanelContainer.new()
    panel.name = "ControllerConfirmation"
    panel.set_anchors_preset(Control.PRESET_TOP_LEFT)
    panel.offset_left = 380.0
    panel.offset_top = 20.0
    panel.offset_right = 780.0
    panel.offset_bottom = 310.0
    controller_confirmation_panel = panel
    flight_hud_layer.add_child(panel)

    var rows := VBoxContainer.new()
    rows.name = "Rows"
    rows.add_theme_constant_override("separation", 6)
    panel.add_child(rows)

    var title := Label.new()
    title.name = "Title"
    title.text = "CONFIRM XBOX DEFAULT PROFILE"
    rows.add_child(title)

    confirmation_mapping_label = Label.new()
    confirmation_mapping_label.name = "FixedMapping"
    rows.add_child(confirmation_mapping_label)

    confirmation_axes_label = Label.new()
    confirmation_axes_label.name = "LiveAxes"
    rows.add_child(confirmation_axes_label)

    var confirm_button := Button.new()
    confirm_button.name = "UseXboxDefaultProfile"
    confirm_button.text = "USE XBOX DEFAULT PROFILE"
    confirm_button.pressed.connect(accept_controller_confirmation)
    rows.add_child(confirm_button)

    var fallback_button := Button.new()
    fallback_button.name = "UseKeyboardFallback"
    fallback_button.text = "USE KEYBOARD FALLBACK"
    fallback_button.pressed.connect(use_keyboard_fallback)
    rows.add_child(fallback_button)

func _build_flight_hud() -> void:
    var layer := CanvasLayer.new()
    layer.name = "FlightHud"
    layer.layer = 30
    flight_hud_layer = layer
    add_child(layer)

    var margin := MarginContainer.new()
    margin.name = "StatusMargin"
    margin.set_anchors_preset(Control.PRESET_TOP_LEFT)
    margin.offset_right = 360.0
    margin.offset_bottom = 128.0
    margin.add_theme_constant_override("margin_left", 10)
    margin.add_theme_constant_override("margin_top", 10)
    margin.add_theme_constant_override("margin_right", 10)
    margin.add_theme_constant_override("margin_bottom", 10)
    layer.add_child(margin)

    var panel := PanelContainer.new()
    panel.name = "StatusPanel"
    margin.add_child(panel)

    var rows := VBoxContainer.new()
    rows.name = "StatusRows"
    rows.add_theme_constant_override("separation", 4)
    panel.add_child(rows)

    key_hints_label = Label.new()
    key_hints_label.name = "KeyHints"
    key_hints_label.text = KEY_HINTS_TEXT
    rows.add_child(key_hints_label)

    arm_status_label = Label.new()
    arm_status_label.name = "ArmStatus"
    rows.add_child(arm_status_label)

    time_trial_status_label = Label.new()
    time_trial_status_label.name = "TimeTrialStatus"
    rows.add_child(time_trial_status_label)

    arm_takeoff_button = Button.new()
    arm_takeoff_button.name = "ArmTakeoff"
    arm_takeoff_button.pressed.connect(_handle_primary_action)
    rows.add_child(arm_takeoff_button)
    acro_mode_button = Button.new()
    acro_mode_button.name = "AcroMode"
    acro_mode_button.pressed.connect(toggle_acro_mode)
    rows.add_child(acro_mode_button)
    _build_pause_panel()
    _build_controller_safety_panel()
    _build_finish_panel()

func _build_pause_panel() -> void:
    var panel := PanelContainer.new()
    panel.name = "PausePanel"
    panel.set_anchors_preset(Control.PRESET_CENTER)
    panel.offset_left = -170.0
    panel.offset_top = -120.0
    panel.offset_right = 170.0
    panel.offset_bottom = 120.0
    pause_panel = panel
    flight_hud_layer.add_child(panel)

    var rows := VBoxContainer.new()
    rows.name = "Rows"
    rows.add_theme_constant_override("separation", 6)
    panel.add_child(rows)
    var title := Label.new()
    title.text = "PAUSED"
    rows.add_child(title)
    var resume := Button.new()
    resume.name = "Resume"
    resume.text = "RESUME"
    resume.pressed.connect(func() -> void: set_paused(false))
    rows.add_child(resume)
    var retry := Button.new()
    retry.name = "Retry"
    retry.text = "RETRY"
    retry.pressed.connect(retry_time_trial)
    rows.add_child(retry)
    var change := Button.new()
    change.name = "ChangeMap"
    change.text = "CHANGE MAP"
    change.pressed.connect(change_map)
    rows.add_child(change)
    var rates := Button.new()
    rates.name = "Rates"
    rates.text = "RATES"
    rates.pressed.connect(show_rates.bind("flight"))
    rows.add_child(rates)
    var exit := Button.new()
    exit.name = "Exit"
    exit.text = "EXIT"
    exit.pressed.connect(request_exit)
    rows.add_child(exit)


func _build_controller_safety_panel() -> void:
    var panel := PanelContainer.new()
    panel.name = "ControllerSafetyPanel"
    panel.set_anchors_preset(Control.PRESET_CENTER)
    panel.offset_left = -220.0
    panel.offset_top = -80.0
    panel.offset_right = 220.0
    panel.offset_bottom = 80.0
    controller_safety_panel = panel
    flight_hud_layer.add_child(panel)

    var rows := VBoxContainer.new()
    rows.name = "Rows"
    rows.add_theme_constant_override("separation", 6)
    panel.add_child(rows)
    controller_safety_label = Label.new()
    controller_safety_label.name = "Message"
    rows.add_child(controller_safety_label)

func _build_finish_panel() -> void:
    var panel := PanelContainer.new()
    panel.name = "FinishPanel"
    panel.set_anchors_preset(Control.PRESET_CENTER)
    panel.offset_left = -170.0
    panel.offset_top = -120.0
    panel.offset_right = 170.0
    panel.offset_bottom = 120.0
    finish_panel = panel
    flight_hud_layer.add_child(panel)

    var rows := VBoxContainer.new()
    rows.name = "Rows"
    rows.add_theme_constant_override("separation", 6)
    panel.add_child(rows)
    finish_summary_label = Label.new()
    finish_summary_label.name = "Summary"
    finish_summary_label.text = "FINISH"
    rows.add_child(finish_summary_label)
    var retry := Button.new()
    retry.name = "Retry"
    retry.text = "RETRY"
    retry.pressed.connect(retry_time_trial)
    rows.add_child(retry)
    var change := Button.new()
    change.name = "ChangeMap"
    change.text = "CHANGE MAP"
    change.pressed.connect(change_map)
    rows.add_child(change)
    var exit := Button.new()
    exit.name = "Exit"
    exit.text = "EXIT"
    exit.pressed.connect(request_exit)
    rows.add_child(exit)

func _build_status_diagram() -> void:
    status_diagram = StatusDiagramDebug.new()
    status_diagram.connect("vehicle_selected", Callable(self, "_on_dashboard_vehicle_selected"))
    add_child(status_diagram)
    status_diagram.call("set_layout_mode", dashboard_layout_mode)


func set_dashboard_layout_mode(mode: String) -> bool:
    if mode not in ["compact", "full"]:
        return false
    dashboard_layout_mode = mode
    if status_diagram != null:
        status_diagram.call("set_layout_mode", mode)
    return true


func _on_dashboard_vehicle_selected(vehicle_name: String) -> void:
    if _airsim_name_matches(vehicle_name):
        _dashboard_vehicle_name = vehicle_name

func _update_status_diagram() -> void:
    if status_diagram == null or native == null or not native.has_method("telemetry_snapshot"):
        return
    var snapshots: Dictionary = {}
    var primary_snapshot: Dictionary = native.call("telemetry_snapshot")
    primary_snapshot["vehicle_name"] = _airsim_vehicle_name
    snapshots[_airsim_vehicle_name] = primary_snapshot
    for vehicle_name_variant in _airsim_vehicle_names:
        var vehicle_name := String(vehicle_name_variant)
        if vehicle_name == _airsim_vehicle_name:
            continue
        if _airsim_secondary_native != null and _airsim_secondary_native.has_method("telemetry_snapshot"):
            var secondary_snapshot: Dictionary = _airsim_secondary_native.call("telemetry_snapshot")
            secondary_snapshot["vehicle_name"] = vehicle_name
            snapshots[vehicle_name] = secondary_snapshot
        else:
            snapshots[vehicle_name] = {
                "vehicle_name": vehicle_name,
                "connection_state": "disconnected",
            }
    var now_timestamp_us := Time.get_ticks_usec()
    status_diagram.call("set_vehicle_snapshots", snapshots, _dashboard_vehicle_name, now_timestamp_us)
    if environment_state != null and status_diagram.has_method("update_environment"):
        status_diagram.update_environment(environment_state.snapshot())

func _reset_drone_body() -> void:
    drone_body.reset_contact()
    drone_body.apply_native_state(_spawn_position(), Quaternion.IDENTITY, Vector3.ZERO, Vector3.ZERO)
    drone_body.freeze = true
    if secondary_drone_body != null:
        secondary_drone_body.visible = false
        secondary_drone_body.reset_contact()
        secondary_drone_body.apply_native_state(_spawn_position() + Vector3(1.0, 0.0, 0.0), Quaternion.IDENTITY, Vector3.ZERO, Vector3.ZERO)
        secondary_drone_body.freeze = true
        _set_secondary_collision_enabled(_airsim_vehicle_names.size() > 1 and _airsim_secondary_native != null)

func _refresh_flight_hud() -> void:
    if key_hints_label == null or arm_status_label == null or arm_takeoff_button == null:
        return
    if main_menu_layer != null:
        main_menu_layer.visible = screen in ["main_menu", "settings", "controller_settings", "rates"]
    if main_menu_entries_container != null:
        main_menu_entries_container.visible = screen == "main_menu"
    if settings_panel != null:
        settings_panel.visible = screen == "settings"
    if settings_status_label != null:
        settings_status_label.text = last_error_message if not last_error_message.is_empty() else "Settings ready"
    if controller_settings_panel != null:
        controller_settings_panel.visible = screen == "controller_settings"
    if rates_panel != null:
        rates_panel.visible = screen == "rates"
    if flight_hud_layer != null:
        flight_hud_layer.visible = screen not in ["main_menu", "settings", "controller_settings", "rates"]
    if pause_panel != null:
        pause_panel.visible = paused and screen == "flight"
    if controller_safety_panel != null:
        controller_safety_panel.visible = controller_safety_latched
    if controller_safety_label != null:
        controller_safety_label.text = last_error_message
    if finish_panel != null:
        finish_panel.visible = screen == "finish"
    key_hints_label.text = KEY_HINTS_TEXT
    _refresh_rates_panel()
    arm_takeoff_button.disabled = screen == "main_menu" or (controller_safety_latched and screen != "fallback_prompt")
    if acro_mode_button != null:
        acro_mode_button.disabled = screen != "flight" or paused or controller_safety_latched
        acro_mode_button.text = "ACRO MODE (C): %s" % ("ON" if flight_mode == "ACRO" else "OFF")
    if time_trial_status_label != null:
        time_trial_status_label.visible = time_trial != null and screen in ["preflight", "flight", "finish"]
        if time_trial != null:
            var trial_state := "FINISHED" if time_trial.finished else "NEXT %d/%d" % [time_trial.next_checkpoint_index + 1, time_trial.checkpoint_positions.size()]
            time_trial_status_label.text = "TIME TRIAL | %s | %0.2f s" % [trial_state, time_trial.elapsed_seconds]
    if screen == "preflight":
        var armed := _flight_control_armed()
        arm_status_label.text = "%s | %s -> %s -> press T or ARM" % [_px4_status_text(), _profile_input_status(), "ARMED" if armed else "DISARMED"]
        arm_takeoff_button.text = "ARM / TAKEOFF (T)"
    elif screen == "flight":
        var armed := _flight_control_armed()
        arm_status_label.text = "%s | %s | %s | %s" % [_px4_status_text(), _profile_input_status(), "ARMED" if armed else "DISARMED", "PAUSED" if paused else "TAKEOFF"]
        arm_takeoff_button.text = "ARM / TAKEOFF (T)"
    elif screen == "fallback_prompt":
        arm_status_label.text = last_error_message
        arm_takeoff_button.text = "USE KEYBOARD FALLBACK"
    elif screen == "controller_confirmation":
        arm_status_label.text = "Confirm the fixed Xbox mapping or use KeyboardProfile fallback"
        arm_takeoff_button.text = "BACK TO MAIN MENU"
    elif screen == "error":
        arm_status_label.text = last_error_message
        arm_takeoff_button.text = "BACK TO MAIN MENU"
    elif screen == "exit":
        arm_status_label.text = "EXIT requested"
        arm_takeoff_button.text = "EXIT"
    elif screen == "finish":
        arm_status_label.text = "TIME TRIAL COMPLETE"
        arm_takeoff_button.text = "RETRY"
    elif screen == "controller_disconnected":
        arm_status_label.text = last_error_message
        arm_takeoff_button.text = "WAIT FOR CONTROLLER"
    else:
        arm_status_label.text = "Quick Fly: choose Quick Fly, then arm at low throttle"
        arm_takeoff_button.text = "ARM / TAKEOFF (T)"

func _handle_primary_action() -> void:
    if screen == "fallback_prompt":
        accept_fallback()
    elif screen in ["preflight", "flight"]:
        arm_and_takeoff()
    elif screen in ["controller_confirmation", "error"]:
        if controller_confirmation_panel != null:
            controller_confirmation_panel.hide()
        screen = "main_menu"
        last_error_message = ""
        _refresh_flight_hud()
    elif screen == "finish":
        retry_time_trial()

func _first_connected_device() -> int:
    var devices := gamepad_device_state.connected_joypads()
    for device_id in devices:
        if InputProfiles.GamepadProfile.is_supported_device(device_id, gamepad_device_state):
            return device_id
    return devices[0] if not devices.is_empty() else -1

func _on_joy_connection_changed(device_id: int, connected: bool) -> void:
    handle_controller_connection_changed(device_id, connected)


func handle_controller_connection_changed(device_id: int, connected: bool) -> void:
    if connected:
        if not controller_safety_latched or device_id != disconnected_gamepad_device_id:
            update_fallback_status()
            return
        var profile := InputProfiles.GamepadProfile.xbox_default(device_id, gamepad_device_state)
        if profile == null:
            session_gamepad_profile = null
            session_gamepad_device_id = -1
            last_error_message = "Unsupported controller reconnected; remain disarmed and frozen"
        else:
            session_gamepad_profile = InputProfiles.GamepadProfile.from_persisted_dict(persisted_gamepad_profile.to_persisted_dict()) if persisted_gamepad_profile != null else profile
            session_gamepad_device_id = device_id
            controller_reconnected = true
            screen = "preflight"
            last_error_message = "Controller reconnected; throttle LOW then press ARM/RESUME"
        update_fallback_status()
        _refresh_flight_hud()
        return

    if device_id != session_gamepad_device_id:
        update_fallback_status()
        return
    disconnected_gamepad_device_id = device_id
    controller_safety_latched = true
    controller_reconnected = false
    session_gamepad_profile = null
    session_gamepad_device_id = -1
    keyboard_fallback_explicitly_selected = false
    takeoff_requested = false
    _reset_airsim_flight_state()
    set_paused(true)
    screen = "controller_disconnected"
    last_error_message = "Controller disconnected; vehicle disarmed and frozen"
    update_fallback_status()
    _refresh_flight_hud()

func _refresh_controller_confirmation() -> void:
    if controller_confirmation_panel == null or not controller_confirmation_panel.visible or controller_confirmation_profile == null:
        return
    var mapping_lines := ["FIXED XBOX MAPPING"]
    var live_axis_lines := ["LIVE AXES"]
    for role in ["roll", "pitch", "yaw", "throttle"]:
        var axis := int(controller_confirmation_profile.axis_for_role[role])
        var raw := Input.get_joy_axis(controller_confirmation_device_id, axis)
        var normalized := _normalize_gamepad_axis(raw, controller_confirmation_profile.deadzone)
        mapping_lines.append("%s -> Axis %d%s" % [role, axis, " (reversed)" if controller_confirmation_profile.reversed_for_role[role] else ""])
        live_axis_lines.append("%s: Raw %+.3f | Normalized %+.3f" % [role, raw, normalized])
    confirmation_mapping_label.text = "\n".join(mapping_lines)
    confirmation_axes_label.text = "\n".join(live_axis_lines)

func _refresh_controller_settings() -> void:
    if controller_settings_panel == null or not controller_settings_panel.visible:
        return
    var device_id := _first_connected_device()
    var profile := session_gamepad_profile if _has_active_gamepad_profile() and session_gamepad_device_id == device_id else InputProfiles.GamepadProfile.new()
    if device_id < 0:
        controller_settings_device_label.text = "CURRENT DEVICE: none"
    else:
        var support := "SDL mapped" if InputProfiles.GamepadProfile.is_supported_device(device_id, gamepad_device_state) else "unknown"
        controller_settings_device_label.text = "CURRENT DEVICE: %d %s (%s)" % [device_id, gamepad_device_state.joy_name(device_id), support]
    var mapping_lines := ["FIXED XBOX MAPPING"]
    for role in ["roll", "pitch", "yaw", "throttle"]:
        var axis := int(profile.axis_for_role[role])
        mapping_lines.append("%s -> Axis %d%s" % [role, axis, " (reversed)" if profile.reversed_for_role[role] else ""])
    controller_settings_mapping_label.text = "\n".join(mapping_lines)
    controller_settings_deadzone_label.text = "DEADZONE: %.3f" % profile.deadzone
    controller_settings_button_status_label.text = "Arm %s | Mode %s" % ["PRESSED" if profile.arm_pressed else "RELEASED", "PRESSED" if profile.mode_pressed else "RELEASED"]

func _normalize_gamepad_axis(raw: float, deadzone: float) -> float:
    if absf(raw) <= deadzone:
        return 0.0
    return sign(raw) * (absf(raw) - deadzone) / (1.0 - deadzone)

func _handle_gamepad_button(event: InputEventJoypadButton) -> bool:
    if not _has_active_gamepad_profile() or event.device != session_gamepad_device_id:
        return false
    var profile := session_gamepad_profile
    var is_arm := event.button_index == profile.arm_button
    var is_mode := event.button_index == profile.mode_button
    if not is_arm and not is_mode:
        return false
    if is_arm:
        profile.arm_pressed = event.pressed
    else:
        profile.mode_pressed = event.pressed
    if not event.pressed:
        _refresh_flight_hud()
        return true
    var now_ms := _gamepad_button_now_ms()
    var last_press_ms := last_arm_button_press_ms if is_arm else last_mode_button_press_ms
    if now_ms - last_press_ms < GAMEPAD_BUTTON_DEBOUNCE_MS:
        _refresh_flight_hud()
        return true
    if is_arm:
        last_arm_button_press_ms = now_ms
        if controller_safety_latched:
            if not _profile_throttle_is_low():
                last_error_message = "Resume blocked: throttle_not_low"
                _refresh_flight_hud()
                return true
            controller_safety_latched = false
            controller_reconnected = false
            last_error_message = ""
        if screen in ["preflight", "flight"]:
            arm_and_takeoff()
    else:
        last_mode_button_press_ms = now_ms
        toggle_altitude_hold()
    _refresh_flight_hud()
    return true

func set_gamepad_button_time_source(time_source: Callable) -> void:
    gamepad_button_time_source = time_source

func _gamepad_button_now_ms() -> int:
    if gamepad_button_time_source.is_valid():
        return int(gamepad_button_time_source.call())
    return Time.get_ticks_msec()

func _has_active_gamepad_profile() -> bool:
    return session_gamepad_profile != null and session_gamepad_device_id >= 0

func _profile_axis(role: String) -> float:
    if not _has_active_gamepad_profile():
        return 0.0
    var axis := int(session_gamepad_profile.axis_for_role[role])
    var raw := Input.get_joy_axis(session_gamepad_device_id, axis)
    var normalized := _normalize_gamepad_axis(raw, session_gamepad_profile.deadzone)
    if session_gamepad_profile.reversed_for_role[role]:
        normalized = -normalized
    return normalized

func _profile_throttle_raw() -> float:
    if not _has_active_gamepad_profile():
        return 0.0
    var axis := int(session_gamepad_profile.axis_for_role["throttle"])
    return Input.get_joy_axis(session_gamepad_device_id, axis)

func _flight_throttle() -> float:
    if not _has_active_gamepad_profile():
        return KEYBOARD_FLIGHT_THROTTLE
    session_gamepad_profile.apply_throttle_axis(_profile_throttle_raw())
    return session_gamepad_profile.throttle

func _profile_throttle_is_low() -> bool:
    return _has_active_gamepad_profile() and session_gamepad_profile.throttle_axis_is_low(_profile_throttle_raw())

func _angle_roll_degrees() -> float:
    return _profile_axis("roll") * ANGLE_MAX_TILT_DEGREES

func _angle_pitch_degrees() -> float:
    return _profile_axis("pitch") * ANGLE_MAX_TILT_DEGREES

func _angle_yaw_rate_degrees_per_second() -> float:
    return _profile_axis("yaw") * ANGLE_MAX_YAW_RATE_DPS

func _profile_input_status() -> String:
    if not _has_active_gamepad_profile():
        return "Throttle LOW | KeyboardProfile"
    var throttle := _flight_throttle()
    var is_low := _profile_throttle_is_low()
    return "Throttle %d%% %s | Arm %s | Mode %s" % [roundi(throttle * 100.0), "LOW" if is_low else "HIGH", "PRESSED" if session_gamepad_profile.arm_pressed else "RELEASED", "PRESSED" if session_gamepad_profile.mode_pressed else "RELEASED"]

func _update_chase_camera() -> void:
    if chase_camera == null or drone_body == null:
        return
    chase_camera.current = true
    chase_camera.global_position = drone_body.global_position + CHASE_CAMERA_OFFSET
    chase_camera.look_at(drone_body.global_position, Vector3.UP)
    if secondary_drone_body != null and secondary_chase_camera != null and secondary_drone_body.visible:
        secondary_chase_camera.global_position = secondary_drone_body.global_position + CHASE_CAMERA_OFFSET
        secondary_chase_camera.look_at(secondary_drone_body.global_position, Vector3.UP)


func _airsim_camera_source(vehicle_name: String = "") -> Camera3D:
    if _airsim_vehicle_names.size() > 1 and vehicle_name == String(_airsim_vehicle_names[1]):
        return secondary_chase_camera
    return chase_camera


func _airsim_camera_vehicle(vehicle_name: String):
    if not _airsim_name_matches(vehicle_name):
        return null
    return _secondary_body(vehicle_name) if not _is_primary_airsim_vehicle(vehicle_name) else drone_body


func _airsim_camera_origin() -> Vector3:
    return _spawn_position()

func _flight_control_armed() -> bool:
    if px4_sitl_bridge != null:
        return px4_sitl_bridge.state == "armed"
    return native != null and bool(native.call("flight_control_armed"))


func _px4_status_text() -> String:
    if px4_sitl_bridge == null:
        return "LOCAL"
    var diagnostics: Dictionary = px4_sitl_bridge.diagnostics()
    var message := String(diagnostics.get("message", ""))
    return "PX4 %s%s" % [px4_sitl_bridge.state.to_upper(), " (%s)" % message if not message.is_empty() else ""]

func _kinetic(linear_velocity: Vector3, angular_velocity: Vector3) -> float:
    return 0.5 * _mass_kg() * linear_velocity.length_squared() + 0.5 * angular_velocity.length_squared()

func _mass_kg() -> float:
    if native == null or not native.has_method("hardware_power_diagnostics"):
        return 1.0
    var diagnostics: Dictionary = native.call("hardware_power_diagnostics")
    return maxf(float(diagnostics.get("mass_kg", 1.0)), 0.000001)


func _airsim_name_matches(name: String) -> bool:
    if _airsim_vehicle_names.size() > 1:
        return name in _airsim_vehicle_names
    return name == _airsim_vehicle_name or (_airsim_vehicle_name.is_empty() and name.is_empty())


func _airsim_lifecycle_stopped() -> bool:
    return screen in ["finish", "settings", "controller_settings", "controller_disconnected", "error"] or (screen == "main_menu" and exit_requested)


func _airsim_enable_api_control(enabled: bool, name: String) -> Dictionary:
    if controller_safety_latched and enabled:
        return {"ok": false, "error": "controller_resume_required"}
    if _airsim_lifecycle_stopped():
        return {"ok": false, "error": "flight session is not active"}
    if not _airsim_name_matches(name):
        return {"ok": false, "error": "unknown vehicle: %s" % name}
    if not _is_primary_airsim_vehicle(name):
        var secondary_context: Dictionary = _airsim_vehicle_contexts.get(name, {})
        secondary_context["api_control"] = enabled
        secondary_context["disarm_requested"] = true
        secondary_context["hold_controls"] = _airsim_neutral_controls() if enabled else {}
        if not enabled:
            secondary_context["command_state"] = {}
            secondary_context["command_remaining_frames"] = 0
            secondary_context["armed"] = false
            if _airsim_secondary_native != null:
                _airsim_secondary_native.call("disarm_flight_control")
        _airsim_vehicle_contexts[name] = secondary_context
        return {"ok": true}
    _airsim_api_control = enabled
    _airsim_disarm_requested = true
    _airsim_hold_controls = _airsim_neutral_controls() if enabled else {}
    if not enabled:
        _airsim_command_state.clear()
        _airsim_command_remaining_frames = 0
        if native != null and native.has_method("disarm_flight_control"):
            native.call("disarm_flight_control")
        if px4_sitl_bridge != null:
            px4_sitl_bridge.arm_disarm(false)
    return {"ok": true}


func _airsim_arm_disarm(armed: bool, name: String) -> Dictionary:
    if controller_safety_latched and armed:
        return {"ok": false, "error": "controller_resume_required"}
    if _airsim_lifecycle_stopped():
        return {"ok": false, "error": "flight session is not active"}
    if not _airsim_name_matches(name):
        return {"ok": false, "error": "unknown vehicle: %s" % name}
    if not _is_primary_airsim_vehicle(name):
        if _airsim_secondary_native == null:
            return {"ok": false, "error": "vehicle native runtime unavailable"}
        var secondary_context: Dictionary = _airsim_vehicle_contexts.get(name, {})
        if armed:
            var secondary_armed := bool(_airsim_secondary_native.call("arm_flight_control", 0.0))
            secondary_context["armed"] = secondary_armed
            secondary_context["disarm_requested"] = not secondary_armed
            _airsim_vehicle_contexts[name] = secondary_context
            return {"ok": true, "armed": secondary_armed}
        _airsim_secondary_native.call("disarm_flight_control")
        secondary_context["armed"] = false
        secondary_context["disarm_requested"] = true
        secondary_context["command_state"] = {}
        secondary_context["hold_controls"] = _airsim_neutral_controls()
        secondary_context["command_remaining_frames"] = 0
        _airsim_vehicle_contexts[name] = secondary_context
        return {"ok": true, "armed": false}
    if native == null:
        return {"ok": false, "error": "native runtime unavailable"}
    if px4_sitl_bridge != null:
        var px4_result := px4_sitl_bridge.arm_disarm(armed)
        if not px4_result.ok:
            return px4_result
        _airsim_disarm_requested = not armed
        return {"ok": true, "armed": px4_sitl_bridge.state == "armed" if armed else px4_sitl_bridge.state == "connected"}
    if armed:
        _airsim_disarm_requested = false
        return {"ok": true, "armed": bool(native.call("arm_flight_control", 0.0))}
    _airsim_disarm_requested = true
    if native.has_method("disarm_flight_control"):
        native.call("disarm_flight_control")
    _airsim_command_state.clear()
    _airsim_hold_controls = _airsim_neutral_controls()
    _airsim_command_remaining_frames = 0
    return {"ok": true, "armed": false}


func _airsim_cancel_task(name: String) -> void:
    if not _is_primary_airsim_vehicle(name):
        var secondary_context: Dictionary = _airsim_vehicle_contexts.get(name, {})
        secondary_context["command_state"] = {}
        secondary_context["hold_controls"] = _airsim_neutral_controls()
        secondary_context["command_remaining_frames"] = 0
        _airsim_vehicle_contexts[name] = secondary_context
        return
    if _airsim_name_matches(name):
        _airsim_command_state.clear()
        _airsim_hold_controls = _airsim_neutral_controls()
        _airsim_command_remaining_frames = 0


func _airsim_sensor(sensor_type: int, sensor_name: String, vehicle_name: String) -> Dictionary:
    if airsim_sensor_suite == null:
        return {"ok": false, "error": "sensor backend is unavailable"}
    return airsim_sensor_suite.sensor_result(vehicle_name, sensor_type, sensor_name)


func _secondary_task_complete(context: Dictionary, body) -> bool:
    var command_state: Dictionary = context.get("command_state", {})
    if command_state.is_empty():
        return true
    if body == null:
        return false
    var method := String(command_state.get("method", ""))
    var args: Array = command_state.get("args", [])
    var position_ned := AirSimCoordinateContract.godot_world_to_ned(body.global_position, _spawn_position())
    match method:
        "takeoff":
            return position_ned.z <= -2.75 and body.linear_velocity.length() < 1.0
        "land":
            var landed_on_ground: bool = body.global_position.y <= _spawn_position().y + AIRSIM_GROUND_BODY_CLEARANCE_M and body.linear_velocity.length() < 0.25
            return position_ned.z >= -0.5 and (bool(context.get("contact_this_frame", false)) or landed_on_ground)
        "hover":
            return body.linear_velocity.length() < 2.0 and body.angular_velocity.length() < 1.0
        "goHome":
            return position_ned.length() < 1.0 and body.linear_velocity.length() < 3.0
        "moveToPosition":
            return position_ned.distance_to(Vector3(float(args[0]), float(args[1]), float(args[2]))) < 0.25 and body.linear_velocity.length() < 0.75
        "moveOnPath":
            var path: Array = args[0]
            var index := int(command_state.get("waypoint_index", 0))
            if index >= path.size():
                return true
            var point: Dictionary = path[index]
            return position_ned.distance_to(Vector3(float(point["x_val"]), float(point["y_val"]), float(point["z_val"]))) < 0.25 and index == path.size() - 1 and body.linear_velocity.length() < 0.75
        "rotateToYaw":
            return absf(wrapf(AirSimCoordinateContract.ned_yaw_degrees_to_godot_radians(float(args[0])) - body.rotation.y, -PI, PI)) <= deg_to_rad(maxf(float(args[2]), 1.0)) and body.angular_velocity.length() < 0.75
        "moveByVelocity", "moveByVelocityZ", "moveByVelocityBodyFrame", "moveByVelocityZBodyFrame", "rotateByYawRate", "moveByAngleRatesThrottle":
            return int(context.get("command_remaining_frames", 0)) <= 0
    return false


func _airsim_task_complete(name: String) -> bool:
    if not _airsim_name_matches(name):
        return false
    if not _is_primary_airsim_vehicle(name):
        var secondary_context: Dictionary = _airsim_vehicle_contexts.get(name, {})
        var secondary_complete := _secondary_task_complete(secondary_context, _secondary_body(name))
        if secondary_complete:
            secondary_context["command_state"] = {}
            secondary_context["hold_controls"] = _airsim_neutral_controls()
            secondary_context["command_remaining_frames"] = 0
            _airsim_vehicle_contexts[name] = secondary_context
        return secondary_complete
    if _airsim_command_state.is_empty():
        return true
    if drone_body == null:
        return false
    var method := String(_airsim_command_state["method"])
    var args: Array = _airsim_command_state["args"]
    var position_ned := AirSimCoordinateContract.godot_world_to_ned(drone_body.global_position, _spawn_position())
    match method:
        "takeoff":
            return position_ned.z <= -2.75 and drone_body.linear_velocity.length() < 1.0
        "land":
            var landed_on_ground: bool = drone_body.global_position.y <= _spawn_position().y + AIRSIM_GROUND_BODY_CLEARANCE_M and drone_body.linear_velocity.length() < 0.25
            return position_ned.z >= -0.5 and (_airsim_contact_this_frame or landed_on_ground)
        "hover":
            return drone_body.linear_velocity.length() < 2.0 and drone_body.angular_velocity.length() < 1.0
        "goHome":
            return position_ned.length() < 1.0 and drone_body.linear_velocity.length() < 3.0
        "moveToPosition":
            return position_ned.distance_to(Vector3(float(args[0]), float(args[1]), float(args[2]))) < 0.25 and drone_body.linear_velocity.length() < 0.75
        "moveOnPath":
            var path: Array = args[0]
            var index := int(_airsim_command_state.get("waypoint_index", 0))
            if index >= path.size():
                return true
            var point: Dictionary = path[index]
            return position_ned.distance_to(Vector3(float(point["x_val"]), float(point["y_val"]), float(point["z_val"]))) < 0.25 and index == path.size() - 1 and drone_body.linear_velocity.length() < 0.75
        "rotateToYaw":
            return absf(wrapf(AirSimCoordinateContract.ned_yaw_degrees_to_godot_radians(float(args[0])) - drone_body.rotation.y, -PI, PI)) <= deg_to_rad(maxf(float(args[2]), 1.0)) and drone_body.angular_velocity.length() < 0.75
        "moveByVelocity", "moveByVelocityZ", "moveByVelocityBodyFrame", "moveByVelocityZBodyFrame", "rotateByYawRate", "moveByAngleRatesThrottle":
            return _airsim_command_remaining_frames <= 0
    return false


func _airsim_command(method: String, params: Array, name: String) -> Dictionary:
    if controller_safety_latched:
        return {"ok": false, "error": "controller_resume_required"}
    if _airsim_lifecycle_stopped() or (screen == "main_menu" and method != "takeoff"):
        return {"ok": false, "error": "flight session is not active"}
    if not _airsim_name_matches(name):
        return {"ok": false, "error": "unknown vehicle: %s" % name}
    var args: Array = params.slice(0, params.size() - 1)
    if not _is_primary_airsim_vehicle(name):
        var secondary_context: Dictionary = _airsim_vehicle_contexts.get(name, {})
        var duration_frames := 1
        match method:
            "moveByVelocity", "moveByVelocityZ", "moveByVelocityBodyFrame", "moveByVelocityZBodyFrame":
                duration_frames = maxi(1, ceili(float(args[3]) * float(Engine.physics_ticks_per_second)))
            "rotateByYawRate":
                duration_frames = maxi(1, ceili(float(args[1]) * float(Engine.physics_ticks_per_second)))
            "moveByAngleRatesThrottle":
                duration_frames = maxi(1, ceili(float(args[4]) * float(Engine.physics_ticks_per_second)))
            _:
                duration_frames = maxi(1, int(30.0 * float(Engine.physics_ticks_per_second)))
        secondary_context["command_state"] = {"method": method, "args": args}
        secondary_context["hold_controls"] = _airsim_neutral_controls()
        secondary_context["command_remaining_frames"] = duration_frames
        _airsim_vehicle_contexts[name] = secondary_context
        if method == "takeoff":
            var secondary_body = _secondary_body(name)
            if secondary_body != null:
                secondary_body.reset_contact()
                secondary_body.freeze = false
                secondary_body.sleeping = false
                secondary_body.apply_native_state(secondary_body.global_position, secondary_body.global_transform.basis.get_rotation_quaternion(), Vector3(0.0, 0.5, 0.0), Vector3.ZERO)
        return {"ok": true, "duration_frames": duration_frames}
    if px4_sitl_bridge != null:
        return _airsim_px4_command(method, args)
    var duration_frames := 1
    match method:
        "moveByVelocity", "moveByVelocityZ", "moveByVelocityBodyFrame", "moveByVelocityZBodyFrame":
            duration_frames = maxi(1, ceili(float(args[3]) * float(Engine.physics_ticks_per_second)))
        "rotateByYawRate":
            duration_frames = maxi(1, ceili(float(args[1]) * float(Engine.physics_ticks_per_second)))
        "moveByAngleRatesThrottle":
            duration_frames = maxi(1, ceili(float(args[4]) * float(Engine.physics_ticks_per_second)))
        "takeoff", "land", "hover", "goHome", "moveToPosition", "moveOnPath", "rotateToYaw":
            duration_frames = maxi(1, int(30.0 * float(Engine.physics_ticks_per_second)))
    _airsim_command_state = {"method": method, "args": args, "waypoint_index": 0}
    _airsim_hold_controls = _airsim_neutral_controls()
    _airsim_command_remaining_frames = duration_frames
    takeoff_requested = true
    if method == "takeoff":
        takeoff_requested = true
        screen = "flight"
        if drone_body != null:
            drone_body.reset_contact()
            drone_body.freeze = false
            drone_body.sleeping = false
            drone_body.apply_native_state(drone_body.global_position, drone_body.global_transform.basis.get_rotation_quaternion(), Vector3(0.0, 0.5, 0.0), Vector3.ZERO)
    elif method == "land":
        takeoff_requested = true
    elif method == "goHome":
        takeoff_requested = true
    return {"ok": true, "duration_frames": duration_frames}


func _configure_px4_sitl_bridge() -> void:
    if airsim_rpc_server == null:
        return
    var vehicles: Dictionary = airsim_rpc_server.settings.get("Vehicles", {})
    if vehicles.is_empty():
        return
    var vehicle_settings: Dictionary = vehicles.get(_airsim_vehicle_name, {})
    if String(vehicle_settings.get("VehicleType", "SimpleFlight")) != "PX4Multirotor":
        return
    px4_sitl_bridge = Px4SitlBridge.new()
    var configure_result := px4_sitl_bridge.configure(vehicle_settings, Callable(self, "_on_px4_authority_changed"))
    if not configure_result.ok:
        last_error_message = String(configure_result.error)
        paused = true
        airsim_session.set_paused(true)
        push_error(last_error_message)
        return
    var start_result := px4_sitl_bridge.start()
    if not start_result.ok:
        last_error_message = String(start_result.error)
        paused = true
        airsim_session.set_paused(true)
        push_error(last_error_message)


func _on_px4_authority_changed(active: bool) -> void:
    if not active and px4_sitl_bridge != null and px4_sitl_bridge.state == "failed":
        paused = true
        if airsim_session != null:
            airsim_session.set_paused(true)


func _airsim_px4_command(method: String, args: Array) -> Dictionary:
    var result: Dictionary
    match method:
        "takeoff":
            result = px4_sitl_bridge.takeoff(Vector3(0.0, 0.0, -5.0))
        "land":
            result = px4_sitl_bridge.land()
        "hover":
            result = px4_sitl_bridge.hover()
        "moveToPosition":
            result = px4_sitl_bridge.move_to_position(Vector3(float(args[0]), float(args[1]), float(args[2])))
        "moveOnPath":
            if args.is_empty() or typeof(args[0]) != TYPE_ARRAY or args[0].is_empty():
                return {"ok": false, "error": "PX4 moveOnPath requires at least one waypoint"}
            var point: Dictionary = args[0][0]
            result = px4_sitl_bridge.move_to_position(Vector3(float(point["x_val"]), float(point["y_val"]), float(point["z_val"])))
        _:
            return {"ok": false, "error": "PX4 SITL does not support AirSim command '%s' in this slice" % method}
    if not result.ok:
        return result
    _airsim_command_state = {"method": method, "args": args, "waypoint_index": 0}
    _airsim_command_remaining_frames = maxi(1, int(30.0 * float(Engine.physics_ticks_per_second)))
    takeoff_requested = true
    screen = "flight" if method == "takeoff" else screen
    return {"ok": true, "duration_frames": _airsim_command_remaining_frames}


func _advance_px4_path() -> void:
    if px4_sitl_bridge == null or drone_body == null or _airsim_command_state.get("method", "") != "moveOnPath":
        return
    var command_args: Array = _airsim_command_state.get("args", [])
    if command_args.is_empty() or typeof(command_args[0]) != TYPE_ARRAY:
        return
    var path: Array = command_args[0]
    var index := int(_airsim_command_state.get("waypoint_index", 0))
    if index >= path.size():
        return
    var point: Dictionary = path[index]
    var target_ned := Vector3(float(point["x_val"]), float(point["y_val"]), float(point["z_val"]))
    var current_ned := AirSimCoordinateContract.godot_world_to_ned(drone_body.global_position, _spawn_position())
    if current_ned.distance_to(target_ned) >= 0.25:
        return
    index += 1
    _airsim_command_state["waypoint_index"] = index
    if index < path.size():
        point = path[index]
        px4_sitl_bridge.move_to_position(Vector3(float(point["x_val"]), float(point["y_val"]), float(point["z_val"])))


func _airsim_controls_for_frame() -> Dictionary:
    if px4_sitl_bridge != null:
        return {}
    if not _airsim_api_control:
        return {}
    if _airsim_command_state.is_empty():
        return _airsim_hold_controls.duplicate(true)
    var method := String(_airsim_command_state["method"])
    var args: Array = _airsim_command_state["args"]
    if drone_body != null:
        drone_body.freeze = false
        drone_body.sleeping = false
    else:
        return {}
    match method:
        "takeoff":
            var takeoff_velocity := clampf((3.0 - drone_body.global_position.y) * 1.5, -3.0, 3.0)
            return _airsim_velocity_controls(Vector3(0.0, takeoff_velocity, 0.0), 0.0)
        "land":
            var landing_velocity := clampf((0.0 - drone_body.global_position.y) * 1.5, -3.0, 3.0)
            return _airsim_velocity_controls(Vector3(0.0, landing_velocity, 0.0), 0.0)
        "hover":
            return _airsim_velocity_controls(Vector3.ZERO, 0.0)
        "goHome":
            var home_delta: Vector3 = _spawn_position() - drone_body.global_position
            var home_horizontal := Vector3(home_delta.x, 0.0, home_delta.z)
            var home_velocity := home_horizontal.normalized() * minf(home_horizontal.length() * 1.5, 4.0)
            home_velocity.y = clampf(home_delta.y * 4.0 - drone_body.linear_velocity.y * 3.0, -8.0, 8.0)
            return _airsim_velocity_controls(home_velocity, 0.0)
        "moveByVelocity":
            return _airsim_velocity_controls(AirSimCoordinateContract.ned_direction_to_godot(Vector3(float(args[0]), float(args[1]), float(args[2]))), 0.0, args[5])
        "moveByVelocityZ":
            var horizontal := AirSimCoordinateContract.ned_direction_to_godot(Vector3(float(args[0]), float(args[1]), 0.0))
            return _airsim_velocity_controls(horizontal, (-float(args[2]) - drone_body.global_position.y) * 4.0, args[5])
        "moveByVelocityBodyFrame":
            var body_frd := Vector3(float(args[0]), float(args[1]), float(args[2]))
            var local_godot := AirSimCoordinateContract.frd_to_godot_body(body_frd)
            return _airsim_velocity_controls(drone_body.global_transform.basis * local_godot, 0.0, args[5])
        "moveByVelocityZBodyFrame":
            # AirSim rotates only the horizontal body velocity into the world
            # frame and passes z unchanged to commandVelocityZ; z is NED
            # altitude, not a pitch/roll-rotated body coordinate.
            var position_ned := AirSimCoordinateContract.godot_world_to_ned(drone_body.global_position, _spawn_position())
            var body_target_velocity := Vector3(float(args[0]), float(args[1]), (float(args[2]) - position_ned.z) * 2.0)
            var body_velocity_local := AirSimCoordinateContract.frd_to_godot_body(body_target_velocity)
            return _airsim_velocity_controls(drone_body.global_transform.basis * body_velocity_local, 0.0, args[5])
        "moveToPosition", "moveOnPath":
            var target_ned: Vector3
            if method == "moveToPosition":
                target_ned = Vector3(float(args[0]), float(args[1]), float(args[2]))
            else:
                var path: Array = args[0]
                var waypoint_index := int(_airsim_command_state.get("waypoint_index", 0))
                if waypoint_index >= path.size():
                    _airsim_hold_controls = _airsim_neutral_controls()
                    _airsim_command_state.clear()
                    return _airsim_hold_controls.duplicate(true)
                var waypoint: Dictionary = path[waypoint_index]
                target_ned = Vector3(float(waypoint["x_val"]), float(waypoint["y_val"]), float(waypoint["z_val"]))
            var delta_world: Vector3 = AirSimCoordinateContract.ned_to_godot_world(target_ned, _spawn_position()) - drone_body.global_position
            var command_speed := float(args[3]) if method == "moveToPosition" else float(args[1])
            if method == "moveOnPath" and delta_world.length() < 0.25:
                _airsim_command_state["waypoint_index"] = int(_airsim_command_state.get("waypoint_index", 0)) + 1
            var yaw_mode: Variant = args[6] if method == "moveToPosition" else args[4]
            return _airsim_velocity_controls(delta_world.normalized() * minf(delta_world.length() * 2.0, command_speed), delta_world.y * 4.0, yaw_mode)
        "rotateToYaw":
            var target_yaw := AirSimCoordinateContract.ned_yaw_degrees_to_godot_radians(float(args[0]))
            var delta_yaw := wrapf(target_yaw - drone_body.rotation.y, -PI, PI)
            var rotate_to_controls := _airsim_velocity_controls(Vector3.ZERO, 0.0)
            rotate_to_controls["yaw_rate"] = clampf(rad_to_deg(delta_yaw) * 3.0, -ANGLE_MAX_YAW_RATE_DPS, ANGLE_MAX_YAW_RATE_DPS)
            return rotate_to_controls
        "rotateByYawRate":
            var rotate_rate_controls := _airsim_velocity_controls(Vector3.ZERO, 0.0)
            rotate_rate_controls["yaw_rate"] = clampf(-float(args[0]), -ANGLE_MAX_YAW_RATE_DPS, ANGLE_MAX_YAW_RATE_DPS)
            return rotate_rate_controls
        "moveByAngleRatesThrottle":
            return {"mode": "ACRO", "throttle": float(args[3]), "acro_roll": _airsim_rate_stick(rad_to_deg(float(args[0]))), "acro_pitch": _airsim_rate_stick(rad_to_deg(float(args[1]))), "acro_yaw": _airsim_rate_stick(rad_to_deg(float(args[2])))}
    return {}


func _airsim_velocity_controls(velocity_world: Vector3, vertical_correction: float, yaw_mode: Variant = null, body = null) -> Dictionary:
    var desired := velocity_world
    var measured_body = body if body != null else drone_body
    var measured_velocity: Vector3 = measured_body.linear_velocity if measured_body != null else Vector3.ZERO
    var horizontal_velocity_error := Vector3(desired.x - measured_velocity.x, 0.0, desired.z - measured_velocity.z)
    var measured_vertical_velocity: float = measured_velocity.y
    var vertical_velocity_error: float = desired.y - measured_vertical_velocity
    var throttle := clampf(0.50 + vertical_velocity_error * 0.15 + clampf(vertical_correction, -0.5, 0.5), 0.0, 1.0)
    return {
        "mode": "ANGLE",
        "throttle": throttle,
        "roll": clampf(-horizontal_velocity_error.x * 4.0, -ANGLE_MAX_TILT_DEGREES, ANGLE_MAX_TILT_DEGREES),
        "pitch": clampf(horizontal_velocity_error.z * 4.0, -ANGLE_MAX_TILT_DEGREES, ANGLE_MAX_TILT_DEGREES),
        "yaw_rate": _airsim_yaw_rate_from_mode(yaw_mode, measured_body),
    }


func _airsim_yaw_rate_from_mode(yaw_mode: Variant, body = null) -> float:
    if typeof(yaw_mode) != TYPE_DICTIONARY:
        return 0.0
    var requested := float(yaw_mode.get("yaw_or_rate", 0.0))
    if bool(yaw_mode.get("is_rate", true)):
        return clampf(-requested, -ANGLE_MAX_YAW_RATE_DPS, ANGLE_MAX_YAW_RATE_DPS)
    var yaw_body = body if body != null else drone_body
    if yaw_body == null:
        return 0.0
    var delta_yaw := wrapf(AirSimCoordinateContract.ned_yaw_degrees_to_godot_radians(requested) - yaw_body.rotation.y, -PI, PI)
    return clampf(rad_to_deg(delta_yaw) * 3.0, -ANGLE_MAX_YAW_RATE_DPS, ANGLE_MAX_YAW_RATE_DPS)


func _airsim_rate_stick(rate_degrees_per_second: float, target_native: Object = null) -> float:
    var rate_native: Object = target_native if target_native != null else native
    if rate_native != null and rate_native.has_method("betaflight_stick_for_rate"):
        return float(rate_native.call("betaflight_stick_for_rate", rate_degrees_per_second, _acro_rate("rc_rate"), _acro_rate("super_rate"), _acro_rate("expo")))
    return clampf(rate_degrees_per_second / 720.0, -1.0, 1.0)


func _airsim_neutral_controls() -> Dictionary:
    return {"mode": "ANGLE", "throttle": 0.50, "roll": 0.0, "pitch": 0.0, "yaw_rate": 0.0}


func _airsim_state(name: String) -> Dictionary:
    if not _airsim_name_matches(name):
        return {"ok": false, "error": "unknown vehicle: %s" % name}
    if not _is_primary_airsim_vehicle(name):
        return _airsim_secondary_state(name)
    var position: Vector3 = drone_body.global_position if drone_body != null else _spawn_position()
    var orientation: Quaternion = drone_body.global_transform.basis.get_rotation_quaternion() if drone_body != null else Quaternion.IDENTITY
    var linear_velocity: Vector3 = drone_body.linear_velocity if drone_body != null else Vector3.ZERO
    var angular_velocity: Vector3 = drone_body.angular_velocity if drone_body != null else Vector3.ZERO
    var body_basis_inverse: Basis = drone_body.global_transform.basis.inverse() if drone_body != null else Basis.IDENTITY
    var origin: Dictionary = airsim_rpc_server.settings.get("OriginGeopoint", {}) if airsim_rpc_server != null else {}
    var position_ned := AirSimCoordinateContract.godot_world_to_ned(position, _spawn_position())
    const EARTH_RADIUS_M := 6378137.0
    var origin_latitude := float(origin.get("Latitude", 0.0))
    var origin_longitude := float(origin.get("Longitude", 0.0))
    var origin_altitude := float(origin.get("Altitude", 0.0))
    var latitude_scale := maxf(cos(deg_to_rad(origin_latitude)), 0.01)
    var gps_location := {
        "latitude": origin_latitude + rad_to_deg(position_ned.x / EARTH_RADIUS_M),
        "longitude": origin_longitude + rad_to_deg(position_ned.y / (EARTH_RADIUS_M * latitude_scale)),
        "altitude": origin_altitude - position_ned.z,
    }
    var native_imu_sample := {}
    if native != null and native.has_method("imu_sample"):
        var raw_imu: Dictionary = native.call("imu_sample")
        if bool(raw_imu.get("valid", false)):
            var measurement_orientation := Quaternion(
                float(raw_imu.get("measurement_orientation_x", 0.0)),
                float(raw_imu.get("measurement_orientation_y", 0.0)),
                float(raw_imu.get("measurement_orientation_z", 0.0)),
                float(raw_imu.get("measurement_orientation_w", 1.0))
            ).normalized()
            var raw_acceleration := Vector3(
                float(raw_imu.get("accel_x", 0.0)),
                float(raw_imu.get("accel_y", 0.0)),
                float(raw_imu.get("accel_z", 0.0))
            )
            native_imu_sample = {
                "gyro": _airsim_vector3(AirSimCoordinateContract.godot_body_to_frd(Vector3(raw_imu.get("gyro_x", 0.0), raw_imu.get("gyro_y", 0.0), raw_imu.get("gyro_z", 0.0)))),
                "accel": _airsim_vector3(AirSimCoordinateContract.godot_body_to_frd(raw_acceleration)),
                "orientation": _airsim_quaternion(AirSimCoordinateContract.godot_orientation_to_ned(measurement_orientation)),
                "barometer_altitude_m": float(raw_imu.get("barometer_altitude_m", -position.y)),
            }
    var collision := {
        "has_collided": _airsim_collision_seen,
        "normal": _airsim_vector3(AirSimCoordinateContract.godot_direction_to_ned(_airsim_collision_normal)),
        "impact_point": _airsim_vector3(AirSimCoordinateContract.godot_world_to_ned(_airsim_collision_point, _spawn_position())),
        "position": _airsim_vector3(AirSimCoordinateContract.godot_world_to_ned(position, _spawn_position())),
        "penetration_depth": 0.0,
        "time_stamp": int(round(airsim_session.simulation_time_seconds * 1_000_000_000.0)),
        "object_name": "",
        "object_id": -1,
    }
    var landed := position.y <= _spawn_position().y + AIRSIM_GROUND_BODY_CLEARANCE_M and linear_velocity.length() < 0.25
    var state := {
        "collision": collision,
        "kinematics_estimated": {
            "position": _airsim_vector3(AirSimCoordinateContract.godot_world_to_ned(position, _spawn_position())),
            "orientation": _airsim_quaternion(AirSimCoordinateContract.godot_orientation_to_ned(orientation)),
            "linear_velocity": _airsim_vector3(AirSimCoordinateContract.godot_direction_to_ned(linear_velocity)),
            "angular_velocity": _airsim_vector3(AirSimCoordinateContract.godot_body_to_frd(body_basis_inverse * angular_velocity)),
            "linear_acceleration": _airsim_vector3(AirSimCoordinateContract.godot_body_to_frd(body_basis_inverse * _airsim_linear_acceleration)),
            "angular_acceleration": _airsim_vector3(AirSimCoordinateContract.godot_body_to_frd(_airsim_angular_acceleration)),
        },
        "gps_location": gps_location,
        "imu_sample": native_imu_sample,
        "timestamp": int(round(airsim_session.simulation_time_seconds * 1_000_000_000.0)),
        "landed_state": 0 if landed else 1,
        "rc_data": {"timestamp": 0, "pitch": 0.0, "roll": 0.0, "throttle": _flight_throttle(), "yaw": 0.0, "is_initialized": false, "is_valid": false},
        "ready": native != null,
        "ready_message": "" if native != null else "native runtime unavailable",
        "can_arm": native != null,
        "aerosim_identity": {"vehicle_name": _airsim_vehicle_name},
    }
    return {"ok": true, "state": state}


func _airsim_secondary_state(name: String) -> Dictionary:
    var body = _secondary_body(name)
    var context: Dictionary = _airsim_vehicle_contexts.get(name, {})
    if body == null:
        return {"ok": false, "error": "vehicle body is unavailable: %s" % name}
    var position: Vector3 = body.global_position
    var orientation: Quaternion = body.global_transform.basis.get_rotation_quaternion()
    var linear_velocity: Vector3 = body.linear_velocity
    var angular_velocity: Vector3 = body.angular_velocity
    var origin: Dictionary = airsim_rpc_server.settings.get("OriginGeopoint", {}) if airsim_rpc_server != null else {}
    var position_ned := AirSimCoordinateContract.godot_world_to_ned(position, _spawn_position())
    const earth_radius_m := 6378137.0
    var origin_latitude := float(origin.get("Latitude", 0.0))
    var origin_longitude := float(origin.get("Longitude", 0.0))
    var origin_altitude := float(origin.get("Altitude", 0.0))
    var latitude_scale := maxf(cos(deg_to_rad(origin_latitude)), 0.01)
    var gps_location := {
        "latitude": origin_latitude + rad_to_deg(position_ned.x / earth_radius_m),
        "longitude": origin_longitude + rad_to_deg(position_ned.y / (earth_radius_m * latitude_scale)),
        "altitude": origin_altitude - position_ned.z,
    }
    var native_imu_sample := {}
    if _airsim_secondary_native != null and _airsim_secondary_native.has_method("imu_sample"):
        var raw_imu: Dictionary = _airsim_secondary_native.call("imu_sample")
        if bool(raw_imu.get("valid", false)):
            native_imu_sample = {
                "gyro": _airsim_vector3(AirSimCoordinateContract.godot_body_to_frd(Vector3(raw_imu.get("gyro_x", 0.0), raw_imu.get("gyro_y", 0.0), raw_imu.get("gyro_z", 0.0)))),
                "accel": _airsim_vector3(AirSimCoordinateContract.godot_body_to_frd(Vector3(raw_imu.get("accel_x", 0.0), raw_imu.get("accel_y", 0.0), raw_imu.get("accel_z", 0.0)))),
                "orientation": _airsim_quaternion(AirSimCoordinateContract.godot_orientation_to_ned(Quaternion(
                    float(raw_imu.get("measurement_orientation_x", 0.0)),
                    float(raw_imu.get("measurement_orientation_y", 0.0)),
                    float(raw_imu.get("measurement_orientation_z", 0.0)),
                    float(raw_imu.get("measurement_orientation_w", 1.0))).normalized())),
                "barometer_altitude_m": float(raw_imu.get("barometer_altitude_m", -position.y)),
            }
    var collision := {
        "has_collided": bool(context.get("collision_seen", false)),
        "normal": _airsim_vector3(AirSimCoordinateContract.godot_direction_to_ned(context.get("collision_normal", Vector3.ZERO))),
        "impact_point": _airsim_vector3(AirSimCoordinateContract.godot_world_to_ned(context.get("collision_point", Vector3.ZERO), _spawn_position())),
        "position": _airsim_vector3(AirSimCoordinateContract.godot_world_to_ned(position, _spawn_position())),
        "penetration_depth": 0.0,
        "time_stamp": int(round(airsim_session.simulation_time_seconds * 1_000_000_000.0)),
        "object_name": "",
        "object_id": -1,
    }
    var state := {
        "collision": collision,
        "kinematics_estimated": {
            "position": _airsim_vector3(AirSimCoordinateContract.godot_world_to_ned(position, _spawn_position())),
            "orientation": _airsim_quaternion(AirSimCoordinateContract.godot_orientation_to_ned(orientation)),
            "linear_velocity": _airsim_vector3(AirSimCoordinateContract.godot_direction_to_ned(linear_velocity)),
            "angular_velocity": _airsim_vector3(AirSimCoordinateContract.godot_body_to_frd(body.global_transform.basis.inverse() * angular_velocity)),
            "linear_acceleration": _airsim_vector3(AirSimCoordinateContract.godot_body_to_frd(body.global_transform.basis.inverse() * context.get("linear_acceleration", Vector3.ZERO))),
            "angular_acceleration": _airsim_vector3(AirSimCoordinateContract.godot_body_to_frd(context.get("angular_acceleration", Vector3.ZERO))),
        },
        "gps_location": gps_location,
        "imu_sample": native_imu_sample,
        "timestamp": int(round(airsim_session.simulation_time_seconds * 1_000_000_000.0)),
        "landed_state": 0 if position.y <= _spawn_position().y + AIRSIM_GROUND_BODY_CLEARANCE_M and linear_velocity.length() < 0.25 else 1,
        "rc_data": {"timestamp": 0, "pitch": 0.0, "roll": 0.0, "throttle": 0.0, "yaw": 0.0, "is_initialized": false, "is_valid": false},
        "ready": _airsim_secondary_native != null,
        "ready_message": "" if _airsim_secondary_native != null else "native runtime unavailable",
        "can_arm": _airsim_secondary_native != null,
        "aerosim_identity": {"vehicle_name": name},
    }
    return {"ok": true, "state": state}


func _airsim_vector3(value: Vector3) -> Dictionary:
    return {"x_val": value.x, "y_val": value.y, "z_val": value.z}


func _airsim_quaternion(value: Quaternion) -> Dictionary:
    return {"w_val": value.w, "x_val": value.x, "y_val": value.y, "z_val": value.z}

func _acro_roll_stick() -> float:
    if acro_roll_stick != 0.0:
        return acro_roll_stick
    return Input.get_axis("ui_left", "ui_right")

func _acro_pitch_stick() -> float:
    if acro_pitch_stick != 0.0:
        return acro_pitch_stick
    return Input.get_axis("ui_down", "ui_up")

func _acro_yaw_stick() -> float:
    return acro_yaw_stick

func _sync_native_from_drone() -> void:
    var q: Quaternion = drone_body.global_transform.basis.get_rotation_quaternion()
    native.call(
        "sync_flight_state",
        drone_body.global_position.x,
        drone_body.global_position.y,
        drone_body.global_position.z,
        q.x,
        q.y,
        q.z,
        q.w,
        drone_body.linear_velocity.x,
        drone_body.linear_velocity.y,
        drone_body.linear_velocity.z,
        drone_body.angular_velocity.x,
        drone_body.angular_velocity.y,
        drone_body.angular_velocity.z
    )
