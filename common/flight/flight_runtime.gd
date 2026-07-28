extends Node3D

const InputProfiles = preload("res://common/flight/input_profiles.gd")
const GamepadDeviceState = preload("res://common/flight/gamepad_device_state.gd")
const SettingsStoreScript = preload("res://common/flight/settings_store.gd")
const LanguageProfile = preload("res://common/flight/language_profile.gd")
const Localization = preload("res://common/flight/localization.gd")
const RatesProfile = preload("res://common/flight/rates_profile.gd")
const QualityProfile = preload("res://common/flight/quality_profile.gd")
const CameraProfile = preload("res://common/flight/camera_profile.gd")
const OsdProfile = preload("res://common/flight/osd_profile.gd")
const HardwareConfig = preload("res://common/flight/hardware_config.gd")
const GspPresetStore = preload("res://common/gsp/gsp_preset_store.gd")
const StatusDiagramDebug = preload("res://common/flight/status_diagram_debug.gd")
const RotorTelemetryPanel = preload("res://common/flight/rotor_telemetry_panel.gd")
const GamepadTelemetryPanel = preload("res://common/flight/gamepad_telemetry_panel.gd")
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
const ReplayIntegrationRunner = preload("res://common/flight/replay_integration_runner.gd")
const LicenseProviderScript = preload("res://common/license/license_provider.gd")
const DEFAULT_HARDWARE_PRESET := "res://config/drones/5_inch_6s.json"
const LICENSE_PROVIDER_CONFIG_PATH := "res://config/license_provider.json"
const DEFAULT_FREE_FLIGHT_MAP_ID := "terrain3d_range"
const DEFAULT_FLIGHT_MODE := "ANGLE"
const DEFAULT_WIND_PRESET := "calm"
const MAP_SCENE_PATHS := {
    "industrial_yard": "res://levels/free_flight/industrial_yard.tscn",
    "terrain3d_range": "res://levels/free_flight/terrain3d_range.tscn"
}
const SPAWN_POSITION := Vector3(-1.0, 0.0, 0.0)
const AIRSIM_GROUND_BODY_CLEARANCE_M := 0.25
## Altitude the AirSim `takeoff` command climbs to, above the spawn origin.
const AIRSIM_TAKEOFF_ALTITUDE_M := 3.0
const KEYBOARD_FLIGHT_THROTTLE := 0.75
const TAKEOFF_ASSIST_ALTITUDE_M := 1.0
const TAKEOFF_ASSIST_VERTICAL_SPEED_MPS := 0.75
const ANGLE_MAX_TILT_DEGREES := 30.0
const ANGLE_MAX_YAW_RATE_DPS := 180.0
const ASSISTED_MAX_YAW_RATE_DPS := 120.0
const ASSISTED_MAX_VERTICAL_SPEED_MPS := 2.0
const GAMEPAD_BUTTON_DEBOUNCE_MS := 50
const COCKPIT_LEFT_RAIL_WIDTH := 360.0
const COCKPIT_RIGHT_RAIL_WIDTH := 436.0
const CHASE_CAMERA_OFFSET := Vector3(-3.0, 1.4, 2.2)
const THIRD_PERSON_CAMERA_OFFSET := Vector3(0.0, 0.8, 1.8)
const WIND_PRESETS := ["calm", "light", "moderate", "severe"]

@export var scene_steady_wind_mps := Vector3.ZERO

@onready var fallback_status_label: Label3D = %FallbackStatus
@onready var drone_body = get_node_or_null("DroneBody")
@onready var chase_camera := get_node_or_null("ChaseCamera") as Camera3D
@onready var third_person_camera := get_node_or_null("ThirdPersonCamera") as Camera3D
@onready var secondary_drone_body = get_node_or_null("DroneBodySecondary")
@onready var secondary_chase_camera := get_node_or_null("ChaseCameraSecondary") as Camera3D

var native: Object
var license_provider: Node
var airsim_session: AirSimSession
var airsim_rpc_server: AirSimRpcServer
var airsim_sensor_suite: AirSimSensorSuite
var px4_sitl_bridge: Px4SitlBridge
var airsim_camera_surface: AirSimCameraSurface
var scene_object_catalog: SceneObjectCatalog
var environment_state: EnvironmentState
var airsim_stop_file := ""
var _map_scene_paths: Dictionary = MAP_SCENE_PATHS.duplicate()
var loaded_map: Node3D
var loaded_map_id := ""
var loaded_map_wind_preset := "calm"
var loaded_spawn_names: Array[String] = []
var current_spawn_index := 0
var selected_wind_preset := ""
var time_trial: TimeTrialController
var camera_profile: Dictionary = CameraProfile.default_profile()
var osd_profile: Dictionary = OsdProfile.default_profile()
var paused := false
var participant_mode := false
var exit_requested := false
var quit_on_exit := true
var takeoff_requested := false
var takeoff_assist_active := false
var takeoff_assist_commanded_altitude_m := 0.0
var assisted_throttle_waiting_for_neutral := false
var assisted_hover_throttle := 0.0
var assisted_horizontal_intent_active := false
var reset_count := 0
var _reset_generation := 0
var _reset_pending_token := 0
var _reset_pending_frames := 0
var _reset_pending_spawn := Vector3.ZERO
var _reset_pending_secondary_spawn := Vector3.ZERO
var _reset_pending_primary_ack_required := false
var _reset_pending_secondary_ack_required := false
var _reset_primary_gravity_scale := 1.0
var _reset_secondary_gravity_scale := 1.0
var _reset_environment_snapshot: Dictionary = {}
var _reset_commit_in_progress := false
var _reset_publication_blocked := false
var _reset_after_commit_takeoff := false
var _reset_arm_after_commit := false
var _rpc_reset_owned_generation := 0
var _reset_last_committed_generation := 0
var _reset_last_failed_generation := 0
var _quick_fly_route_pending := false
var last_profile_status := ""
var main_menu_entries := ["Quick Fly", "Lab Mode", "Controller", "Drone", "Map", "Settings", "Quit"]
var screen := "main_menu"
var flight_setup: Dictionary = {}
var flight_setup_focus := "drone"
var last_error_message := ""
var last_collision_authority := -1
var collision_handoff_count := 0
var reset_hold_frames := 0
var flight_mode := "ANGLE"
var acro_roll_stick := 0.0
var acro_pitch_stick := 0.0
var acro_yaw_stick := 0.0
var dashboard_layout_mode := "compact"
var development_license_bypass := OS.is_debug_build()
var status_diagram: CanvasLayer
var body_drag_debug_panel: Node
var main_menu_layer: CanvasLayer
var main_menu_entries_container: VBoxContainer
var settings_panel: Control
var settings_status_label: Label
var language_selector: OptionButton
var rates_panel: Control
var rates_status_label: Label
var rates_json_editor: TextEdit
var rates_diff_label: Label
var rates_curve_line: Line2D
var rates_curve_plot: Control
var rates_sliders: Dictionary = {}
var rates_slider_labels: Dictionary = {}
var rates_return_screen := "settings"
var camera_return_screen := "settings"
var osd_return_screen := "settings"
var controller_settings_return_screen := "settings"
var status_diagram_fullscreen := false
var render_scale := QualityProfile.DEFAULT_RENDER_SCALE
var graphics_committed_scale := QualityProfile.DEFAULT_RENDER_SCALE
var graphics_return_screen := "settings"
var graphics_panel: Control
var graphics_value_label: Label
var controller_settings_panel: Control
var flight_hud_layer: CanvasLayer
var motor_hud_panel: PanelContainer
var motor_hud_labels: Dictionary = {}
var motor_hud_rotor_panel: Control
var motor_hud_spin_directions: Array = []
var gamepad_hud_panel: PanelContainer
var gamepad_hud_display: Control
var key_hints_label: Label
var arm_status_label: Label
var player_view_label: Label
var arm_takeoff_button: Button
var lab_back_button: Button
var license_panel: Control
var license_status_label: Label
var license_key_input: LineEdit
var license_activate_button: Button
var license_retry_button: Button
var license_diagnostics_button: Button
var license_exit_button: Button
var acro_mode_button: Button
var quick_adjust_status_label: Label
var time_trial_status_label: Label
var pause_panel: Control
var status_diagram_back_button: Button
var finish_panel: Control
var finish_summary_label: Label
var camera_panel: Control
var osd_panel: Control
var osd_preset_selector: OptionButton
var osd_labels: Dictionary = {}
var osd_drag_element := ""
var osd_drag_offset := Vector2.ZERO
var analog_noise_overlay: ColorRect
var camera_profile_persisted := false
var session_gamepad_profile: InputProfiles.GamepadProfile
var session_gamepad_device_id := -1
var gamepad_device_state: GamepadDeviceState.DeviceState = GamepadDeviceState.DeviceState.new()
var controller_confirmation_panel: Control
var controller_confirmation_profile: InputProfiles.GamepadProfile
var controller_confirmation_device_id := -1
var controller_return_screen := "preflight"
var third_person_view := false
var confirmation_mapping_label: Label
var confirmation_axes_label: Label
var controller_settings_device_label: Label
var controller_settings_mapping_label: Label
var controller_settings_monitor_label: Label
var controller_monitor_refresh_count := 0
var flight_setup_panel: Control
var controller_safety_panel: Control
var controller_safety_label: Label
var last_arm_button_press_ms := -1000000
var last_mode_button_press_ms := -1000000
var gamepad_pause_pressed := false
var gamepad_button_time_source: Callable
var settings_store: RefCounted
var persisted_gamepad_profile: InputProfiles.GamepadProfile
var keyboard_fallback_explicitly_selected := false
var controller_safety_latched := false
var controller_reconnected := false
var disconnected_gamepad_device_id := -1
var _airsim_vehicle_name := ""
var _airsim_vehicle_names: Array[String] = []
var _airsim_ready_file_pending := ""
var _dashboard_vehicle_name := ""
var _airsim_secondary_native: Object
var _replay_recording_active := false
var _replay_recording_failed := false
var _replay_recording_failure := ""
var _replay_authoritative_physics_tick := 0
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
var _gsp_telemetry_cache: Dictionary = {}
var _gsp_telemetry_publish_count := -1
var _gsp_tuning_registry: Array = []
var _gsp_tuning_registry_hash := "unavailable"
var _gsp_tuning_pending: Array[Dictionary] = []
var _gsp_tuning_completed: Array[Dictionary] = []
var _gsp_tuning_recent_results: Array[Dictionary] = []
const GSP_MIGRATION_CAPABILITY_TTL_MS := 30_000
const GSP_MIGRATION_CAPABILITY_LIMIT := 8
var _gsp_migration_capabilities: Array[Dictionary] = []
var _gsp_used_migration_ids: Array[String] = []
var _gsp_expired_migration_ids: Array[String] = []
var _native_external_authority_state: Variant = null
var _quick_adjust_profile: Dictionary = InputProfiles.QuickAdjustProfile.default_profile()
var _quick_adjust_next_allowed_usec: Array[int] = []
var _quick_adjust_request_seq := 0
var _quick_adjust_active_slot := -1
var _quick_adjust_last_value := 0.0
var _quick_adjust_pressed_keys: Dictionary = {}
var _quick_adjust_axis_values: Dictionary = {}
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
    if _has_arg("--aerosim-replay-integration"):
        _run_replay_integration()
        return
    Input.joy_connection_changed.connect(_on_joy_connection_changed)
    settings_store = SettingsStoreScript.new()
    _load_player_settings()
    _restore_startup_gamepad_session()
    var startup_settings := _load_and_validate_airsim_settings()
    if startup_settings.is_empty():
        return
    _build_main_menu()
    _build_flight_hud()
    _build_status_diagram()
    set_participant_mode(_has_arg("--aerosim-participant-mode"))
    if not _configure_license_provider_from_path(LICENSE_PROVIDER_CONFIG_PATH):
        return
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
    airsim_rpc_server.set_session(airsim_session)
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
    airsim_rpc_server.set_replay_handlers(
        Callable(self, "_record_replay_simulation_operation"),
        Callable(self, "_record_replay_async"),
        Callable(self, "_record_replay_reset_environment"))
    airsim_rpc_server.set_publication_error_handler(Callable(self, "_reset_publication_error"))
    airsim_rpc_server.set_reset_lifecycle_handlers(
        Callable(self, "_begin_rpc_reset"),
        Callable(self, "_rpc_reset_status"),
        Callable(self, "_abort_rpc_reset"))
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
    _gsp_tuning_registry = hardware_config.tuning_registry()
    _gsp_tuning_registry_hash = hardware_config.tuning_registry_hash()
    var quick_adjust_validation := validate_quick_adjust_profile(_quick_adjust_profile)
    if not bool(quick_adjust_validation.get("ok", false)):
        _quick_adjust_profile = InputProfiles.QuickAdjustProfile.default_profile()
        last_error_message = "Quick Adjust settings rejected: %s" % String(quick_adjust_validation.get("error", "invalid binding"))
    _reset_quick_adjust_rate_limits()
    if not hardware_config.initialize_tuning(self):
        last_error_message = hardware_config.last_error
        push_error("Default tuning initialization failed: %s" % hardware_config.last_error)
    if not hardware_config.apply_to_runtime(self, DEFAULT_HARDWARE_PRESET):
        last_error_message = hardware_config.last_error
        push_error("Default hardware preset failed: %s" % hardware_config.last_error)
    motor_hud_spin_directions = hardware_config.current.get("spin_direction", [])
    if not _configure_secondary_native(hardware_config):
        push_error("Named vehicle runtime setup failed: %s" % last_error_message)
        if airsim_rpc_server != null and airsim_rpc_server.is_running():
            airsim_rpc_server.stop()
        get_tree().quit(1)
        return
    _apply_hardware_camera_defaults(hardware_config)
    _begin_complete_replay_recording(startup_settings)
    var ready_file := _cold_start_arg("--airsim-ready-file")
    if not ready_file.is_empty() and _airsim_vehicle_names.size() >= 2 and loaded_map == null:
        if not load_map(DEFAULT_FREE_FLIGHT_MAP_ID):
            push_error("AirSim default map setup failed: %s" % last_error_message)
            if airsim_rpc_server != null and airsim_rpc_server.is_running():
                airsim_rpc_server.stop()
            get_tree().quit(1)
            return
        if not reset_to_spawn():
            push_error("AirSim default spawn reset failed: %s" % last_error_message)
            if airsim_rpc_server != null and airsim_rpc_server.is_running():
                airsim_rpc_server.stop()
            get_tree().quit(1)
            return
        screen = "preflight"
        _airsim_ready_file_pending = ready_file
    else:
        _write_airsim_ready_marker(ready_file)
    update_fallback_status()
    _update_chase_camera()
    _refresh_flight_hud()
    call_deferred("_run_cold_start_probe")


func _run_replay_integration() -> void:
    var result: Dictionary = ReplayIntegrationRunner.new().run()
    if bool(result.get("ok", false)):
        print("complete-session replay integration: PASS")
        get_tree().quit(0)
    else:
        push_error(String(result.get("error", "unknown")))
        get_tree().quit(1)


func _configure_license_provider_from_path(path: String) -> bool:
    if license_provider == null:
        license_provider = LicenseProviderScript.new()
        add_child(license_provider)
    var result: Dictionary = license_provider.configure_from_path(path)
    if not bool(result.get("ok", false)):
        _show_license_blocked("License provider configuration failed: %s" % String(result.get("error_code", "unknown")))
        return false
    return true


func _configure_license_provider(config: Dictionary) -> bool:
    if license_provider == null:
        license_provider = LicenseProviderScript.new()
        add_child(license_provider)
    var result: Dictionary = license_provider.configure(config)
    if not bool(result.get("ok", false)):
        _show_license_blocked("License provider configuration failed: %s" % String(result.get("error_code", "unknown")))
        return false
    return true


func get_license_snapshot() -> Dictionary:
    if license_provider == null:
        return {"ok": false, "status": "invalid_token", "fatal": {"kind": "config", "code": "not_configured"}}
    return license_provider.get_snapshot()


func can_start_quick_fly() -> bool:
    if development_license_bypass:
        return true
    var status := String(get_license_snapshot().get("status", "invalid_token"))
    return status in ["online_valid", "offline_grace_valid"]


func license_actions() -> Array[String]:
    var snapshot := get_license_snapshot()
    if snapshot.has("fatal"):
        return ["exit"]
    var status := String(snapshot.get("status", "invalid_token"))
    if status == "not_activated":
        return ["activate_license", "diagnostics", "exit"]
    if status in ["offline_grace_expired", "revoked", "invalid_token"]:
        return ["retry_license", "diagnostics", "exit"]
    return []


func activate_license(license_key: String = "") -> Dictionary:
    var snapshot := get_license_snapshot()
    if snapshot.has("fatal"):
        var fatal_result := {"ok": false, "error_type": "fatal", "error_code": String(snapshot.fatal.code)}
        _record_license_action_failure(fatal_result)
        _refresh_flight_hud()
        return fatal_result
    var status := String(snapshot.get("status", "invalid_token"))
    if status not in ["not_activated", "offline_grace_expired", "invalid_token"]:
        var unavailable_result := {"ok": false, "error_type": "request", "error_code": "activation_unavailable"}
        _record_license_action_failure(unavailable_result)
        _refresh_flight_hud()
        return unavailable_result
    var entered_key := license_key
    if entered_key.is_empty() and license_key_input != null:
        entered_key = license_key_input.text
    if entered_key.is_empty():
        var missing_key_result := {"ok": false, "error_type": "request", "error_code": "license_key_required"}
        _record_license_action_failure(missing_key_result)
        _refresh_flight_hud()
        return missing_key_result
    if license_provider == null:
        var missing_provider_result := {"ok": false, "error_type": "fatal", "error_code": "not_configured"}
        _record_license_action_failure(missing_provider_result)
        _refresh_flight_hud()
        return missing_provider_result
    var result: Dictionary = await license_provider.activate(entered_key)
    if license_key_input != null:
        license_key_input.clear()
    _record_license_action_failure(result)
    _reconcile_license_after_provider_action()
    return result


func retry_license() -> Dictionary:
    var snapshot := get_license_snapshot()
    if snapshot.has("fatal"):
        var fatal_result := {"ok": false, "error_type": "fatal", "error_code": String(snapshot.fatal.code)}
        _record_license_action_failure(fatal_result)
        _refresh_flight_hud()
        return fatal_result
    var status := String(snapshot.get("status", "invalid_token"))
    if status in ["offline_grace_expired", "invalid_token"]:
        return await activate_license("")
    if status != "revoked":
        var unavailable_result := {"ok": false, "error_type": "request", "error_code": "retry_unavailable"}
        _record_license_action_failure(unavailable_result)
        _refresh_flight_hud()
        return unavailable_result
    if license_provider == null:
        var missing_provider_result := {"ok": false, "error_type": "fatal", "error_code": "not_configured"}
        _record_license_action_failure(missing_provider_result)
        _refresh_flight_hud()
        return missing_provider_result
    var result: Dictionary = await license_provider.refresh_online()
    _record_license_action_failure(result)
    _reconcile_license_after_provider_action()
    return result


func _record_license_action_failure(result: Dictionary) -> void:
    if bool(result.get("ok", false)):
        return
    last_error_message = "License %s failed: %s" % [
        String(result.get("error_type", "unknown")),
        String(result.get("error_code", "unknown")),
    ]


func _reconcile_license_after_provider_action() -> void:
    if can_start_quick_fly():
        last_error_message = ""
        show_main_menu()
    else:
        screen = "license_blocked"
        _refresh_flight_hud()


func _show_license_blocked(message: String) -> void:
    last_error_message = message
    unload_map()
    screen = "license_blocked"
    takeoff_requested = false
    _refresh_flight_hud()


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
    if not hardware_config.initialize_tuning(self):
        native = primary_native
        last_error_message = "second named vehicle tuning initialization failed"
        return false
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


func _set_replay_physics_tick(physics_tick: int = -1) -> bool:
    if _replay_recording_failed or not _replay_recording_active:
        return false
    if native == null or not native.has_method("set_replay_physics_tick"):
        _fail_replay_recording("replay physics tick hook is unavailable")
        return false
    var result: Dictionary = native.call("set_replay_physics_tick", _replay_authoritative_physics_tick if physics_tick < 0 else physics_tick)
    if not bool(result.get("ok", false)):
        _fail_replay_recording(String(result.get("diagnostic_message", "physics tick update failed")))
        return false
    return true


func _fail_replay_recording(message: String) -> void:
    if _replay_recording_failed:
        return
    _replay_recording_failed = true
    _replay_recording_failure = message
    push_error("Complete replay recording is irrecoverable: %s" % message)


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
    _replay_recording_failed = false
    _replay_recording_failure = ""
    _replay_authoritative_physics_tick = 0
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
    _replay_upper_config_manifest_hash = String(native.call("config_hash")) if native.has_method("config_hash") else ""
    _replay_lower_config_manifest_hash = String(_airsim_secondary_native.call("config_hash")) if _airsim_secondary_native.has_method("config_hash") else ""
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
    if _airsim_secondary_native.has_method("begin_replay_checkpoint_capture"):
        _airsim_secondary_native.call("begin_replay_checkpoint_capture")
    _replay_recording_active = true
    if not _set_replay_physics_tick(0) or not _record_replay_environment({}):
        _replay_recording_active = false


func _finish_complete_replay_recording(reason: String) -> Dictionary:
    if not _replay_recording_active or native == null:
        return {"ok": false, "error": "complete replay recording is inactive"}
    if _replay_recording_failed:
        _replay_recording_active = false
        return {"ok": false, "error": "complete replay recording failed", "diagnostic_message": _replay_recording_failure}
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
    if _replay_recording_failed or not _replay_recording_active or native == null:
        return
    var mode := String(controls.get("mode", "ANGLE"))
    if mode == "ASSISTED_HOLD":
        mode = "ALTITUDE_HOLD"
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
            0,
            float(controls.get("vertical_velocity_mps", 0.0)),
            bool(controls.get("heading_hold_enabled", false)),
            bool(controls.get("position_hold_enabled", false)))
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
        _fail_replay_recording(String(result.get("diagnostic_message", "command recording failed")))
        push_error("Complete replay command recording failed: %s" % String(result.get("diagnostic_message", "unknown error")))
        return
    var response_native: Object = _airsim_secondary_native if vehicle_name == String(_airsim_vehicle_names[1]) else native
    if response_native != null and response_native.has_method("capture_replay_recorded_response"):
        var non_neutral := float(controls.get("throttle", 0.0)) != 0.5
        if mode == "ACRO":
            non_neutral = non_neutral or float(controls.get("acro_roll", 0.0)) != 0.0 or \
                float(controls.get("acro_pitch", 0.0)) != 0.0 or float(controls.get("acro_yaw", 0.0)) != 0.0
        else:
            non_neutral = non_neutral or float(controls.get("roll", 0.0)) != 0.0 or \
                float(controls.get("pitch", 0.0)) != 0.0 or float(controls.get("yaw_rate", 0.0)) != 0.0
        response_native.call("capture_replay_recorded_response", non_neutral)


func _record_replay_actuator_command(vehicle_name: String, actuator_outputs: PackedFloat32Array, timestamp_us: int) -> void:
    if _replay_recording_failed or not _replay_recording_active or native == null or actuator_outputs.size() < 4:
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
        _fail_replay_recording(String(result.get("diagnostic_message", "actuator recording failed")))
        push_error("Complete replay actuator recording failed: %s" % String(result.get("diagnostic_message", "unknown error")))
        return
    if native.has_method("capture_replay_recorded_response"):
        var non_neutral := false
        for output in actuator_outputs:
            non_neutral = non_neutral or absf(float(output) - 0.5) > 0.0
        native.call("capture_replay_recorded_response", non_neutral)


func _record_replay_collision(vehicle_name: String, body, authority: int = 1, timestamp_us: int = -1) -> void:
    if _replay_recording_failed or not _replay_recording_active or native == null or body == null or not body.contact_seen:
        return
    var angular_velocity_body := _jolt_angular_velocity_body_y_up(body)
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
        angular_velocity_body.x,
        angular_velocity_body.y,
        angular_velocity_body.z,
        _kinetic(body.linear_velocity, angular_velocity_body, _airsim_secondary_native if vehicle_name != _airsim_vehicle_name else native),
        true,
        authority)
    if not bool(result.get("ok", false)):
        _fail_replay_recording(String(result.get("diagnostic_message", "collision recording failed")))
        push_error("Complete replay collision recording failed: %s" % String(result.get("diagnostic_message", "unknown error")))


func _record_replay_scene_object(operation: int, snapshot: Dictionary) -> void:
    if _replay_recording_failed or not _replay_recording_active or native == null or snapshot.is_empty():
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
        _fail_replay_recording(String(result.get("diagnostic_message", "scene recording failed")))
        push_error("Complete replay scene recording failed: %s" % String(result.get("diagnostic_message", "unknown error")))


func _record_replay_environment(state: Dictionary) -> bool:
    if _replay_recording_failed or not _replay_recording_active or native == null:
        return false
    var replay_state := state.duplicate(true)
    if native.has_method("wind_configuration"):
        replay_state["atmosphere"] = _replay_canonical_value(native.call("wind_configuration"))
    if native.has_method("replay_vehicle_config_manifest"):
        var manifest: Dictionary = native.call("replay_vehicle_config_manifest")
        var body_drag: Dictionary = manifest.get("body_drag", {})
        if body_drag.has("air_density_kg_m3"):
            replay_state["atmosphere_air_density_kg_m3"] = body_drag["air_density_kg_m3"]
    var result: Dictionary = native.call("record_replay_environment", _replay_timestamp_us(), JSON.stringify(replay_state))
    if not bool(result.get("ok", false)):
        _fail_replay_recording(String(result.get("diagnostic_message", "environment recording failed")))
        return false
    return true


func _record_replay_checkpoint(timestamp_us: int, upper_row: PackedFloat64Array) -> bool:
    if _replay_recording_failed or not _replay_recording_active or native == null or upper_row.size() < 12 or _replay_secondary_row.size() < 12:
        return false
    var result: Dictionary = native.call("record_replay_checkpoint", timestamp_us, upper_row, _replay_secondary_row, _airsim_secondary_native)
    if not bool(result.get("ok", false)):
        _fail_replay_recording(String(result.get("diagnostic_message", "checkpoint recording failed")))
        return false
    return true


func _record_replay_simulation_operation(operation: int, value: float) -> bool:
    if _replay_recording_failed or not _replay_recording_active or native == null:
        return false
    var result: Dictionary = native.call("record_replay_simulation_operation", _replay_timestamp_us(), operation, value)
    if not bool(result.get("ok", false)):
        _fail_replay_recording(String(result.get("diagnostic_message", "simulation recording failed")))
        return false
    elif operation == 4 or operation == 5:
        _replay_epoch_pending = true
    return true


func _record_replay_reset_environment() -> void:
    if environment_state != null:
        _record_replay_environment(_environment_rpc_snapshot(environment_state.snapshot()))


func _record_replay_async(simulation_time_seconds: float, vehicle_name: String, command_id: String, method: String, lifecycle: int) -> void:
    if _replay_recording_failed or not _replay_recording_active or native == null:
        return
    var timestamp_us := _replay_timestamp_for_simulation_us(int(round(simulation_time_seconds * 1_000_000.0)))
    var result: Dictionary = native.call("record_replay_async_command", timestamp_us, vehicle_name, command_id, method, lifecycle)
    if not bool(result.get("ok", false)):
        _fail_replay_recording(String(result.get("diagnostic_message", "async recording failed")))
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


func _validate_replay_world_events(events: Array) -> Dictionary:
    for event in events:
        if typeof(event) != TYPE_DICTIONARY:
            return {"ok": false, "error": "replay event is malformed"}
        match String(event.get("type", "")):
            "scene_object":
                var position_values: Variant = event.get("position", [])
                var orientation_values: Variant = event.get("orientation", [])
                var operation := String(event.get("operation", ""))
                if typeof(position_values) != TYPE_ARRAY or typeof(orientation_values) != TYPE_ARRAY or position_values.size() != 3 or orientation_values.size() != 4 or scene_object_catalog == null:
                    return {"ok": false, "error": "replay scene object transform is malformed"}
                if operation not in ["spawn", "move", "destroy", "reset"]:
                    return {"ok": false, "error": "unsupported replay scene operation"}
            "environment":
                if typeof(event.get("state", {})) != TYPE_DICTIONARY:
                    return {"ok": false, "error": "replay environment state is malformed"}
            "simulation_time":
                if String(event.get("operation", "")) not in ["pause", "resume", "step_frames", "step_seconds", "reset", "respawn"]:
                    return {"ok": false, "error": "unsupported replay simulation operation"}
    return {"ok": true}


func _apply_replay_world_events(events: Array) -> Dictionary:
    for event in events:
        match String(event.get("type", "")):
            "scene_object":
                var position_values: Array = event.get("position", [])
                var orientation_values: Array = event.get("orientation", [])
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
                else:
                    scene_object_catalog.reset()
                    world_result = {"ok": true}
                if not bool(world_result.get("ok", false)):
                    return {"ok": false, "error": String(world_result.get("error", "replay scene application failed"))}
            "environment":
                var world_environment: Dictionary = event.get("state", {}).duplicate(true)
                world_environment.erase("atmosphere")
                world_environment.erase("atmosphere_air_density_kg_m3")
                if not world_environment.is_empty():
                    var environment_result := _airsim_environment("simSetEnvironment", [world_environment])
                    if not bool(environment_result.get("ok", false)):
                        return environment_result
            "simulation_time":
                if String(event.get("operation", "")) in ["reset", "respawn"]:
                    scene_object_catalog.reset()
                    if environment_state != null:
                        _apply_environment_result(environment_state.reset())
    return {"ok": true}


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
        if typeof(vehicle.get("config", null)) != TYPE_DICTIONARY:
            return {"ok": false, "error": "replay vehicle config manifest is malformed"}
        var config: Dictionary = vehicle.get("config", {})
        if String(vehicle.get("config_manifest_hash", "")) != String(expected_vehicle_hashes[index]) or _replay_manifest_hash(_replay_canonical_json(config)) != String(expected_vehicle_hashes[index]):
            return {"ok": false, "error": "replay vehicle config manifest integrity check failed"}
    var world_validation := _validate_replay_world_events(parsed.events)
    if not bool(world_validation.get("ok", false)):
        return world_validation
    var native_result: Dictionary = native.call(
        "replay_complete_session", serialized, expected_settings_manifest_hash,
        expected_upper_config_manifest_hash, expected_lower_config_manifest_hash,
        native.call("replay_vehicle_config_manifest"),
        _airsim_secondary_native.call("replay_vehicle_config_manifest") if _airsim_secondary_native != null else {})
    if not bool(native_result.get("ok", false)):
        return native_result
    var world_result := _apply_replay_world_events(parsed.events)
    if not bool(world_result.get("ok", false)):
        return world_result
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
    var saved_language = result.document.get("language")
    var locale := LanguageProfile.DEFAULT_LOCALE
    if saved_language != null:
        var language_result: Dictionary = LanguageProfile.validate_profile(saved_language)
        if language_result.ok:
            locale = String(language_result.profile.locale)
    Localization.set_locale(locale)
    var saved_quality = result.document.get("quality")
    if saved_quality == null:
        _preview_render_scale(QualityProfile.DEFAULT_RENDER_SCALE)
    else:
        var quality_result: Dictionary = QualityProfile.validate_profile(saved_quality)
        if quality_result.ok:
            _preview_render_scale(float(quality_result.profile.render_scale))
    var saved = result.document.get("confirmed_gamepad")
    if saved != null:
        persisted_gamepad_profile = InputProfiles.GamepadProfile.from_persisted_dict(saved)
    var saved_rates = result.document.get("rates")
    if saved_rates != null:
        var rates_result: Dictionary = RatesProfile.validate_profile(saved_rates)
        if rates_result.ok:
            rates_profile = rates_result.profile
    var saved_camera = result.document.get("camera")
    if saved_camera != null:
        var camera_result: Dictionary = CameraProfile.validate_profile(saved_camera)
        if camera_result.ok:
            camera_profile = camera_result.profile
            camera_profile_persisted = true
    var saved_osd = result.document.get("osd")
    if saved_osd != null:
        var osd_result: Dictionary = OsdProfile.validate_profile(saved_osd)
        if osd_result.ok:
            osd_profile = osd_result.profile
    var saved_quick_adjust = result.document.get("quick_adjust")
    if saved_quick_adjust != null:
        var quick_adjust_result: Dictionary = InputProfiles.QuickAdjustProfile.validate_profile(saved_quick_adjust)
        if quick_adjust_result.ok:
            _quick_adjust_profile = quick_adjust_result.profile
    if not result.ok and result.recovered:
        last_error_message = "Settings recovered to factory defaults: %s" % result.error


func _restore_startup_gamepad_session() -> void:
    if controller_safety_latched or persisted_gamepad_profile == null:
        return
    var device_id := _first_connected_device()
    if not InputProfiles.GamepadProfile.is_supported_device(device_id, gamepad_device_state):
        return
    var profile := InputProfiles.GamepadProfile.from_persisted_dict(persisted_gamepad_profile.to_persisted_dict())
    if profile == null:
        return
    session_gamepad_profile = profile
    session_gamepad_device_id = device_id


func _save_gamepad_profile(profile: InputProfiles.GamepadProfile) -> Dictionary:
    var loaded: Dictionary = settings_store.load_document()
    if not loaded.ok and not (bool(loaded.get("recovered", false)) and String(loaded.get("error", "")).contains("confirmed_gamepad")):
        return {"ok": false, "error": "cannot save gamepad while settings are unavailable: %s" % loaded.error}
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


func _save_quality_profile(profile: Dictionary) -> Dictionary:
    var validation: Dictionary = QualityProfile.validate_profile(profile)
    if not validation.ok:
        return validation
    var loaded: Dictionary = settings_store.load_document()
    if not loaded.ok:
        return {"ok": false, "error": "cannot save quality while settings are unavailable: %s" % loaded.error}
    var document: Dictionary = loaded.document
    document["quality"] = validation.profile
    var result: Dictionary = settings_store.save_document(document)
    if result.ok:
        graphics_committed_scale = float(validation.profile.render_scale)
    return result


func _save_camera_profile(profile: Dictionary) -> Dictionary:
    var validation: Dictionary = CameraProfile.validate_profile(profile)
    if not validation.ok:
        return validation
    var loaded: Dictionary = settings_store.load_document()
    if not loaded.ok:
        return {"ok": false, "error": "cannot save camera while settings are unavailable: %s" % loaded.error}
    loaded.document["camera"] = validation.profile
    var result: Dictionary = settings_store.save_document(loaded.document)
    if result.ok:
        camera_profile = validation.profile
        camera_profile_persisted = true
        _apply_camera_profile()
    return result


func _apply_hardware_camera_defaults(hardware_config: RefCounted) -> void:
    if camera_profile_persisted or hardware_config == null:
        return
    var fpv: Variant = hardware_config.current.get("fpv")
    if typeof(fpv) != TYPE_DICTIONARY:
        return
    var candidate := camera_profile.duplicate(true)
    candidate["camera_angle_deg"] = fpv.get("camera_angle_deg", candidate.camera_angle_deg)
    candidate["fov_deg"] = fpv.get("fov_deg", candidate.fov_deg)
    var validation: Dictionary = CameraProfile.validate_profile(candidate)
    if validation.ok:
        camera_profile = validation.profile


func _save_osd_profile(profile: Dictionary) -> Dictionary:
    var validation: Dictionary = OsdProfile.validate_profile(profile)
    if not validation.ok:
        return validation
    var loaded: Dictionary = settings_store.load_document()
    if not loaded.ok:
        return {"ok": false, "error": "cannot save OSD while settings are unavailable: %s" % loaded.error}
    loaded.document["osd"] = validation.profile
    var result: Dictionary = settings_store.save_document(loaded.document)
    if result.ok:
        osd_profile = validation.profile
        _refresh_osd()
    return result

func _run_cold_start_probe() -> void:
    var report_path := _cold_start_report_path()
    if report_path.is_empty():
        return
    quick_fly()
    accept_fallback()
    await RenderingServer.frame_post_draw
    var frame_marker_path := _cold_start_arg("--aerosim-cold-start-frame-marker")
    if not frame_marker_path.is_empty():
        var frame_marker := FileAccess.open(frame_marker_path, FileAccess.WRITE)
        if frame_marker == null:
            push_error("Cannot write cold-start frame marker: %s" % frame_marker_path)
            get_tree().quit(1)
            return
        frame_marker.store_string(JSON.stringify({
            "stage": "frame_post_draw",
            "display_driver": DisplayServer.get_name(),
            "rendering_method": RenderingServer.get_current_rendering_method(),
            "rendering_driver": RenderingServer.get_current_rendering_driver_name(),
            "preflight_ready": native != null and screen == "preflight" and not takeoff_requested and not paused,
            "frame_post_draw": true,
            "screen": screen,
        }))
        frame_marker.close()
    var screenshot_path := _cold_start_arg("--aerosim-cold-start-screenshot")
    var screenshot := get_viewport().get_texture().get_image()
    var screenshot_written := not screenshot_path.is_empty() and screenshot.save_png(screenshot_path) == OK
    var result := {
        "display_driver": DisplayServer.get_name(),
        "rendering_method": RenderingServer.get_current_rendering_method(),
        "rendering_driver": RenderingServer.get_current_rendering_driver_name(),
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

func _has_arg(name: String) -> bool:
    return OS.get_cmdline_user_args().has(name)

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
    if event is InputEventKey:
        var key_event := event as InputEventKey
        _quick_adjust_pressed_keys[int(key_event.keycode)] = key_event.pressed
    elif event is InputEventJoypadMotion:
        var axis_event := event as InputEventJoypadMotion
        _quick_adjust_axis_values["%d:%d" % [axis_event.device, axis_event.axis]] = axis_event.axis_value
    if event is InputEventJoypadButton and _handle_gamepad_button(event):
        return
    if event.is_action_pressed("flight_takeoff") and screen in ["preflight", "flight"]:
        arm_and_takeoff()
    elif event.is_action_pressed("flight_pause") and screen == "flight":
        set_paused(not paused)
    elif event.is_action_pressed("flight_change_spawn") and screen in ["preflight", "flight", "finish"]:
        change_spawn()
    elif event.is_action_pressed("flight_respawn") and screen in ["preflight", "flight", "finish"]:
        respawn()
    elif event.is_action_pressed("flight_acro"):
        toggle_acro_mode()
    elif event.is_action_pressed("flight_altitude_hold"):
        toggle_altitude_hold()
    elif event.is_action_pressed("flight_view_toggle"):
        toggle_player_view()
    elif event.is_action_pressed("flight_exit"):
        if screen == "lab_mode":
            return_from_lab_mode()
        elif screen in ["controller_confirmation", "fallback_prompt"]:
            if controller_confirmation_panel != null:
                controller_confirmation_panel.hide()
            _cancel_controller_route()
        else:
            request_exit()

func _process(_delta: float) -> void:
    if not airsim_stop_file.is_empty() and FileAccess.file_exists(airsim_stop_file):
        get_tree().quit()
        return
    if _reset_pending_token == 0 and airsim_session != null and paused != airsim_session.is_paused():
        if not airsim_session.is_paused() and _airsim_lifecycle_stopped() and not airsim_session.is_explicit_step_active():
            airsim_session.set_paused(true)
        else:
            set_paused(airsim_session.is_paused(), false)
    _update_chase_camera()
    _refresh_controller_confirmation()
    _refresh_controller_settings()
    _refresh_flight_hud()

func _physics_process(delta: float) -> void:
    if _replay_recording_active:
        _replay_authoritative_physics_tick += 1
        if not _set_replay_physics_tick():
            return
    if _reset_pending_token != 0:
        _advance_reset_pending()
        return
    if reset_hold_frames > 0:
        reset_hold_frames -= 1
        if reset_hold_frames == 0 and drone_body != null and not paused:
            drone_body.freeze = false
            drone_body.sleeping = false
        return
    _sync_native_external_authority()
    _apply_quick_adjust_inputs(delta)
    _apply_gsp_tuning_requests(_gsp_public_physics_tick())
    if paused:
        if airsim_session != null and not airsim_session.is_paused():
            set_paused(false, false)
        if paused:
            return
    # Commands and contacts belong to this frame's native start time;
    # checkpoints use the post-step frame timestamp separately.
    var replay_timestamp_us := _replay_timestamp_us()
    var replay_frame_timestamp_us := _replay_frame_timestamp_us()
    _replay_secondary_row = PackedFloat64Array()
    var defer_airsim_advance := native != null and takeoff_requested
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
    if not defer_airsim_advance and px4_lockstep_active and not _px4_lockstep_sensor_pending:
        _publish_px4_lockstep_sensor_if_needed()
        _px4_lockstep_sensor_pending = true
    var session_advanced := true
    if not defer_airsim_advance and airsim_session != null and not px4_lockstep_active:
        session_advanced = airsim_session.advance_frame()
        if not session_advanced and airsim_session.is_paused():
            set_paused(true, false)
            return
    if not defer_airsim_advance and px4_sitl_bridge != null and not px4_lockstep_active:
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
    if takeoff_assist_active:
        if not _has_active_gamepad_profile():
            takeoff_assist_active = false
    var angle_roll := _angle_roll_degrees()
    var angle_pitch := _angle_pitch_degrees()
    var angle_yaw := _angle_yaw_rate_degrees_per_second()
    var assisted_vertical_velocity := 0.0
    if flight_mode == "ASSISTED_HOLD" and _has_active_gamepad_profile():
        if takeoff_assist_active:
            var takeoff_remaining_m := TAKEOFF_ASSIST_ALTITUDE_M - takeoff_assist_commanded_altitude_m
            if takeoff_remaining_m > 0.0 and delta > 0.0:
                assisted_vertical_velocity = minf(TAKEOFF_ASSIST_VERTICAL_SPEED_MPS, takeoff_remaining_m / delta)
                takeoff_assist_commanded_altitude_m += assisted_vertical_velocity * delta
            else:
                takeoff_assist_active = false
        elif assisted_throttle_waiting_for_neutral:
            assisted_throttle_waiting_for_neutral = absf(_profile_throttle_raw()) > InputProfiles.GamepadProfile.THROTTLE_LOW_THRESHOLD
        else:
            assisted_vertical_velocity = _profile_axis("throttle") * ASSISTED_MAX_VERTICAL_SPEED_MPS
    if flight_mode == "ASSISTED_HOLD":
        throttle = assisted_hover_throttle
        var assisted_horizontal_angles := _assisted_hold_horizontal_angles()
        angle_roll = assisted_horizontal_angles.x
        angle_pitch = assisted_horizontal_angles.y
        angle_yaw = _profile_axis("yaw") * ASSISTED_MAX_YAW_RATE_DPS if _has_active_gamepad_profile() else 0.0
    else:
        assisted_horizontal_intent_active = false
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
            if not _sync_native_from_drone():
                return
        var angular_velocity_body := _jolt_angular_velocity_body_y_up(drone_body) if drone_body != null else Vector3.ZERO
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
            angular_velocity_body.x,
            angular_velocity_body.y,
            angular_velocity_body.z,
            _pre_impact_energy(drone_body) if drone_body != null else -1.0
        )
        if _handle_native_step_failure(native, row, true):
            return
    elif drone_body != null:
        if not _sync_native_from_drone():
            return
        var angular_velocity_body := _jolt_angular_velocity_body_y_up(drone_body)
        var energy_limit := _pre_impact_energy(drone_body)
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
                angular_velocity_body.x,
                angular_velocity_body.y,
                angular_velocity_body.z,
                energy_limit
            )
        else:
            var step_method := "step_collision_altitude_hold_mode" if flight_mode in ["ALTITUDE_HOLD", "ASSISTED_HOLD"] else "step_collision_angle_mode"
            var step_args := [
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
                angular_velocity_body.x,
                angular_velocity_body.y,
                angular_velocity_body.z,
                energy_limit
            ]
            if flight_mode == "ASSISTED_HOLD":
                step_args.append(assisted_vertical_velocity)
                step_args.append(true)
                step_args.append(true)
            row = native.callv(step_args[0], step_args.slice(1))
        if _handle_native_step_failure(native, row, true):
            return
    else:
        if flight_mode == "ACRO":
            row = native.call("step_acro_mode", Engine.physics_ticks_per_second, 1000, throttle, acro_roll, acro_pitch, acro_yaw, _acro_rate("rc_rate"), _acro_rate("super_rate"), _acro_rate("expo"))
        else:
            var free_flight_method := "step_altitude_hold_mode" if flight_mode in ["ALTITUDE_HOLD", "ASSISTED_HOLD"] else "step_angle_mode"
            var free_flight_args := [Engine.physics_ticks_per_second, 1000, throttle, angle_roll, angle_pitch, angle_yaw]
            if flight_mode == "ASSISTED_HOLD":
                free_flight_args.append(assisted_vertical_velocity)
                free_flight_args.append(true)
                free_flight_args.append(true)
            row = native.callv(free_flight_method, free_flight_args)
        if _handle_native_step_failure(native, row, true):
            return
    if _airsim_secondary_native != null and secondary_drone_body != null and (airsim_session == null or not airsim_session.is_paused()):
        _step_secondary_airsim_vehicle(String(_airsim_vehicle_names[1]), replay_timestamp_us)
        if paused:
            return
    if not _refresh_native_imu_sample(native):
        return
    if px4_sitl_bridge != null:
        _record_replay_actuator_command(_airsim_vehicle_name, px4_sitl_bridge.actuator_outputs(), replay_timestamp_us)
    if drone_body != null and drone_body.contact_seen:
        _record_replay_collision(_airsim_vehicle_name, drone_body, int(row[12]) if row.size() >= 13 else 0, replay_timestamp_us)
        collision_handoff_count += 1
        _airsim_contact_this_frame = true
        _airsim_collision_seen = true
        _airsim_collision_normal = drone_body.contact_normal
        _airsim_collision_point = drone_body.global_position
        if flight_mode == "ASSISTED_HOLD" and assisted_vertical_velocity < -0.05 and absf(drone_body.linear_velocity.y) <= 0.25:
            native.call("disarm_flight_control")
            _airsim_disarm_requested = true
            takeoff_requested = false
            drone_body.freeze = true
            drone_body.sleeping = true
        drone_body.reset_contact()
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
            "vertical_velocity_mps": assisted_vertical_velocity,
            "heading_hold_enabled": flight_mode == "ASSISTED_HOLD",
            "position_hold_enabled": flight_mode == "ASSISTED_HOLD",
        }, replay_timestamp_us)
    if row.size() >= 13:
        last_collision_authority = int(row[12])
    if drone_body != null and row.size() >= 17:
        _record_replay_checkpoint(replay_frame_timestamp_us, row)
        drone_body.freeze = false
        drone_body.sleeping = false
        drone_body.apply_native_state(
            Vector3(row[1], row[2], row[3]),
            Quaternion(row[4], row[5], row[6], row[7]),
            Vector3(row[8], row[9], row[10]),
            Vector3(row[14], row[15], row[16])
        )
    if defer_airsim_advance and airsim_session != null and not px4_lockstep_active:
        session_advanced = airsim_session.advance_frame()
        if not session_advanced and airsim_session.is_paused():
            set_paused(true, false)
            return
    if defer_airsim_advance and px4_sitl_bridge != null and not px4_lockstep_active:
        px4_sitl_bridge.publish_sensor_snapshot(_airsim_state(_airsim_vehicle_name).get("state", {}), airsim_session.simulation_time_seconds if airsim_session != null else 0.0)
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
    if _airsim_secondary_native.has_method("flight_control_armed") and not bool(_airsim_secondary_native.call("flight_control_armed")) and not bool(_airsim_secondary_native.call("arm_flight_control", 0.0)):
        push_error("Secondary AirSim vehicle could not arm: %s" % String(_airsim_secondary_native.call("flight_control_arm_reject_code")))
        return
    if not _sync_named_native(body, _airsim_secondary_native):
        return
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
    var angular_velocity_body := _jolt_angular_velocity_body_y_up(body)
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
            angular_velocity_body.x,
            angular_velocity_body.y,
            angular_velocity_body.z,
            _pre_impact_energy(body, _airsim_secondary_native))
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
            angular_velocity_body.x,
            angular_velocity_body.y,
            angular_velocity_body.z,
            _pre_impact_energy(body, _airsim_secondary_native))
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
            angular_velocity_body.x,
            angular_velocity_body.y,
            angular_velocity_body.z,
            _pre_impact_energy(body, _airsim_secondary_native))
    if _handle_native_step_failure(_airsim_secondary_native, row, true):
        return
    if not _refresh_native_imu_sample(_airsim_secondary_native):
        return
    _record_replay_command(vehicle_name, controls, replay_timestamp_us)
    if row.size() >= 17:
        body.freeze = false
        body.sleeping = false
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
func _airsim_secondary_controls(context: Dictionary, body) -> Dictionary:
    var command_state: Dictionary = context.get("command_state", {})
    if command_state.is_empty():
        return context.get("hold_controls", _airsim_neutral_controls()).duplicate(true)
    var method := String(command_state.get("method", ""))
    var args: Array = command_state.get("args", [])
    var altitude_m := _airsim_altitude_above_origin(body)
    match method:
        "takeoff":
            return _airsim_velocity_controls(Vector3(0.0, clampf((AIRSIM_TAKEOFF_ALTITUDE_M - altitude_m) * 1.5, -3.0, 3.0), 0.0), 0.0, null, body)
        "land":
            return _airsim_velocity_controls(Vector3(0.0, clampf(-altitude_m * 1.5, -3.0, 3.0), 0.0), 0.0, null, body)
        "hover":
            return _airsim_velocity_controls(Vector3.ZERO, 0.0, null, body)
        "moveByVelocity":
            return _airsim_velocity_controls(AirSimCoordinateContract.ned_direction_to_godot(Vector3(float(args[0]), float(args[1]), float(args[2]))), 0.0, args[5], body)
        "moveByVelocityZ":
            return _airsim_velocity_controls(AirSimCoordinateContract.ned_direction_to_godot(Vector3(float(args[0]), float(args[1]), 0.0)), (-float(args[2]) - altitude_m) * 4.0, args[5], body)
        "moveByVelocityBodyFrame":
            return _airsim_velocity_controls(body.global_transform.basis * AirSimCoordinateContract.frd_to_godot_body(Vector3(float(args[0]), float(args[1]), float(args[2]))), 0.0, args[5], body)
        "moveByVelocityZBodyFrame":
            return _airsim_velocity_controls(body.global_transform.basis * AirSimCoordinateContract.frd_to_godot_body(Vector3(float(args[0]), float(args[1]), 0.0)), (-float(args[2]) - altitude_m) * 4.0, args[5], body)
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
            rotate_to_controls["yaw_rate"] = clampf(-rad_to_deg(delta_yaw) * 3.0, -ANGLE_MAX_YAW_RATE_DPS, ANGLE_MAX_YAW_RATE_DPS)
            return rotate_to_controls
        "rotateByYawRate":
            var rotate_rate_controls := _airsim_velocity_controls(Vector3.ZERO, 0.0, null, body)
            rotate_rate_controls["yaw_rate"] = clampf(float(args[0]), -ANGLE_MAX_YAW_RATE_DPS, ANGLE_MAX_YAW_RATE_DPS)
            return rotate_rate_controls
        "moveByAngleRatesThrottle":
            return {"mode": "ACRO", "throttle": float(args[3]), "acro_roll": _airsim_rate_stick(rad_to_deg(float(args[0])), _airsim_secondary_native), "acro_pitch": _airsim_rate_stick(rad_to_deg(float(args[1])), _airsim_secondary_native), "acro_yaw": _airsim_rate_stick(rad_to_deg(float(args[2])), _airsim_secondary_native)}
    return _airsim_neutral_controls()


func _sync_named_native(body: Object, target_native: Object) -> bool:
    var q: Quaternion = body.global_transform.basis.get_rotation_quaternion()
    var angular_velocity_body := _jolt_angular_velocity_body_y_up(body)
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
        angular_velocity_body.x,
        angular_velocity_body.y,
        angular_velocity_body.z)
    return not _handle_native_step_failure(target_native)


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
    if _reset_pending_token != 0:
        last_error_message = "Arm blocked: reset_pending"
        _refresh_flight_hud()
        return
    reset_hold_frames = 0
    # A direct AirSim-style takeoff may arrive after the caller has already
    # armed native control.  Reset publication deliberately disarms the
    # runtime, so preserve that pre-transaction intent for the single
    # post-ACK rearm.  arm_and_takeoff() sets this flag explicitly before
    # reaching here when native control is not armed yet.
    _reset_arm_after_commit = _reset_arm_after_commit or _flight_control_armed()
    _reset_after_commit_takeoff = true
    if not reset_to_spawn():
        _reset_after_commit_takeoff = false
        _reset_arm_after_commit = false
        screen = "error"
        _refresh_flight_hud()
    return


func _complete_takeoff_after_reset() -> void:
    if _reset_arm_after_commit:
        _reset_arm_after_commit = false
        if px4_sitl_bridge != null:
            var px4_arm_result := px4_sitl_bridge.arm_disarm(true)
            if not px4_arm_result.ok:
                _fail_reset_pending("PX4 arm failed: %s" % px4_arm_result.error)
                return
        elif native != null and not native.call("arm_flight_control", 0.0):
            _fail_reset_pending("Quick Fly cannot arm: %s" % native.call("flight_control_arm_reject_code"))
            return
        _airsim_disarm_requested = false
    screen = "flight"
    set_dashboard_layout_mode("compact")
    flight_mode = "ANGLE"
    set_paused(false)
    takeoff_requested = true
    takeoff_assist_active = false
    takeoff_assist_commanded_altitude_m = 0.0
    assisted_throttle_waiting_for_neutral = false
    assisted_horizontal_intent_active = false
    update_fallback_status()
    assisted_hover_throttle = _configured_hover_throttle()
    takeoff_assist_active = _has_active_gamepad_profile() and assisted_hover_throttle > 0.0
    if drone_body != null:
        drone_body.freeze = reset_hold_frames > 0
        drone_body.sleeping = reset_hold_frames > 0
        if takeoff_assist_active:
            flight_mode = "ASSISTED_HOLD"
            assisted_throttle_waiting_for_neutral = true
    if time_trial != null:
        # Reset publication already reset trial state as part of the ACKed
        # transaction.  Starting it must not publish a second reset.
        time_trial.start(false)
    _refresh_flight_hud()

func arm_and_takeoff() -> void:
    if _reset_pending_token != 0:
        last_error_message = "Arm blocked: reset_pending"
        _refresh_flight_hud()
        return
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
    _reset_arm_after_commit = true
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


func default_flight_setup() -> Dictionary:
    return {
        "hardware_preset": DEFAULT_HARDWARE_PRESET,
        "map_id": DEFAULT_FREE_FLIGHT_MAP_ID,
        "mode": DEFAULT_FLIGHT_MODE,
        "wind_preset": DEFAULT_WIND_PRESET,
    }


func apply_flight_setup(raw_setup: Dictionary) -> bool:
    var candidate := default_flight_setup()
    for key in raw_setup:
        if not candidate.has(key):
            return false
    candidate.merge(raw_setup, true)
    if String(candidate.get("hardware_preset", "")) != DEFAULT_HARDWARE_PRESET:
        return false
    if String(candidate.get("map_id", "")) != DEFAULT_FREE_FLIGHT_MAP_ID:
        return false
    if String(candidate.get("mode", "")) != DEFAULT_FLIGHT_MODE:
        return false
    var wind_preset := String(candidate.get("wind_preset", ""))
    if not WIND_PRESETS.has(wind_preset):
        return false
    if native != null:
        var hardware_config := HardwareConfig.new()
        if not hardware_config.apply_to_runtime(self, String(candidate.hardware_preset)):
            last_error_message = hardware_config.last_error
            return false
        motor_hud_spin_directions = hardware_config.current.get("spin_direction", [])
        _apply_hardware_camera_defaults(hardware_config)
    flight_setup = candidate
    flight_mode = String(candidate.mode)
    select_map(String(candidate.map_id), wind_preset)
    return true


func open_flight_setup(focus: String) -> void:
    if focus not in ["drone", "map"]:
        return
    flight_setup_focus = focus
    if flight_setup.is_empty():
        flight_setup = default_flight_setup()
    screen = "flight_setup"
    if flight_setup_panel == null and main_menu_layer != null:
        _build_flight_setup_panel()
    _refresh_flight_hud()
    var focus_button: Button = null
    if flight_setup_panel != null:
        focus_button = flight_setup_panel.get_node_or_null("Rows/%s" % focus.capitalize()) as Button
    if focus_button != null and focus_button.is_inside_tree():
        focus_button.grab_focus()


func _set_flight_setup_wind(preset: String) -> void:
    if not WIND_PRESETS.has(preset):
        return
    if flight_setup.is_empty():
        flight_setup = default_flight_setup()
    flight_setup["wind_preset"] = preset
    _refresh_flight_setup_panel()


func _fly_from_flight_setup() -> void:
    if not can_start_quick_fly():
        _show_license_blocked("Flight Setup unavailable: license %s" % String(get_license_snapshot().get("status", "invalid_token")))
        return
    if not apply_flight_setup(flight_setup):
        last_error_message = "Flight Setup contains an unsupported selection"
        screen = "error"
        _refresh_flight_hud()
        return
    enter_preflight()


func quick_fly() -> void:
    if not can_start_quick_fly():
        if screen != "license_blocked":
            _show_license_blocked("Quick Fly unavailable: license %s" % String(get_license_snapshot().get("status", "invalid_token")))
        return
    if not apply_flight_setup(default_flight_setup()):
        screen = "error"
        _refresh_flight_hud()
        return
    third_person_view = true
    _quick_fly_route_pending = true
    if drone_body != null and drone_body.is_inside_tree():
        enter_preflight()
        if screen == "error":
            _quick_fly_route_pending = false
            return
        if _reset_pending_token != 0:
            return
    _route_quick_fly_after_reset()


func _route_quick_fly_after_reset() -> void:
    _quick_fly_route_pending = false
    controller_return_screen = "preflight"
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
            screen = "preflight"
            _refresh_flight_hud()
            return
        controller_return_screen = "preflight"
        begin_controller_confirmation(device_id)
        return
    if _reset_pending_token == 0:
        screen = "preflight"
    _refresh_flight_hud()

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
    var confirm_button := controller_confirmation_panel.get_node_or_null("Rows/UseXboxDefaultProfile") as Button
    if confirm_button != null and confirm_button.is_inside_tree():
        confirm_button.grab_focus()


func open_controller_from_menu() -> void:
    controller_return_screen = "main_menu"
    begin_controller_confirmation()


func _complete_controller_route() -> void:
    var target := controller_return_screen
    controller_return_screen = "preflight"
    if target == "preflight":
        if not can_start_quick_fly():
            _show_license_blocked("Quick Fly unavailable: license %s" % String(get_license_snapshot().get("status", "invalid_token")))
            return
        if loaded_map != null and loaded_map_id == String(flight_setup.get("map_id", DEFAULT_FREE_FLIGHT_MAP_ID)) and _reset_pending_token == 0:
            screen = "preflight"
            _refresh_flight_hud()
        else:
            enter_preflight()
    elif target == "controller_settings":
        show_controller_settings()
    else:
        show_main_menu()


func _cancel_controller_route() -> void:
    var target := controller_return_screen
    controller_return_screen = "preflight"
    if target == "controller_settings":
        show_controller_settings()
    else:
        if target == "preflight":
            _deactivate_preloaded_flight_map()
        show_main_menu()


func _deactivate_preloaded_flight_map() -> void:
    takeoff_requested = false
    reset_hold_frames = 0
    _reset_airsim_flight_state()
    if drone_body != null:
        drone_body.reset_contact()
    set_paused(true)

func accept_controller_confirmation() -> void:
    var profile := InputProfiles.GamepadProfile.xbox_default(controller_confirmation_device_id, gamepad_device_state)
    if profile == null:
        session_gamepad_profile = null
        session_gamepad_device_id = -1
        _show_keyboard_fallback("Unsupported controller; Xbox default profile is unavailable. KeyboardProfile fallback active (non-sim control)")
        return
    var save_result := _save_gamepad_profile(profile)
    if not save_result.ok:
        unload_map()
        last_error_message = "Controller profile was not persisted"
        screen = "error"
        _refresh_flight_hud()
        return
    session_gamepad_profile = profile
    session_gamepad_device_id = controller_confirmation_device_id
    controller_confirmation_panel.hide()
    _complete_controller_route()

func use_keyboard_fallback() -> void:
    session_gamepad_profile = null
    session_gamepad_device_id = -1
    gamepad_pause_pressed = false
    keyboard_fallback_explicitly_selected = false
    if controller_confirmation_panel != null:
        controller_confirmation_panel.hide()
    _show_keyboard_fallback("KeyboardProfile fallback selected (non-sim control)")

func _show_keyboard_fallback(message: String) -> void:
    keyboard_fallback_explicitly_selected = false
    last_error_message = message
    screen = "fallback_prompt"
    _refresh_flight_hud()
    if arm_takeoff_button != null and arm_takeoff_button.is_inside_tree():
        arm_takeoff_button.grab_focus()

func accept_fallback() -> void:
    if screen == "fallback_prompt":
        keyboard_fallback_explicitly_selected = true
        controller_safety_latched = false
        controller_reconnected = false
        disconnected_gamepad_device_id = -1
        _complete_controller_route()
        return
    last_error_message = "No fallback prompt is active"
    screen = "error"
    _refresh_flight_hud()

func enter_preflight() -> void:
    var map_id := String(flight_setup.get("map_id", DEFAULT_FREE_FLIGHT_MAP_ID))
    if loaded_map_id == map_id and loaded_map != null:
        if not reset_to_spawn():
            screen = "error"
            _refresh_flight_hud()
            return
    else:
        if not load_map(map_id) or not reset_to_spawn():
            screen = "error"
            _refresh_flight_hud()
            return
    if _reset_pending_token == 0:
        screen = "preflight"
    set_dashboard_layout_mode("compact")
    exit_requested = false
    flight_mode = "ANGLE"
    takeoff_requested = false
    if _reset_pending_token == 0:
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
        var wind_config := {
            "preset": wind_preset,
            "steady_wind": scene_steady_wind_mps,
        }
        native.call("configure_wind", wind_config)
        if _airsim_secondary_native != null:
            _airsim_secondary_native.call("configure_wind", wind_config)

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
        button.text = _t("ui.wind.%s" % preset)
        button.pressed.connect(select_map.bind(DEFAULT_FREE_FLIGHT_MAP_ID, preset))
        presets.add_child(button)
    var environment_controls := VBoxContainer.new()
    environment_controls.name = "EnvironmentControls"
    environment_controls.position = Vector2(240.0, 0.0)
    layer.add_child(environment_controls)
    _add_environment_slider(environment_controls, "ui.map.rain", "rain", 0.0, 1.0, 0.05)
    _add_environment_slider(environment_controls, "ui.map.fog", "fog", 0.0, 1.0, 0.05)
    _add_environment_slider(environment_controls, "ui.map.time_of_day", "time_of_day", 0.0, 23.99, 0.25)


func _add_environment_slider(parent: VBoxContainer, label_key: String, key: String, minimum: float, maximum: float, step: float) -> void:
    if environment_state == null:
        return
    var label := Label.new()
    label.name = key
    label.text = _t(label_key)
    parent.add_child(label)
    var slider := HSlider.new()
    slider.name = key.capitalize()
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

func _begin_rpc_reset() -> Dictionary:
    if _reset_publication_blocked:
        return {"ok": false, "error": "reset_failed"}
    if _reset_pending_token != 0:
        if _rpc_reset_owned_generation == _reset_pending_token:
            return {"ok": true, "generation": _reset_pending_token}
        return {"ok": false, "error": "reset_pending"}
    # AirSim reset is a disarming lifecycle reset, not the local Quick Fly
    # respawn action (which can preserve an armed takeoff intent).
    _reset_after_commit_takeoff = false
    _reset_arm_after_commit = false
    var generation := _reset_generation + 1
    # `reset_to_spawn` can commit synchronously when no body needs a physics
    # ACK. Pass ownership in before it can run that completion path.
    if not reset_to_spawn(true):
        return {"ok": false, "error": last_error_message if not last_error_message.is_empty() else "reset rejected"}
    if generation != _reset_last_committed_generation and generation != _rpc_reset_owned_generation:
        return {"ok": false, "error": "reset did not create a pending generation"}
    return {"ok": true, "generation": generation}


func _rpc_reset_status(generation: int) -> Dictionary:
    if generation == _reset_last_committed_generation:
        return {"state": "committed"}
    if generation == _reset_last_failed_generation:
        return {"state": "failed", "error": last_error_message if not last_error_message.is_empty() else "reset_failed"}
    if generation == _reset_pending_token and generation == _rpc_reset_owned_generation:
        return {"state": "pending"}
    return {"state": "failed", "error": "reset generation is no longer active"}


func _abort_rpc_reset(generation: int, reason: String) -> void:
    if generation == _reset_pending_token and generation == _rpc_reset_owned_generation:
        _fail_reset_pending(reason)


func respawn() -> bool:
    if controller_safety_latched:
        last_error_message = "Respawn blocked: controller_resume_required"
        _refresh_flight_hud()
        return false
    if _reset_pending_token != 0:
        return false
    var was_armed := _flight_control_armed()
    reset_count += 1
    # Keep the ACKed spawn pose stable for one quarter second before the
    # resumed flight loop can unfreeze it.
    reset_hold_frames = maxi(1, Engine.physics_ticks_per_second / 4)
    _reset_after_commit_takeoff = true
    _reset_arm_after_commit = was_armed
    if not reset_to_spawn():
        reset_hold_frames = 0
        _reset_after_commit_takeoff = false
        _reset_arm_after_commit = false
        return false
    return true

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


func change_spawn() -> void:
    var spawn_names := _spawn_names_for_loaded_map()
    if spawn_names.size() > 1:
        current_spawn_index = (current_spawn_index + 1) % spawn_names.size()
    respawn()

func load_map(map_id: String) -> bool:
    var maps := FreeFlightMap.new()
    var descriptor: Dictionary = maps.load_descriptor(map_id)
    if not maps.last_ok:
        return _set_map_error("Cannot load Free Flight map %s: %s" % [map_id, maps.last_error])
    var scene_path := str(_map_scene_paths.get(map_id, ""))
    if scene_path.is_empty() or not ResourceLoader.exists(scene_path):
        return _set_map_error("Cannot load Free Flight map %s: scene is unavailable" % map_id)
    var scene := load(scene_path) as PackedScene
    if scene == null:
        return _set_map_error("Cannot load Free Flight map %s: scene failed to load" % map_id)
    var map_root := scene.instantiate() as Node3D
    if map_root == null:
        return _set_map_error("Cannot load Free Flight map %s: scene root must be Node3D" % map_id)
    if map_id == "terrain3d_range":
        var environment := map_root.get_node_or_null("AeroSimEnvironment") as WorldEnvironment
        if environment == null or environment.environment == null:
            return _set_map_error("Cannot load Free Flight map terrain3d_range: required AeroSimEnvironment is missing")
    unload_map()
    map_root.name = "LoadedMap"
    add_child(map_root)
    loaded_map = map_root
    loaded_map_id = map_id
    loaded_map_wind_preset = str(descriptor.wind_preset)
    loaded_spawn_names.clear()
    for spawn in descriptor.spawns:
        loaded_spawn_names.append(String(spawn.name))
    current_spawn_index = 0
    _refresh_loaded_map_localization()
    if native != null:
        var applied_wind_preset := selected_wind_preset if not selected_wind_preset.is_empty() else str(descriptor.wind_preset)
        var wind_config := {
            "preset": applied_wind_preset,
            "steady_wind": scene_steady_wind_mps,
        }
        native.call("configure_wind", wind_config)
        if _airsim_secondary_native != null:
            _airsim_secondary_native.call("configure_wind", wind_config)
    _configure_time_trial(map_root)
    return true

func reset_to_spawn(rpc_owned_reset: bool = false) -> bool:
    if loaded_map == null:
        return _set_map_error("Cannot reset Free Flight: no map is loaded")
    var spawn := _current_spawn_marker()
    if spawn == null:
        return _set_map_error("Cannot reset Free Flight map %s: configured spawn is missing" % loaded_map_id)
    if _reset_pending_token != 0:
        return true
    _reset_generation += 1
    _reset_pending_token = _reset_generation
    if rpc_owned_reset:
        _rpc_reset_owned_generation = _reset_pending_token
    _reset_pending_frames = 0
    _reset_publication_blocked = false
    _reset_pending_spawn = spawn.global_position
    _reset_pending_secondary_spawn = spawn.global_position + Vector3(1.0, 0.0, 0.0)
    _reset_pending_primary_ack_required = drone_body != null and drone_body.has_method("queue_reset_state")
    _reset_pending_secondary_ack_required = _airsim_secondary_native != null and secondary_drone_body != null and secondary_drone_body.has_method("queue_reset_state")
    screen = "reset_pending"
    takeoff_requested = false
    takeoff_assist_active = false
    assisted_throttle_waiting_for_neutral = false
    # Quiesce private simulation/body state while retaining the public AirSim
    # session until the ACKed reset publication commits.
    set_paused(true, false)
    _reset_environment_snapshot = environment_state.snapshot() if environment_state != null else {}
    if drone_body != null:
        if drone_body is RigidBody3D:
            _reset_primary_gravity_scale = drone_body.gravity_scale
            drone_body.gravity_scale = 0.0
        drone_body.freeze = false
        drone_body.sleeping = false
        if _reset_pending_primary_ack_required:
            drone_body.call("queue_reset_state", _reset_pending_spawn, spawn.global_transform.basis.get_rotation_quaternion(), _reset_pending_token)
        else:
            drone_body.apply_native_state(_reset_pending_spawn, spawn.global_transform.basis.get_rotation_quaternion(), Vector3.ZERO, Vector3.ZERO)
    if _airsim_secondary_native != null and secondary_drone_body != null:
        if secondary_drone_body is RigidBody3D:
            _reset_secondary_gravity_scale = secondary_drone_body.gravity_scale
            secondary_drone_body.gravity_scale = 0.0
        secondary_drone_body.freeze = false
        secondary_drone_body.sleeping = false
        if _reset_pending_secondary_ack_required:
            secondary_drone_body.call("queue_reset_state", _reset_pending_secondary_spawn, spawn.global_transform.basis.get_rotation_quaternion(), _reset_pending_token)
        else:
            secondary_drone_body.apply_native_state(_reset_pending_secondary_spawn, spawn.global_transform.basis.get_rotation_quaternion(), Vector3.ZERO, Vector3.ZERO)
    if not _reset_pending_primary_ack_required and not _reset_pending_secondary_ack_required:
        _advance_reset_pending()
    return true


func _commit_reset_publication() -> Dictionary:
    # Do not reset native/IMU/collision state until every physics body has ACKed
    # its queued pose.  That makes the pose and all published flight state one
    # transaction from an AirSim consumer's perspective.
    if native != null:
        native.call("reset_flight")
    if _airsim_secondary_native != null:
        _airsim_secondary_native.call("reset_flight")
    var rpc_owned_reset := _rpc_reset_owned_generation == _reset_pending_token
    # The deferred RPC server publishes its control latches with the public
    # session/replay reset immediately before replying.  Do not expose those
    # latches early from this private physics commit.
    _reset_airsim_flight_state(false, false, not rpc_owned_reset)
    if drone_body != null:
        drone_body.reset_contact()
    if secondary_drone_body != null:
        secondary_drone_body.reset_contact()
    if environment_state != null:
        _reset_commit_in_progress = true
        var reset_environment := _apply_environment_result(environment_state.reset())
        if not reset_environment.ok:
            _apply_environment_result(environment_state.apply(_reset_environment_snapshot))
            _reset_commit_in_progress = false
            return {"ok": false, "error": String(reset_environment.error)}
        var baseline_preset := selected_wind_preset if not selected_wind_preset.is_empty() else loaded_map_wind_preset
        var baseline_environment := _apply_environment_result(environment_state.apply({
            "wind_preset": baseline_preset,
            "steady_wind": scene_steady_wind_mps,
        }))
        if not baseline_environment.ok:
            _apply_environment_result(environment_state.apply(_reset_environment_snapshot))
            _reset_commit_in_progress = false
            return {"ok": false, "error": String(baseline_environment.error)}
        _reset_commit_in_progress = false
    _airsim_last_velocity = Vector3.ZERO
    _airsim_linear_acceleration = Vector3.ZERO
    _airsim_last_body_angular_velocity = Vector3.ZERO
    _airsim_angular_acceleration = Vector3.ZERO
    if time_trial != null:
        time_trial.reset()
    if scene_object_catalog != null:
        scene_object_catalog.reset()
    if _airsim_secondary_native != null and secondary_drone_body != null:
        _set_secondary_collision_enabled(_airsim_vehicle_names.size() > 1)
    if not rpc_owned_reset:
        _record_replay_simulation_operation(5, 0.0)
    if environment_state != null and not rpc_owned_reset:
        _record_replay_environment(_environment_rpc_snapshot(environment_state.snapshot()))
    _reset_environment_snapshot.clear()
    _reset_publication_blocked = false
    return {"ok": true}


func _reset_body_committed(body, target: Vector3, token: int, requires_ack: bool) -> bool:
    if body == null:
        return not requires_ack
    if requires_ack and not bool(body.call("reset_acknowledged", token)):
        return false
    return body.global_position.distance_to(target) <= 0.000001 and body.linear_velocity.length_squared() <= 0.000000000001 and body.angular_velocity.length_squared() <= 0.000000000001


func _advance_reset_pending() -> void:
    if _reset_pending_token == 0:
        return
    _reset_pending_frames += 1
    var primary_committed := _reset_body_committed(drone_body, _reset_pending_spawn, _reset_pending_token, _reset_pending_primary_ack_required)
    var secondary_required := _airsim_secondary_native != null and secondary_drone_body != null
    var secondary_committed := not secondary_required or _reset_body_committed(secondary_drone_body, _reset_pending_secondary_spawn, _reset_pending_token, _reset_pending_secondary_ack_required)
    if primary_committed and secondary_committed:
        if drone_body != null:
            drone_body.freeze = true
            drone_body.sleeping = true
            if drone_body is RigidBody3D:
                drone_body.gravity_scale = _reset_primary_gravity_scale
        if secondary_drone_body != null:
            secondary_drone_body.freeze = true
            secondary_drone_body.sleeping = true
            if secondary_drone_body is RigidBody3D:
                secondary_drone_body.gravity_scale = _reset_secondary_gravity_scale
        var publication_result := _commit_reset_publication()
        if not publication_result.ok:
            _fail_reset_pending(String(publication_result.error))
            return
        var committed_generation := _reset_pending_token
        var rpc_owned_reset := _rpc_reset_owned_generation == committed_generation
        _reset_pending_token = 0
        _reset_pending_frames = 0
        if not rpc_owned_reset:
            _advance_airsim_sensors()
        if _reset_after_commit_takeoff:
            _reset_after_commit_takeoff = false
            _complete_takeoff_after_reset()
            if screen == "error":
                return
        elif _quick_fly_route_pending:
            set_paused(false)
            _route_quick_fly_after_reset()
        else:
            set_paused(false, not rpc_owned_reset)
            screen = "preflight"
        _reset_last_committed_generation = committed_generation
        if _rpc_reset_owned_generation == committed_generation:
            _rpc_reset_owned_generation = 0
        if not _airsim_ready_file_pending.is_empty():
            _write_airsim_ready_marker(_airsim_ready_file_pending)
            _airsim_ready_file_pending = ""
        _update_chase_camera()
        _refresh_flight_hud()
        return
    if _reset_pending_frames > 8:
        _fail_reset_pending("Reset commit acknowledgement timed out")


func _fail_reset_pending(message: String) -> void:
    var failed_generation := _reset_pending_token
    if failed_generation == 0 and _rpc_reset_owned_generation != 0:
        failed_generation = _rpc_reset_owned_generation
    var rpc_owned_reset := _rpc_reset_owned_generation == failed_generation
    _reset_pending_token = 0
    reset_hold_frames = 0
    _reset_after_commit_takeoff = false
    _reset_arm_after_commit = false
    _reset_last_failed_generation = failed_generation
    if _rpc_reset_owned_generation == failed_generation:
        _rpc_reset_owned_generation = 0
    _quick_fly_route_pending = false
    takeoff_requested = false
    takeoff_assist_active = false
    assisted_throttle_waiting_for_neutral = false
    last_error_message = message
    screen = "error"
    set_paused(true, not rpc_owned_reset)
    _reset_publication_blocked = true
    if drone_body is RigidBody3D:
        drone_body.gravity_scale = _reset_primary_gravity_scale
    if drone_body != null:
        drone_body.freeze = true
        drone_body.sleeping = true
    if secondary_drone_body is RigidBody3D:
        secondary_drone_body.gravity_scale = _reset_secondary_gravity_scale
    if secondary_drone_body != null:
        secondary_drone_body.freeze = true
        secondary_drone_body.sleeping = true
    _reset_environment_snapshot.clear()
    _reset_commit_in_progress = false
    _refresh_flight_hud()


func _reset_publication_error() -> String:
    if _reset_pending_token != 0:
        return "reset_pending"
    if _reset_publication_blocked:
        return "reset_failed"
    return ""

func _reset_secondary_kinematic_contexts() -> void:
    for name in _airsim_vehicle_contexts:
        var context: Dictionary = _airsim_vehicle_contexts[name]
        context["last_velocity"] = Vector3.ZERO
        context["linear_acceleration"] = Vector3.ZERO
        context["last_body_angular_velocity"] = Vector3.ZERO
        context["angular_acceleration"] = Vector3.ZERO
        _airsim_vehicle_contexts[name] = context

## Height of a vehicle above the AirSim origin, in metres.
##
## AirSim addresses altitude as NED z relative to the spawn origin, which is
## what `_airsim_task_complete` and the landed-state reporting already measure.
## The vertical velocity commands must resolve their targets in that same frame:
## reading `global_position.y` directly only agrees with it while the spawn
## happens to sit at world height zero, and silently commands a descent on any
## map whose spawn is above it.
func _airsim_altitude_above_origin(body) -> float:
    if body == null:
        return 0.0
    return body.global_position.y - _spawn_position().y


func _spawn_position() -> Vector3:
    var spawn := _current_spawn_marker()
    if spawn != null:
        return spawn.global_position
    return SPAWN_POSITION

func _spawn_names_for_loaded_map() -> Array[String]:
    if not loaded_spawn_names.is_empty():
        return loaded_spawn_names
    if loaded_map == null:
        return []
    var discovered: Array[String] = []
    for child in loaded_map.get_children():
        if child is Marker3D and String(child.name).begins_with("Spawn"):
            discovered.append(String(child.name))
    discovered.sort()
    return discovered

func _current_spawn_marker() -> Marker3D:
    if loaded_map == null:
        return null
    var spawn_names := _spawn_names_for_loaded_map()
    if spawn_names.is_empty():
        return null
    current_spawn_index = clampi(current_spawn_index, 0, spawn_names.size() - 1)
    return loaded_map.get_node_or_null(spawn_names[current_spawn_index]) as Marker3D

func unload_map() -> void:
    if scene_object_catalog != null:
        scene_object_catalog.reset()
    if loaded_map != null:
        remove_child(loaded_map)
        loaded_map.queue_free()
        loaded_map = null
    loaded_map_id = ""
    loaded_map_wind_preset = "calm"
    loaded_spawn_names.clear()
    current_spawn_index = 0
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
    var reset_error := _reset_publication_error()
    if not reset_error.is_empty():
        return {"ok": false, "error": reset_error}
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
    var reset_error := _reset_publication_error()
    if not reset_error.is_empty():
        return {"ok": false, "error": reset_error}
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
        var wind_config := {
            "preset": String(result.state.wind_preset),
            "steady_wind": result.state.steady_wind,
        }
        native.call("configure_wind", wind_config)
        if _airsim_secondary_native != null:
            _airsim_secondary_native.call("configure_wind", wind_config)
    if not _apply_environment_visuals(result.state):
        return {"ok": false, "error": last_error_message}
    if not _reset_commit_in_progress:
        _record_replay_environment(_environment_rpc_snapshot(result.state))
    return {"ok": true, "value": _environment_rpc_snapshot(result.state)}


func _apply_environment_visuals(state: Dictionary) -> bool:
    if loaded_map == null:
        return true
    var world_environment := loaded_map.get_node_or_null("AeroSimEnvironment") as WorldEnvironment
    if world_environment == null:
        if loaded_map_id == "terrain3d_range":
            last_error_message = "Terrain Range is missing required AeroSimEnvironment"
            return false
        world_environment = WorldEnvironment.new()
        world_environment.name = "AeroSimEnvironment"
        loaded_map.add_child(world_environment)
    if world_environment.environment == null:
        if loaded_map_id == "terrain3d_range":
            last_error_message = "Terrain Range required AeroSimEnvironment has no Environment resource"
            return false
        world_environment.environment = Environment.new()
    var visual_environment: Environment = world_environment.environment
    if not world_environment.has_meta("aerosim_initial_fog_enabled"):
        world_environment.set_meta("aerosim_initial_fog_enabled", visual_environment.fog_enabled)
        world_environment.set_meta("aerosim_initial_fog_density", visual_environment.fog_density)
    if bool(state.get("weather_enabled", false)):
        visual_environment.fog_enabled = float(state.get("fog", 0.0)) > 0.0
        visual_environment.fog_density = float(state.get("fog", 0.0)) * 0.05
    else:
        visual_environment.fog_enabled = bool(world_environment.get_meta("aerosim_initial_fog_enabled"))
        visual_environment.fog_density = float(world_environment.get_meta("aerosim_initial_fog_density"))
    if bool(state.get("time_of_day_enabled", false)) and bool(state.get("move_sun", true)):
        var sun := loaded_map.get_node_or_null("Sun") as DirectionalLight3D
        var sun_direction: Vector3 = state.get("sun_position", Vector3(0.0, 1.0, 0.0))
        if sun != null and sun_direction.length_squared() > 0.0:
            sun.rotation = Vector3(-asin(clampf(sun_direction.y, -1.0, 1.0)), atan2(sun_direction.x, sun_direction.z), 0.0)
    return true


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
        finish_summary_label.text = _format("ui.finish.summary", [elapsed_seconds])
    _refresh_flight_hud()

func _set_map_error(message: String) -> bool:
    last_error_message = message
    push_warning(message)
    return false

func _reset_airsim_flight_state(preserve_armed: bool = false, stop_px4: bool = true, reset_rpc_controls: bool = true) -> void:
    _airsim_api_control = false
    _airsim_disarm_requested = not preserve_armed
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
    if reset_rpc_controls and airsim_rpc_server != null:
        airsim_rpc_server.reset_vehicle_control_state()
    if px4_sitl_bridge != null and not preserve_armed:
        px4_sitl_bridge.arm_disarm(false)
        if stop_px4:
            px4_sitl_bridge.stop()
        _px4_lockstep_sensor_pending = false
    if not preserve_armed and native != null and native.has_method("disarm_flight_control"):
        native.call("disarm_flight_control")
    if not preserve_armed and _airsim_secondary_native != null and _airsim_secondary_native.has_method("disarm_flight_control"):
        _airsim_secondary_native.call("disarm_flight_control")
    _reset_secondary_kinematic_contexts()
    for name in _airsim_vehicle_contexts:
        var context: Dictionary = _airsim_vehicle_contexts[name]
        context["api_control"] = false
        if not preserve_armed:
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
    var connected_joypads := gamepad_device_state.connected_joypads()
    last_profile_status = InputProfiles.fallback_status(connected_joypads)
    if fallback_status_label != null:
        var profile_key := "ui.fallback.no_controller" if connected_joypads.is_empty() else "ui.fallback.gamepad"
        fallback_status_label.text = _format("ui.fallback.status", [_t(profile_key), _localized_flight_mode(flight_mode)])


func _localize_fallback_message(message: String) -> String:
    if message == InputProfiles.fallback_status([]):
        return _t("ui.fallback.no_controller")
    if message == InputProfiles.fallback_status([0]):
        return _t("ui.fallback.gamepad")
    if message == "KeyboardProfile fallback selected (non-sim control)":
        return _t("ui.fallback.selected")
    if message == "Unsupported controller; Xbox default profile is unavailable. KeyboardProfile fallback active (non-sim control)":
        return _t("ui.error.unsupported_controller")
    if message == "Unsupported controller reconnected; remain disarmed and frozen":
        return _t("ui.error.unsupported_reconnected")
    if message == "Controller reconnected; throttle LOW then press ARM/RESUME":
        return _t("ui.error.controller_reconnected")
    if message == "Controller disconnected; vehicle disarmed and frozen":
        return _t("ui.error.controller_disconnected")
    if message == "Graphics settings applied":
        return _t("ui.graphics.applied")
    if message.begins_with("Graphics settings save failed: "):
        return _t("ui.graphics.save_failed")
    if message.begins_with("Settings factory reset failed: "):
        return _t("ui.settings.factory_reset_failed")
    if message == "Settings factory reset could not apply the default locale":
        return _t("ui.settings.factory_reset_locale_failed")
    if message == "Settings reset to factory defaults":
        return _t("ui.settings.factory_reset_applied")
    if message == "license diagnostics requested":
        return _t("ui.error.license_diagnostics_requested")
    if message.begins_with("License request failed: "):
        return _format("ui.error.license_request_failed", [message.trim_prefix("License request failed: ")])
    if message.begins_with("License network failed: "):
        return _format("ui.error.license_network_failed", [message.trim_prefix("License network failed: ")])
    if message.begins_with("License fatal failed: "):
        return _format("ui.error.license_fatal_failed", [message.trim_prefix("License fatal failed: ")])
    if message == "Arm blocked: controller_resume_required":
        return _t("ui.error.arm_blocked_resume")
    if message == "Quick Fly cannot arm: native runtime unavailable":
        return _t("ui.error.quick_fly_native_unavailable")
    if message == "Arm blocked: keyboard_fallback_requires_confirmation":
        return _t("ui.error.arm_blocked_fallback")
    if message == "Arm blocked: throttle_not_low":
        return _t("ui.error.arm_blocked_throttle")
    if message.begins_with("Quick Fly cannot arm: "):
        return _format("ui.error.quick_fly_rejected", [message.trim_prefix("Quick Fly cannot arm: ")])
    if message == "Flight Setup contains an unsupported selection":
        return _t("ui.error.flight_setup_unsupported")
    if message == "Controller profile was not persisted" or message.begins_with("Controller profile was not persisted: "):
        return _t("ui.error.controller_profile_not_persisted")
    if message == "No fallback prompt is active":
        return _t("ui.error.fallback_no_prompt")
    if message == "Respawn blocked: controller_resume_required":
        return _t("ui.error.respawn_blocked_resume")
    if message == "Resume blocked: throttle_not_low":
        return _t("ui.error.resume_blocked_throttle")
    if message.begins_with("Settings recovered to factory defaults: "):
        return _t("ui.error.settings_recovered")
    if message == "Cannot reset Free Flight: no map is loaded":
        return _t("ui.error.map_reset_no_map")
    if message.begins_with("Cannot reset Free Flight map "):
        return _t("ui.error.map_reset_failed")
    if message.begins_with("Cannot load Free Flight map ") and message.contains(": "):
        return _t("ui.error.map_load_failed")
    if message.begins_with("PX4"):
        return _localized_px4_message(message)
    return _t("ui.error.generic")


func _localized_flight_mode(mode: String) -> String:
    match mode:
        "ANGLE":
            return _t("ui.dashboard.mode_angle")
        "ACRO":
            return _t("ui.dashboard.mode_acro")
        "ALTITUDE_HOLD":
            return _t("ui.dashboard.mode_altitude_hold")
        "ASSISTED_HOLD":
            return _t("ui.dashboard.mode_altitude_hold")
        "", "-":
            return _t("ui.dashboard.none")
        _:
            return _t("ui.dashboard.mode_unknown")

func toggle_altitude_hold() -> void:
    if native == null or not takeoff_requested:
        return
    if flight_mode in ["ALTITUDE_HOLD", "ASSISTED_HOLD"]:
        flight_mode = "ANGLE"
        assisted_horizontal_intent_active = false
    else:
        assisted_hover_throttle = _configured_hover_throttle()
        if assisted_hover_throttle <= 0.0:
            return
        native.call("capture_altitude_hold")
        flight_mode = "ASSISTED_HOLD"
        assisted_horizontal_intent_active = false
    update_fallback_status()


func toggle_acro_mode() -> void:
    if native == null or not takeoff_requested or screen != "flight" or paused:
        return
    flight_mode = "ANGLE" if flight_mode == "ACRO" else "ACRO"
    update_fallback_status()
    _refresh_flight_hud()


func _acro_rate(key: String) -> float:
    return float(rates_profile.get(key, RatesProfile.default_profile().get(key, 0.0)))

func _handle_native_step_failure(step_native, row: PackedFloat64Array = PackedFloat64Array(), has_row: bool = false) -> bool:
    if step_native == null:
        return false
    var native_error := String(step_native.call("last_step_error")) if step_native.has_method("last_step_error") else ""
    if native_error.is_empty() and (not has_row or not row.is_empty()):
        return false
    last_error_message = native_error if not native_error.is_empty() else "Native simulation step failed"
    set_paused(true)
    if not native_error.is_empty():
        screen = "error"
        _refresh_flight_hud()
    return true

func _refresh_native_imu_sample(step_native) -> bool:
    if step_native != null and step_native.has_method("refresh_imu_sample"):
        step_native.call("refresh_imu_sample")
        return not _handle_native_step_failure(step_native)
    return true

func set_paused(value: bool, sync_session: bool = true) -> void:
    _set_paused_checked(value, sync_session)


func _set_paused_checked(value: bool, sync_session: bool = true) -> bool:
    if not value and _airsim_lifecycle_stopped() and (airsim_session == null or not airsim_session.is_explicit_step_active()):
        return false
    if paused != value and sync_session and _replay_recording_active and native != null:
        if not _record_replay_simulation_operation(0 if value else 1, 0.0):
            return false
    paused = value
    if not value:
        status_diagram_fullscreen = false
        if status_diagram_back_button != null:
            status_diagram_back_button.hide()
    if body_drag_debug_panel != null and body_drag_debug_panel.has_method("set_paused"):
        body_drag_debug_panel.call("set_paused", value)
    if sync_session and airsim_session != null:
        airsim_session.set_paused(value)
    if drone_body != null:
        drone_body.freeze = value
        drone_body.sleeping = value
    if secondary_drone_body != null:
        secondary_drone_body.freeze = value
        secondary_drone_body.sleeping = value
    return true

func set_participant_mode(value: bool) -> void:
    participant_mode = value
    if body_drag_debug_panel != null and body_drag_debug_panel.has_method("set_blind_mode"):
        body_drag_debug_panel.call("set_blind_mode", value)

func _t(key: String) -> String:
    return Localization.translate(key)


func _format(key: String, values: Array) -> String:
    return Localization.format(key, values)


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
        button.text = _t("ui.menu.%s" % entry.to_snake_case())
        entries.add_child(button)
        if entry == "Quick Fly":
            button.pressed.connect(quick_fly)
        elif entry == "Lab Mode":
            button.pressed.connect(open_lab_mode)
        elif entry == "Drone":
            button.pressed.connect(open_flight_setup.bind("drone"))
        elif entry == "Map":
            button.pressed.connect(open_flight_setup.bind("map"))
        elif entry == "Controller":
            button.pressed.connect(open_controller_from_menu)
        elif entry == "Settings":
            button.pressed.connect(show_settings)
        elif entry == "Quit":
            button.pressed.connect(request_exit)
    _build_settings_panel()
    _build_controller_settings_panel()
    _build_rates_panel()
    _build_graphics_panel()
    _build_flight_setup_panel()
    var initial_button := entries.get_child(0) as Button
    if initial_button != null and is_inside_tree():
        initial_button.grab_focus()


func _build_flight_setup_panel() -> void:
    var panel := PanelContainer.new()
    panel.name = "FlightSetupPanel"
    panel.set_anchors_preset(Control.PRESET_TOP_LEFT)
    panel.offset_left = 20.0
    panel.offset_top = 20.0
    panel.offset_right = 460.0
    panel.offset_bottom = 360.0
    flight_setup_panel = panel
    main_menu_layer.add_child(panel)

    var rows := VBoxContainer.new()
    rows.name = "Rows"
    rows.add_theme_constant_override("separation", 6)
    panel.add_child(rows)

    var title := Label.new()
    title.name = "Title"
    title.text = _t("ui.flight_setup.title")
    rows.add_child(title)

    var drone_button := Button.new()
    drone_button.name = "Drone"
    drone_button.text = _t("ui.flight_setup.drone")
    rows.add_child(drone_button)

    var map_button := Button.new()
    map_button.name = "Map"
    map_button.text = _t("ui.flight_setup.map")
    rows.add_child(map_button)

    var mode_label := Label.new()
    mode_label.name = "Mode"
    rows.add_child(mode_label)

    var wind_title := Label.new()
    wind_title.name = "WindTitle"
    wind_title.text = _t("ui.flight_setup.wind_preset")
    rows.add_child(wind_title)
    var wind_presets := GridContainer.new()
    wind_presets.name = "WindPresets"
    wind_presets.columns = 4
    wind_presets.add_theme_constant_override("separation", 6)
    wind_presets.add_theme_constant_override("h_separation", 6)
    wind_presets.add_theme_constant_override("v_separation", 6)
    rows.add_child(wind_presets)
    for preset in WIND_PRESETS:
        var wind_button := Button.new()
        wind_button.name = preset.capitalize()
        wind_button.text = _t("ui.wind.%s" % preset)
        wind_button.custom_minimum_size = Vector2(90.0, 31.0)
        wind_button.pressed.connect(_set_flight_setup_wind.bind(preset))
        wind_presets.add_child(wind_button)

    var fly_button := Button.new()
    fly_button.name = "Fly"
    fly_button.text = _t("ui.action.fly")
    fly_button.pressed.connect(_fly_from_flight_setup)
    rows.add_child(fly_button)

    var back_button := Button.new()
    back_button.name = "Back"
    back_button.text = _t("ui.action.back")
    back_button.pressed.connect(show_main_menu)
    rows.add_child(back_button)
    _refresh_flight_setup_panel()


func _refresh_flight_setup_panel() -> void:
    if flight_setup_panel == null:
        return
    if flight_setup.is_empty():
        flight_setup = default_flight_setup()
    var mode_label := get_node_or_null("MainMenu/FlightSetupPanel/Rows/Mode") as Label
    if mode_label != null:
        mode_label.text = _format("ui.flight_setup.mode", [_localized_flight_mode(String(flight_setup.get("mode", DEFAULT_FLIGHT_MODE)))])
    for preset in WIND_PRESETS:
        var wind_button := get_node_or_null("MainMenu/FlightSetupPanel/Rows/WindPresets/%s" % preset.capitalize()) as Button
        if wind_button != null:
            wind_button.button_pressed = String(flight_setup.get("wind_preset", DEFAULT_WIND_PRESET)) == preset

func _build_settings_panel() -> void:
    var panel := PanelContainer.new()
    panel.name = "SettingsPanel"
    panel.set_anchors_preset(Control.PRESET_TOP_LEFT)
    panel.offset_left = 20.0
    panel.offset_top = 20.0
    panel.offset_right = 360.0
    panel.offset_bottom = 340.0
    settings_panel = panel
    main_menu_layer.add_child(panel)

    var rows := VBoxContainer.new()
    rows.name = "Rows"
    rows.add_theme_constant_override("separation", 6)
    panel.add_child(rows)

    var title := Label.new()
    title.name = "Title"
    title.text = _t("ui.settings")
    rows.add_child(title)

    var language_label := Label.new()
    language_label.name = "LanguageLabel"
    language_label.text = _t("ui.language")
    rows.add_child(language_label)
    language_selector = OptionButton.new()
    language_selector.name = "Language"
    language_selector.add_item(_t("ui.language.english"))
    language_selector.set_item_metadata(0, "en")
    language_selector.add_item(_t("ui.language.traditional_chinese"))
    language_selector.set_item_metadata(1, "zh_TW")
    language_selector.item_selected.connect(_on_language_selected)
    rows.add_child(language_selector)

    var controller_button := Button.new()
    controller_button.name = "Controller"
    controller_button.text = _t("ui.settings.controller")
    controller_button.pressed.connect(show_controller_settings)
    rows.add_child(controller_button)

    var rates_button := Button.new()
    rates_button.name = "Rates"
    rates_button.text = _t("ui.settings.rates")
    rates_button.pressed.connect(show_rates)
    rows.add_child(rates_button)

    var graphics_button := Button.new()
    graphics_button.name = "Graphics"
    graphics_button.text = _t("ui.settings.graphics")
    graphics_button.pressed.connect(show_graphics)
    rows.add_child(graphics_button)

    var factory_reset_button := Button.new()
    factory_reset_button.name = "FactoryReset"
    factory_reset_button.text = _t("ui.settings.factory_reset")
    factory_reset_button.pressed.connect(factory_reset_player_settings)
    rows.add_child(factory_reset_button)

    settings_status_label = Label.new()
    settings_status_label.name = "Status"
    settings_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    rows.add_child(settings_status_label)

    var back_button := Button.new()
    back_button.name = "Back"
    back_button.text = _t("ui.action.back")
    back_button.pressed.connect(show_main_menu)
    rows.add_child(back_button)
    _refresh_language_selector()


func _on_language_selected(index: int) -> void:
    if language_selector == null or index < 0 or index >= language_selector.item_count:
        return
    set_locale(String(language_selector.get_item_metadata(index)))


func set_locale(locale: String) -> bool:
    var previous_locale := Localization.current_locale
    if not Localization.set_locale(locale):
        return false
    var loaded: Dictionary = settings_store.load_document()
    if not loaded.ok:
        Localization.set_locale(previous_locale)
        _refresh_localized_ui()
        return false
    loaded.document["language"] = {"schema_version": LanguageProfile.SCHEMA_VERSION, "locale": locale}
    var saved: Dictionary = settings_store.save_document(loaded.document)
    if not saved.ok:
        Localization.set_locale(previous_locale)
        _refresh_localized_ui()
        return false
    _refresh_localized_ui()
    return true


func _refresh_language_selector() -> void:
    if language_selector == null:
        return
    language_selector.set_item_text(0, _t("ui.language.english"))
    language_selector.set_item_text(1, _t("ui.language.traditional_chinese"))
    language_selector.select(LanguageProfile.SUPPORTED_LOCALES.find(Localization.current_locale))


func _refresh_localized_ui() -> void:
    if main_menu_entries_container != null:
        for index in range(min(main_menu_entries_container.get_child_count(), main_menu_entries.size())):
            var button := main_menu_entries_container.get_child(index) as Button
            if button != null:
                button.text = _t("ui.menu.%s" % main_menu_entries[index].to_snake_case())
    var text_by_path := {
        "MainMenu/FlightSetupPanel/Rows/Title": "ui.flight_setup.title",
        "MainMenu/FlightSetupPanel/Rows/Drone": "ui.flight_setup.drone",
        "MainMenu/FlightSetupPanel/Rows/Map": "ui.flight_setup.map",
        "MainMenu/FlightSetupPanel/Rows/WindTitle": "ui.flight_setup.wind_preset",
        "MainMenu/FlightSetupPanel/Rows/Fly": "ui.action.fly",
        "MainMenu/FlightSetupPanel/Rows/Back": "ui.action.back",
        "MainMenu/SettingsPanel/Rows/Title": "ui.settings",
        "MainMenu/SettingsPanel/Rows/LanguageLabel": "ui.language",
        "MainMenu/SettingsPanel/Rows/Controller": "ui.settings.controller",
        "MainMenu/SettingsPanel/Rows/Rates": "ui.settings.rates",
        "MainMenu/SettingsPanel/Rows/Graphics": "ui.settings.graphics",
        "FlightHud/PausePanel/Rows/Camera": "ui.settings.camera",
        "FlightHud/PausePanel/Rows/OSD": "ui.settings.osd",
        "FlightHud/CameraPanel/Rows/Title": "ui.camera.title",
        "FlightHud/CameraPanel/Rows/CameraAngleLabel": "ui.camera.angle",
        "FlightHud/CameraPanel/Rows/FovLabel": "ui.camera.fov",
        "FlightHud/CameraPanel/Rows/AnalogNoise": "ui.camera.analog_noise",
        "FlightHud/OsdPanel/Rows/Title": "ui.osd.title",
        "FlightHud/OsdPanel/Rows/DragHint": "ui.osd.drag_hint",
        "FlightHud/CameraPanel/Rows/Back": "ui.action.back",
        "FlightHud/OsdPanel/Rows/Back": "ui.action.back",
        "MainMenu/SettingsPanel/Rows/FactoryReset": "ui.settings.factory_reset",
        "MainMenu/SettingsPanel/Rows/Back": "ui.action.back",
        "MainMenu/GraphicsPanel/Rows/Title": "ui.settings.graphics",
        "MainMenu/GraphicsPanel/Rows/Apply": "ui.action.apply",
        "MainMenu/GraphicsPanel/Rows/ResetDefaults": "ui.action.reset_defaults",
        "MainMenu/GraphicsPanel/Rows/Back": "ui.action.back",
        "MainMenu/RatesPanel/Scroll/Rows/Title": "ui.rates.title",
        "MainMenu/RatesPanel/Scroll/Rows/Disclaimer": "ui.rates.disclaimer",
        "MainMenu/RatesPanel/Scroll/Rows/CurvePreviewTitle": "ui.rates.curve_preview",
        "MainMenu/RatesPanel/Scroll/Rows/JsonTitle": "ui.rates.json_title",
        "MainMenu/RatesPanel/Scroll/Rows/Actions/ExportJson": "ui.rates.export",
        "MainMenu/RatesPanel/Scroll/Rows/Actions/ImportJson": "ui.rates.import",
        "MainMenu/RatesPanel/Scroll/Rows/Actions/ResetDefaults": "ui.action.reset_defaults",
        "MainMenu/RatesPanel/Scroll/Rows/Actions/Back": "ui.action.back",
        "MainMenu/ControllerSettingsPanel/Rows/Title": "ui.settings.controller",
        "MainMenu/ControllerSettingsPanel/Rows/ResetXboxDefault": "ui.controller.reset_xbox",
        "MainMenu/ControllerSettingsPanel/Rows/Back": "ui.action.back",
        "FlightHud/ControllerConfirmation/Rows/Title": "ui.controller.confirm_title",
        "FlightHud/ControllerConfirmation/Rows/UseXboxDefaultProfile": "ui.controller.use_xbox",
        "FlightHud/ControllerConfirmation/Rows/UseKeyboardFallback": "ui.controller.use_keyboard",
        "FlightHud/StatusMargin/StatusPanel/StatusRows/LabBack": "ui.action.back_to_menu",
        "FlightHud/LicensePanel/Rows/Title": "ui.license.required",
        "FlightHud/LicensePanel/Rows/Activate": "ui.license.activate",
        "FlightHud/LicensePanel/Rows/Retry": "ui.action.retry",
        "FlightHud/LicensePanel/Rows/Diagnostics": "ui.license.diagnostics",
        "FlightHud/LicensePanel/Rows/Exit": "ui.action.exit",
        "FlightHud/PausePanel/Rows/Title": "ui.pause.title",
        "FlightHud/PausePanel/Rows/Resume": "ui.pause.resume",
        "FlightHud/PausePanel/Rows/Reset": "ui.action.reset",
        "FlightHud/PausePanel/Rows/ChangeSpawn": "ui.action.change_spawn",
        "FlightHud/PausePanel/Rows/Rates": "ui.settings.rates",
        "FlightHud/PausePanel/Rows/ControllerMonitor": "ui.settings.controller_monitor",
        "FlightHud/PausePanel/Rows/StatusDiagram": "ui.settings.status_diagram",
        "FlightHud/PausePanel/Rows/Exit": "ui.action.exit",
        "FlightHud/FinishPanel/Rows/Retry": "ui.action.retry",
        "FlightHud/FinishPanel/Rows/ChangeMap": "ui.action.change_map",
        "FlightHud/FinishPanel/Rows/Exit": "ui.action.exit",
    }
    for path in text_by_path:
        var control := get_node_or_null(path) as Control
        if control != null:
            control.text = _t(String(text_by_path[path]))
    var wind_rows := get_node_or_null("MainMenu/FlightSetupPanel/Rows/WindPresets")
    if wind_rows != null:
        for preset in WIND_PRESETS:
            var wind_button := wind_rows.get_node_or_null(preset.capitalize()) as Button
            if wind_button != null:
                wind_button.text = _t("ui.wind.%s" % preset)
    var map_wind_rows := get_node_or_null("MapMenu/WindPresets")
    if map_wind_rows != null:
        for preset in WIND_PRESETS:
            var map_wind_button := map_wind_rows.get_node_or_null(preset.capitalize()) as Button
            if map_wind_button != null:
                map_wind_button.text = _t("ui.wind.%s" % preset)
    var map_environment_labels := {
        "rain": "ui.map.rain",
        "fog": "ui.map.fog",
        "time_of_day": "ui.map.time_of_day",
    }
    for node_name in map_environment_labels:
        var environment_label := get_node_or_null("MapMenu/EnvironmentControls/%s" % node_name) as Label
        if environment_label != null:
            environment_label.text = _t(String(map_environment_labels[node_name]))
    if license_key_input != null:
        license_key_input.placeholder_text = _t("ui.license.key_placeholder")
    if osd_preset_selector != null:
        for index in range(OsdProfile.PRESETS.size()):
            osd_preset_selector.set_item_text(index, _t("ui.osd.preset.%s" % OsdProfile.PRESETS[index].to_snake_case()))
    if osd_panel != null:
        for element in OsdProfile.ELEMENTS:
            var toggle := osd_panel.get_node_or_null("Rows/Elements/%s" % String(element).capitalize()) as CheckButton
            if toggle != null:
                toggle.text = _t("ui.osd.element.%s" % element)
    if camera_panel != null:
        var angle_label := camera_panel.get_node_or_null("Rows/CameraAngleLabel") as Label
        var fov_label := camera_panel.get_node_or_null("Rows/FovLabel") as Label
        if angle_label != null:
            _refresh_camera_slider_label(angle_label, "ui.camera.angle", float(camera_profile.camera_angle_deg))
        if fov_label != null:
            _refresh_camera_slider_label(fov_label, "ui.camera.fov", float(camera_profile.fov_deg))
    _refresh_language_selector()
    _refresh_flight_setup_panel()
    _refresh_flight_hud()
    if status_diagram != null:
        status_diagram.call("set_locale", Localization.current_locale)
    _refresh_loaded_map_localization()


func _refresh_loaded_map_localization() -> void:
    if loaded_map == null:
        return
    var labels_by_path := {
        "SpawnNorth/DirectionLabel": "ui.map.north_spawn",
        "SpawnSouth/DirectionLabel": "ui.map.south_spawn",
        "TurnMarker/DirectionLabel": "ui.map.turn_90",
        "TimeTrial/Checkpoint01/DirectionArrow": "ui.map.checkpoint_1",
        "TimeTrial/Checkpoint02/DirectionArrow": "ui.map.checkpoint_2",
        "TimeTrial/Checkpoint03/DirectionArrow": "ui.map.checkpoint_3",
        "TimeTrial/Finish/FinishLabel": "ui.map.finish",
    }
    for path in labels_by_path:
        var label := loaded_map.get_node_or_null(path) as Label3D
        if label != null:
            label.text = _t(String(labels_by_path[path]))


func _build_graphics_panel() -> void:
    var panel := PanelContainer.new()
    panel.name = "GraphicsPanel"
    panel.set_anchors_preset(Control.PRESET_TOP_LEFT)
    panel.offset_left = 20.0
    panel.offset_top = 20.0
    panel.offset_right = 460.0
    panel.offset_bottom = 300.0
    graphics_panel = panel
    main_menu_layer.add_child(panel)

    var rows := VBoxContainer.new()
    rows.name = "Rows"
    rows.add_theme_constant_override("separation", 6)
    panel.add_child(rows)

    var title := Label.new()
    title.name = "Title"
    title.text = _t("ui.settings.graphics")
    rows.add_child(title)

    graphics_value_label = Label.new()
    graphics_value_label.name = "RenderScaleValue"
    rows.add_child(graphics_value_label)

    var slider := HSlider.new()
    slider.name = "RenderScale"
    slider.min_value = QualityProfile.MIN_RENDER_SCALE
    slider.max_value = QualityProfile.MAX_RENDER_SCALE
    slider.step = QualityProfile.RENDER_SCALE_STEP
    slider.value = render_scale
    slider.value_changed.connect(_on_render_scale_changed)
    rows.add_child(slider)

    var apply_button := Button.new()
    apply_button.name = "Apply"
    apply_button.text = _t("ui.action.apply")
    apply_button.pressed.connect(_apply_graphics_settings)
    rows.add_child(apply_button)

    var reset_button := Button.new()
    reset_button.name = "ResetDefaults"
    reset_button.text = _t("ui.action.reset_defaults")
    reset_button.pressed.connect(_reset_graphics_defaults)
    rows.add_child(reset_button)

    var back_button := Button.new()
    back_button.name = "Back"
    back_button.text = _t("ui.action.back")
    back_button.pressed.connect(_close_graphics_panel)
    rows.add_child(back_button)
    _refresh_graphics_panel()


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
    title.name = "Title"
    title.text = _t("ui.rates.title")
    rows.add_child(title)
    var disclaimer := Label.new()
    disclaimer.name = "Disclaimer"
    disclaimer.text = _t("ui.rates.disclaimer")
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
    curve_title.name = "CurvePreviewTitle"
    curve_title.text = _t("ui.rates.curve_preview")
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
    json_title.name = "JsonTitle"
    json_title.text = _t("ui.rates.json_title")
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
    export_button.text = _t("ui.rates.export")
    export_button.pressed.connect(_export_rates_json)
    actions.add_child(export_button)
    var import_button := Button.new()
    import_button.name = "ImportJson"
    import_button.text = _t("ui.rates.import")
    import_button.pressed.connect(_import_rates_json)
    actions.add_child(import_button)
    var reset_button := Button.new()
    reset_button.name = "ResetDefaults"
    reset_button.text = _t("ui.action.reset_defaults")
    reset_button.pressed.connect(_reset_rates_defaults)
    actions.add_child(reset_button)
    var back_button := Button.new()
    back_button.name = "Back"
    back_button.text = _t("ui.action.back")
    back_button.pressed.connect(_close_rates_panel)
    actions.add_child(back_button)


func _on_rates_slider_changed(value: float, key: String) -> void:
    var candidate: Dictionary = rates_profile.duplicate(true)
    candidate[key] = value
    var result: Dictionary = _save_rates_profile(candidate)
    if not result.ok:
        rates_status_label.text = _t("ui.rates.save_failed")
        return
    rates_status_label.text = _t("ui.rates.saved")
    if rates_json_editor != null:
        rates_json_editor.text = RatesProfile.to_json(rates_profile)
    _refresh_rates_panel()


func _export_rates_json() -> void:
    if rates_json_editor != null:
        rates_json_editor.text = RatesProfile.to_json(rates_profile)
    rates_status_label.text = _t("ui.rates.exported")
    _refresh_rates_import_diff()


func _import_rates_json() -> void:
    if rates_json_editor == null:
        return
    var result: Dictionary = RatesProfile.from_json(rates_json_editor.text)
    if not result.ok:
        rates_status_label.text = _t("ui.rates.import_rejected")
        _refresh_rates_import_diff()
        return
    var save_result: Dictionary = _save_rates_profile(result.profile)
    if not save_result.ok:
        rates_status_label.text = _t("ui.rates.import_save_failed")
        return
    rates_json_editor.text = RatesProfile.to_json(rates_profile)
    rates_status_label.text = _t("ui.rates.imported")
    _refresh_rates_import_diff()


func _reset_rates_defaults() -> void:
    var result: Dictionary = _save_rates_profile(RatesProfile.default_profile())
    if not result.ok:
        rates_status_label.text = _t("ui.rates.reset_failed")
        return
    rates_json_editor.text = RatesProfile.to_json(rates_profile)
    rates_status_label.text = _t("ui.rates.reset")
    _refresh_rates_import_diff()


func _on_rates_json_changed() -> void:
    _refresh_rates_import_diff()


func _refresh_rates_import_diff() -> void:
    if rates_json_editor == null or rates_diff_label == null:
        return
    var result: Dictionary = RatesProfile.from_json(rates_json_editor.text)
    if not result.ok:
        rates_diff_label.text = _t("ui.rates.diff_invalid")
        return
    var changes: Array[Dictionary] = RatesProfile.diff(rates_profile, result.profile)
    if changes.is_empty():
        rates_diff_label.text = _t("ui.rates.diff_none")
        return
    var lines := [_t("ui.rates.diff_header")]
    for change in changes:
        lines.append(_format("ui.rates.diff_line", [change.key, change.current, change.imported]))
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
        label.text = _format("ui.rates.value", [_localized_rate_name(key), value])
    if rates_curve_line != null:
        _refresh_rates_curve()
    _refresh_rates_import_diff()


func _localized_rate_name(key: String) -> String:
    return _t("ui.rates.axis.%s" % key)


func _refresh_graphics_panel() -> void:
    if graphics_value_label == null:
        return
    graphics_value_label.text = _format("ui.render_scale", [roundi(render_scale * 100.0)])
    var slider := get_node_or_null("MainMenu/GraphicsPanel/Rows/RenderScale") as HSlider
    if slider != null and not is_equal_approx(slider.value, render_scale):
        slider.set_value_no_signal(render_scale)


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
    title.name = "Title"
    title.text = _t("ui.settings.controller")
    rows.add_child(title)

    controller_settings_device_label = Label.new()
    controller_settings_device_label.name = "CurrentDevice"
    rows.add_child(controller_settings_device_label)

    controller_settings_mapping_label = Label.new()
    controller_settings_mapping_label.name = "FixedMapping"
    rows.add_child(controller_settings_mapping_label)

    controller_settings_monitor_label = Label.new()
    controller_settings_monitor_label.name = "ChannelMonitor"
    rows.add_child(controller_settings_monitor_label)

    var reset_button := Button.new()
    reset_button.name = "ResetXboxDefault"
    reset_button.text = _t("ui.controller.reset_xbox")
    reset_button.pressed.connect(reset_to_xbox_default)
    rows.add_child(reset_button)

    var back_button := Button.new()
    back_button.name = "Back"
    back_button.text = _t("ui.action.back")
    back_button.pressed.connect(_close_controller_settings)
    rows.add_child(back_button)

func show_main_menu() -> void:
    if screen == "lab_mode":
        set_dashboard_layout_mode("compact")
    screen = "main_menu"
    _refresh_flight_hud()
    var initial_button := get_node_or_null("MainMenu/Entries/QuickFly") as Button
    if initial_button != null and is_inside_tree():
        initial_button.grab_focus()


func open_lab_mode() -> void:
    set_dashboard_layout_mode("full")
    screen = "lab_mode"
    _refresh_flight_hud()
    if lab_back_button != null and lab_back_button.is_inside_tree():
        lab_back_button.grab_focus()


func return_from_lab_mode() -> void:
    set_dashboard_layout_mode("compact")
    show_main_menu()

func show_settings() -> void:
    screen = "settings"
    _refresh_flight_hud()
    var graphics_button := get_node_or_null("MainMenu/SettingsPanel/Rows/Graphics") as Button
    if graphics_button != null and is_inside_tree():
        graphics_button.grab_focus()

func show_controller_settings(return_screen: String = "settings") -> void:
    controller_settings_return_screen = return_screen if return_screen in ["flight", "settings"] else "settings"
    screen = "controller_settings"
    controller_monitor_refresh_count = 0
    _refresh_controller_settings()
    _refresh_flight_hud()
    var reset_button := controller_settings_panel.get_node_or_null("Rows/ResetXboxDefault") as Button if controller_settings_panel != null else null
    if reset_button != null and reset_button.is_visible_in_tree():
        reset_button.grab_focus()


func _close_controller_settings() -> void:
    screen = controller_settings_return_screen
    _refresh_flight_hud()


func show_rates(return_screen: String = "settings") -> void:
    rates_return_screen = return_screen
    screen = "rates"
    if rates_json_editor != null:
        rates_json_editor.text = RatesProfile.to_json(rates_profile)
    _refresh_rates_import_diff()
    _refresh_flight_hud()


func show_camera(return_screen: String = "settings") -> void:
    camera_return_screen = return_screen if return_screen in ["flight", "settings"] else "settings"
    screen = "camera"
    _refresh_camera_panel()
    _refresh_flight_hud()
    var slider := camera_panel.get_node_or_null("Rows/CameraAngle") as HSlider if camera_panel != null else null
    if slider != null:
        slider.grab_focus()


func show_osd(return_screen: String = "settings") -> void:
    osd_return_screen = return_screen if return_screen in ["flight", "settings"] else "settings"
    screen = "osd"
    _refresh_osd_panel()
    _refresh_flight_hud()
    if osd_preset_selector != null:
        osd_preset_selector.grab_focus()


func show_graphics(return_screen: String = "settings") -> void:
    graphics_return_screen = return_screen
    graphics_committed_scale = render_scale
    var slider := get_node_or_null("MainMenu/GraphicsPanel/Rows/RenderScale") as HSlider
    if slider != null:
        slider.value = render_scale
    screen = "graphics"
    _refresh_graphics_panel()
    _refresh_flight_hud()
    if slider != null:
        slider.grab_focus()


func _preview_render_scale(value: float) -> void:
    render_scale = value
    var viewport := get_viewport()
    if viewport != null:
        viewport.scaling_3d_scale = render_scale
    _refresh_graphics_panel()


func _on_render_scale_changed(value: float) -> void:
    _preview_render_scale(value)


func _reset_graphics_defaults() -> void:
    _preview_render_scale(QualityProfile.DEFAULT_RENDER_SCALE)


func _apply_graphics_settings() -> Dictionary:
    var result := _save_quality_profile({
        "schema_version": QualityProfile.SCHEMA_VERSION,
        "render_scale": render_scale,
    })
    if result.ok:
        last_error_message = "Graphics settings applied"
    else:
        _preview_render_scale(graphics_committed_scale)
        last_error_message = "Graphics settings save failed: %s" % result.error
    _refresh_flight_hud()
    return result


func _close_graphics_panel() -> void:
    _preview_render_scale(graphics_committed_scale)
    if graphics_return_screen == "flight":
        screen = "flight"
        _refresh_flight_hud()
    else:
        show_settings()


func _close_rates_panel() -> void:
    if rates_return_screen == "flight":
        screen = "flight"
        _refresh_flight_hud()
    else:
        show_settings()

func reset_to_xbox_default() -> void:
    controller_return_screen = "controller_settings"
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
    camera_profile = CameraProfile.default_profile()
    osd_profile = OsdProfile.default_profile()
    camera_profile_persisted = false
    _apply_camera_profile()
    _preview_render_scale(QualityProfile.DEFAULT_RENDER_SCALE)
    graphics_committed_scale = QualityProfile.DEFAULT_RENDER_SCALE
    if rates_json_editor != null:
        rates_json_editor.text = RatesProfile.to_json(rates_profile)
    if not Localization.set_locale(LanguageProfile.DEFAULT_LOCALE):
        last_error_message = "Settings factory reset could not apply the default locale"
        screen = "error"
        _refresh_flight_hud()
        return
    _refresh_localized_ui()
    _refresh_osd_panel()
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
    title.text = _t("ui.controller.confirm_title")
    rows.add_child(title)

    confirmation_mapping_label = Label.new()
    confirmation_mapping_label.name = "FixedMapping"
    rows.add_child(confirmation_mapping_label)

    confirmation_axes_label = Label.new()
    confirmation_axes_label.name = "LiveAxes"
    rows.add_child(confirmation_axes_label)

    var confirm_button := Button.new()
    confirm_button.name = "UseXboxDefaultProfile"
    confirm_button.text = _t("ui.controller.use_xbox")
    confirm_button.pressed.connect(accept_controller_confirmation)
    rows.add_child(confirm_button)

    var fallback_button := Button.new()
    fallback_button.name = "UseKeyboardFallback"
    fallback_button.text = _t("ui.controller.use_keyboard")
    fallback_button.pressed.connect(use_keyboard_fallback)
    rows.add_child(fallback_button)

func _build_flight_hud() -> void:
    var layer := CanvasLayer.new()
    layer.name = "FlightHud"
    layer.layer = 30
    flight_hud_layer = layer
    add_child(layer)
    _build_cockpit_regions(layer)
    _build_analog_noise_overlay(layer)
    _build_osd(layer)
    _build_gamepad_hud(layer)
    _build_motor_hud(layer)

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
    key_hints_label.text = _t("ui.hints")
    key_hints_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    rows.add_child(key_hints_label)

    arm_status_label = Label.new()
    arm_status_label.name = "ArmStatus"
    arm_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    rows.add_child(arm_status_label)

    player_view_label = Label.new()
    player_view_label.name = "PlayerView"
    rows.add_child(player_view_label)

    time_trial_status_label = Label.new()
    time_trial_status_label.name = "TimeTrialStatus"
    rows.add_child(time_trial_status_label)

    arm_takeoff_button = Button.new()
    arm_takeoff_button.name = "ArmTakeoff"
    arm_takeoff_button.pressed.connect(_handle_primary_action)
    rows.add_child(arm_takeoff_button)
    lab_back_button = Button.new()
    lab_back_button.name = "LabBack"
    lab_back_button.text = _t("ui.action.back_to_menu")
    lab_back_button.pressed.connect(return_from_lab_mode)
    rows.add_child(lab_back_button)
    acro_mode_button = Button.new()
    acro_mode_button.name = "AcroMode"
    acro_mode_button.pressed.connect(toggle_acro_mode)
    rows.add_child(acro_mode_button)
    quick_adjust_status_label = Label.new()
    quick_adjust_status_label.name = "QuickAdjustStatus"
    quick_adjust_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    rows.add_child(quick_adjust_status_label)
    _build_pause_panel()
    _build_camera_panel()
    _build_osd_panel()
    _build_controller_safety_panel()
    _build_finish_panel()
    _build_license_panel()


func _build_cockpit_regions(layer: CanvasLayer) -> void:
    var left_rail := Panel.new()
    left_rail.name = "LeftRail"
    left_rail.set_anchors_preset(Control.PRESET_LEFT_WIDE)
    left_rail.offset_right = COCKPIT_LEFT_RAIL_WIDTH
    left_rail.mouse_filter = Control.MOUSE_FILTER_IGNORE
    layer.add_child(left_rail)

    var flight_view := Control.new()
    flight_view.name = "FlightViewRegion"
    flight_view.set_anchors_preset(Control.PRESET_FULL_RECT)
    flight_view.offset_left = COCKPIT_LEFT_RAIL_WIDTH
    flight_view.offset_right = -COCKPIT_RIGHT_RAIL_WIDTH
    flight_view.mouse_filter = Control.MOUSE_FILTER_IGNORE
    layer.add_child(flight_view)

    var right_rail := Panel.new()
    right_rail.name = "RightRail"
    right_rail.set_anchors_preset(Control.PRESET_RIGHT_WIDE)
    right_rail.offset_left = -COCKPIT_RIGHT_RAIL_WIDTH
    right_rail.mouse_filter = Control.MOUSE_FILTER_IGNORE
    layer.add_child(right_rail)


func _build_gamepad_hud(layer: CanvasLayer) -> void:
    var margin := MarginContainer.new()
    margin.name = "GamepadHudMargin"
    margin.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
    margin.offset_left = 10.0
    margin.offset_top = -224.0
    margin.offset_right = COCKPIT_LEFT_RAIL_WIDTH - 10.0
    margin.offset_bottom = -10.0
    layer.add_child(margin)
    gamepad_hud_panel = PanelContainer.new()
    gamepad_hud_panel.name = "GamepadHudPanel"
    margin.add_child(gamepad_hud_panel)
    gamepad_hud_display = GamepadTelemetryPanel.new()
    gamepad_hud_display.name = "GamepadTelemetryPanel"
    gamepad_hud_panel.add_child(gamepad_hud_display)

func _build_motor_hud(layer: CanvasLayer) -> void:
    var margin := MarginContainer.new()
    margin.name = "MotorHudMargin"
    margin.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
    margin.offset_left = -COCKPIT_RIGHT_RAIL_WIDTH + 10.0
    margin.offset_top = -224.0
    margin.offset_right = -10.0
    margin.offset_bottom = -10.0
    margin.add_theme_constant_override("margin_left", 6)
    margin.add_theme_constant_override("margin_top", 6)
    margin.add_theme_constant_override("margin_right", 6)
    margin.add_theme_constant_override("margin_bottom", 6)
    layer.add_child(margin)

    motor_hud_panel = PanelContainer.new()
    motor_hud_panel.name = "MotorHudPanel"
    margin.add_child(motor_hud_panel)
    motor_hud_rotor_panel = RotorTelemetryPanel.new()
    motor_hud_rotor_panel.name = "RotorTelemetryPanel"
    motor_hud_panel.add_child(motor_hud_rotor_panel)


func _build_analog_noise_overlay(layer: CanvasLayer) -> void:
    analog_noise_overlay = ColorRect.new()
    analog_noise_overlay.name = "AnalogNoise"
    analog_noise_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    analog_noise_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
    var shader := Shader.new()
    shader.code = "shader_type canvas_item; void fragment() { float noise = fract(sin(dot(UV + TIME, vec2(12.9898, 78.233))) * 43758.5453); COLOR = vec4(vec3(noise), 0.045); }"
    var material := ShaderMaterial.new()
    material.shader = shader
    analog_noise_overlay.material = material
    layer.add_child(analog_noise_overlay)


func _build_osd(layer: CanvasLayer) -> void:
    var root := Control.new()
    root.name = "FpvOsd"
    root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    root.mouse_filter = Control.MOUSE_FILTER_IGNORE
    layer.add_child(root)
    for element in OsdProfile.ELEMENTS:
        var label := Label.new()
        label.name = String(element).capitalize().replace(" ", "")
        label.mouse_filter = Control.MOUSE_FILTER_STOP
        label.gui_input.connect(_on_osd_label_gui_input.bind(element))
        label.add_theme_color_override("font_color", Color(0.85, 1.0, 0.85))
        label.add_theme_color_override("font_shadow_color", Color(0.0, 0.0, 0.0, 0.85))
        label.add_theme_constant_override("shadow_offset_x", 2)
        label.add_theme_constant_override("shadow_offset_y", 2)
        root.add_child(label)
        osd_labels[element] = label


func _build_camera_panel() -> void:
    var panel := PanelContainer.new()
    panel.name = "CameraPanel"
    panel.set_anchors_preset(Control.PRESET_CENTER)
    panel.offset_left = -220.0
    panel.offset_top = -150.0
    panel.offset_right = 220.0
    panel.offset_bottom = 150.0
    camera_panel = panel
    flight_hud_layer.add_child(panel)
    var rows := VBoxContainer.new()
    rows.name = "Rows"
    rows.add_theme_constant_override("separation", 6)
    panel.add_child(rows)
    var title := Label.new()
    title.name = "Title"
    title.text = _t("ui.camera.title")
    rows.add_child(title)
    _add_camera_slider(rows, "CameraAngle", "ui.camera.angle", 0.0, 90.0, 1.0, float(camera_profile.camera_angle_deg), "camera_angle_deg")
    _add_camera_slider(rows, "Fov", "ui.camera.fov", 30.0, 180.0, 1.0, float(camera_profile.fov_deg), "fov_deg")
    var noise := CheckButton.new()
    noise.name = "AnalogNoise"
    noise.text = _t("ui.camera.analog_noise")
    noise.button_pressed = bool(camera_profile.analog_noise)
    noise.toggled.connect(_on_camera_noise_toggled)
    rows.add_child(noise)
    var back := Button.new()
    back.name = "Back"
    back.text = _t("ui.action.back")
    back.pressed.connect(_close_camera_panel)
    rows.add_child(back)


func _add_camera_slider(rows: VBoxContainer, node_name: String, label_key: String, minimum: float, maximum: float, step: float, value: float, key: String) -> void:
    var label := Label.new()
    label.name = "%sLabel" % node_name
    rows.add_child(label)
    var slider := HSlider.new()
    slider.name = node_name
    slider.min_value = minimum
    slider.max_value = maximum
    slider.step = step
    slider.value = value
    slider.value_changed.connect(_on_camera_slider_changed.bind(key, label, label_key))
    rows.add_child(slider)
    _refresh_camera_slider_label(label, label_key, value)


func _refresh_camera_slider_label(label: Label, label_key: String, value: float) -> void:
    label.text = _format(label_key, [value])


func _on_camera_slider_changed(value: float, key: String, label: Label, label_key: String) -> void:
    var candidate := camera_profile.duplicate(true)
    candidate[key] = value
    var result := _save_camera_profile(candidate)
    if result.ok:
        _refresh_camera_slider_label(label, label_key, value)
    else:
        label.text = _format(label_key, [camera_profile[key]])


func _on_camera_noise_toggled(enabled: bool) -> void:
    var candidate := camera_profile.duplicate(true)
    candidate["analog_noise"] = enabled
    _save_camera_profile(candidate)


func _close_camera_panel() -> void:
    screen = camera_return_screen
    _refresh_flight_hud()


func _build_osd_panel() -> void:
    var panel := PanelContainer.new()
    panel.name = "OsdPanel"
    panel.set_anchors_preset(Control.PRESET_CENTER)
    panel.offset_left = -240.0
    panel.offset_top = -210.0
    panel.offset_right = 240.0
    panel.offset_bottom = 210.0
    osd_panel = panel
    flight_hud_layer.add_child(panel)
    var rows := VBoxContainer.new()
    rows.name = "Rows"
    rows.add_theme_constant_override("separation", 5)
    panel.add_child(rows)
    var title := Label.new()
    title.name = "Title"
    title.text = _t("ui.osd.title")
    rows.add_child(title)
    var hint := Label.new()
    hint.name = "DragHint"
    hint.text = _t("ui.osd.drag_hint")
    hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    rows.add_child(hint)
    osd_preset_selector = OptionButton.new()
    osd_preset_selector.name = "Preset"
    for preset in OsdProfile.PRESETS:
        osd_preset_selector.add_item(_t("ui.osd.preset.%s" % preset.to_snake_case()))
        osd_preset_selector.set_item_metadata(osd_preset_selector.item_count - 1, preset)
    osd_preset_selector.item_selected.connect(_on_osd_preset_selected)
    rows.add_child(osd_preset_selector)
    var toggles := GridContainer.new()
    toggles.name = "Elements"
    toggles.columns = 2
    rows.add_child(toggles)
    for element in OsdProfile.ELEMENTS:
        var toggle := CheckButton.new()
        toggle.name = String(element).capitalize()
        toggle.text = _t("ui.osd.element.%s" % element)
        toggle.button_pressed = bool(osd_profile.elements[element])
        toggle.toggled.connect(_on_osd_element_toggled.bind(element))
        toggles.add_child(toggle)
    var back := Button.new()
    back.name = "Back"
    back.text = _t("ui.action.back")
    back.pressed.connect(_close_osd_panel)
    rows.add_child(back)


func _on_osd_preset_selected(index: int) -> void:
    if osd_preset_selector == null or index < 0 or index >= osd_preset_selector.item_count:
        return
    var preset := String(osd_preset_selector.get_item_metadata(index))
    var result := _save_osd_profile(OsdProfile.profile_for_preset(preset))
    if result.ok:
        _refresh_osd_panel()


func _on_osd_element_toggled(enabled: bool, element: String) -> void:
    var candidate := osd_profile.duplicate(true)
    candidate.elements[element] = enabled
    _save_osd_profile(candidate)


func _on_osd_label_gui_input(event: InputEvent, element: String) -> void:
    if screen != "osd" or not bool(osd_profile.elements.get(element, false)):
        return
    var label := osd_labels.get(element) as Label
    if label == null:
        return
    if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
        osd_drag_element = element if event.pressed else ""
        if event.pressed:
            osd_drag_offset = label.get_global_mouse_position() - label.global_position
        else:
            _save_osd_profile(osd_profile.duplicate(true))
        get_viewport().set_input_as_handled()
    elif event is InputEventMouseMotion and osd_drag_element == element:
        var viewport_size: Vector2 = get_viewport().get_visible_rect().size
        if viewport_size.x <= 0.0 or viewport_size.y <= 0.0:
            return
        var position := label.get_global_mouse_position() - osd_drag_offset
        osd_profile.positions[element] = {
            "x": clampf(position.x / viewport_size.x, 0.0, 1.0),
            "y": clampf(position.y / viewport_size.y, 0.0, 1.0),
        }
        _refresh_osd()
        get_viewport().set_input_as_handled()


func _close_osd_panel() -> void:
    screen = osd_return_screen
    _refresh_flight_hud()


func _build_license_panel() -> void:
    var panel := PanelContainer.new()
    panel.name = "LicensePanel"
    panel.set_anchors_preset(Control.PRESET_CENTER)
    panel.offset_left = -280.0
    panel.offset_top = -120.0
    panel.offset_right = 160.0
    panel.offset_bottom = 120.0
    license_panel = panel
    flight_hud_layer.add_child(panel)

    var rows := VBoxContainer.new()
    rows.name = "Rows"
    rows.add_theme_constant_override("separation", 6)
    panel.add_child(rows)

    var title := Label.new()
    title.text = _t("ui.license.required")
    rows.add_child(title)
    license_status_label = Label.new()
    license_status_label.name = "Status"
    rows.add_child(license_status_label)
    license_key_input = LineEdit.new()
    license_key_input.name = "LicenseKey"
    license_key_input.secret = true
    license_key_input.placeholder_text = _t("ui.license.key_placeholder")
    rows.add_child(license_key_input)

    license_activate_button = Button.new()
    license_activate_button.name = "Activate"
    license_activate_button.text = _t("ui.license.activate")
    license_activate_button.pressed.connect(activate_license)
    rows.add_child(license_activate_button)

    license_retry_button = Button.new()
    license_retry_button.name = "Retry"
    license_retry_button.text = _t("ui.action.retry")
    license_retry_button.pressed.connect(retry_license)
    rows.add_child(license_retry_button)

    license_diagnostics_button = Button.new()
    license_diagnostics_button.name = "Diagnostics"
    license_diagnostics_button.text = _t("ui.license.diagnostics")
    license_diagnostics_button.pressed.connect(_open_license_diagnostics)
    rows.add_child(license_diagnostics_button)

    license_exit_button = Button.new()
    license_exit_button.name = "Exit"
    license_exit_button.text = _t("ui.action.exit")
    license_exit_button.pressed.connect(request_exit)
    rows.add_child(license_exit_button)


func _open_license_diagnostics() -> void:
    if license_key_input != null:
        license_key_input.clear()
    show_settings()

func _build_pause_panel() -> void:
    var panel := PanelContainer.new()
    panel.name = "PausePanel"
    panel.set_anchors_preset(Control.PRESET_CENTER)
    panel.offset_left = -170.0
    panel.offset_top = -240.0
    panel.offset_right = 170.0
    panel.offset_bottom = 240.0
    pause_panel = panel
    flight_hud_layer.add_child(panel)

    var rows := VBoxContainer.new()
    rows.name = "Rows"
    rows.add_theme_constant_override("separation", 6)
    panel.add_child(rows)
    var title := Label.new()
    title.text = _t("ui.pause.title")
    rows.add_child(title)
    var resume := Button.new()
    resume.name = "Resume"
    resume.text = _t("ui.pause.resume")
    resume.pressed.connect(func() -> void: set_paused(false))
    rows.add_child(resume)
    var reset := Button.new()
    reset.name = "Reset"
    reset.text = _t("ui.action.reset")
    reset.pressed.connect(respawn)
    rows.add_child(reset)
    var change_spawn_button := Button.new()
    change_spawn_button.name = "ChangeSpawn"
    change_spawn_button.text = _t("ui.action.change_spawn")
    change_spawn_button.pressed.connect(change_spawn)
    rows.add_child(change_spawn_button)
    var rates := Button.new()
    rates.name = "Rates"
    rates.text = _t("ui.settings.rates")
    rates.pressed.connect(show_rates.bind("flight"))
    rows.add_child(rates)
    var camera := Button.new()
    camera.name = "Camera"
    camera.text = _t("ui.settings.camera")
    camera.pressed.connect(show_camera.bind("flight"))
    rows.add_child(camera)
    var osd := Button.new()
    osd.name = "OSD"
    osd.text = _t("ui.settings.osd")
    osd.pressed.connect(show_osd.bind("flight"))
    rows.add_child(osd)
    var controller_monitor := Button.new()
    controller_monitor.name = "ControllerMonitor"
    controller_monitor.text = _t("ui.settings.controller_monitor")
    controller_monitor.pressed.connect(show_controller_settings.bind("flight"))
    rows.add_child(controller_monitor)
    var status_diagram_button := Button.new()
    status_diagram_button.name = "StatusDiagram"
    status_diagram_button.text = _t("ui.settings.status_diagram")
    status_diagram_button.pressed.connect(_show_status_diagram_from_pause)
    rows.add_child(status_diagram_button)
    var exit := Button.new()
    exit.name = "Exit"
    exit.text = _t("ui.action.exit")
    exit.pressed.connect(request_exit)
    rows.add_child(exit)


func _show_status_diagram_from_pause() -> void:
    if status_diagram_back_button == null:
        status_diagram_back_button = Button.new()
        status_diagram_back_button.name = "StatusDiagramBack"
        status_diagram_back_button.text = _t("ui.action.back")
        status_diagram_back_button.set_anchors_preset(Control.PRESET_TOP_LEFT)
        status_diagram_back_button.offset_left = 20.0
        status_diagram_back_button.offset_top = 20.0
        status_diagram_back_button.offset_right = 180.0
        status_diagram_back_button.offset_bottom = 60.0
        status_diagram_back_button.pressed.connect(_close_status_diagram_from_pause)
        flight_hud_layer.add_child(status_diagram_back_button)
    status_diagram_back_button.show()
    status_diagram_fullscreen = true
    if pause_panel != null:
        pause_panel.hide()
    _refresh_flight_hud()


func _close_status_diagram_from_pause() -> void:
    status_diagram_fullscreen = false
    if status_diagram_back_button != null:
        status_diagram_back_button.hide()
    if pause_panel != null:
        pause_panel.show()
    _refresh_flight_hud()


func _build_controller_safety_panel() -> void:
    var panel := PanelContainer.new()
    panel.name = "ControllerSafetyPanel"
    panel.set_anchors_preset(Control.PRESET_TOP_LEFT)
    panel.offset_left = 10.0
    panel.offset_top = 180.0
    panel.offset_right = 830.0
    panel.offset_bottom = 290.0
    controller_safety_panel = panel
    flight_hud_layer.add_child(panel)

    var rows := VBoxContainer.new()
    rows.name = "Rows"
    rows.add_theme_constant_override("separation", 6)
    panel.add_child(rows)
    controller_safety_label = Label.new()
    controller_safety_label.name = "Message"
    controller_safety_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
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
    finish_summary_label.text = _t("ui.finish.title")
    rows.add_child(finish_summary_label)
    var retry := Button.new()
    retry.name = "Retry"
    retry.text = _t("ui.action.retry")
    retry.pressed.connect(retry_time_trial)
    rows.add_child(retry)
    var change := Button.new()
    change.name = "ChangeMap"
    change.text = _t("ui.action.change_map")
    change.pressed.connect(change_map)
    rows.add_child(change)
    var exit := Button.new()
    exit.name = "Exit"
    exit.text = _t("ui.action.exit")
    exit.pressed.connect(request_exit)
    rows.add_child(exit)

func _build_status_diagram() -> void:
    status_diagram = StatusDiagramDebug.new()
    status_diagram.connect("vehicle_selected", Callable(self, "_on_dashboard_vehicle_selected"))
    add_child(status_diagram)
    status_diagram.call("set_layout_mode", dashboard_layout_mode)
    if OS.is_debug_build():
        var body_drag_panel_script = load("res://addons/debug_api/aerosim_body_drag_panel.gd")
        if body_drag_panel_script != null:
            body_drag_debug_panel = body_drag_panel_script.new()
            add_child(body_drag_debug_panel)
            if body_drag_debug_panel.has_method("set_screen_visible"):
                body_drag_debug_panel.call("set_screen_visible", screen == "lab_mode")


func _refresh_camera_panel() -> void:
    if camera_panel == null:
        return
    var angle := camera_panel.get_node_or_null("Rows/CameraAngle") as HSlider
    var fov := camera_panel.get_node_or_null("Rows/Fov") as HSlider
    var noise := camera_panel.get_node_or_null("Rows/AnalogNoise") as CheckButton
    if angle != null and not is_equal_approx(angle.value, float(camera_profile.camera_angle_deg)):
        angle.set_value_no_signal(float(camera_profile.camera_angle_deg))
    if fov != null and not is_equal_approx(fov.value, float(camera_profile.fov_deg)):
        fov.set_value_no_signal(float(camera_profile.fov_deg))
    if noise != null:
        noise.set_pressed_no_signal(bool(camera_profile.analog_noise))


func _refresh_osd_panel() -> void:
    if osd_preset_selector == null:
        return
    var preset_index := OsdProfile.PRESETS.find(String(osd_profile.preset))
    osd_preset_selector.select(preset_index)
    for element in OsdProfile.ELEMENTS:
        var toggle := osd_panel.get_node_or_null("Rows/Elements/%s" % String(element).capitalize()) as CheckButton
        if toggle != null:
            toggle.set_pressed_no_signal(bool(osd_profile.elements[element]))


func _osd_snapshot() -> Dictionary:
    if native != null and native.has_method("telemetry_snapshot"):
        return native.call("telemetry_snapshot")
    return {}


func _refresh_osd() -> void:
    if osd_labels.is_empty():
        return
    var viewport := get_viewport()
    if viewport == null:
        return
    var viewport_size := viewport.get_visible_rect().size
    var dashboard_panel := status_diagram.get_node_or_null("DashboardMargin/DashboardPanel") as Control if status_diagram != null else null
    var status_panel := flight_hud_layer.get_node_or_null("StatusMargin/StatusPanel") as Control if flight_hud_layer != null else null
    var motor_hud_visible := motor_hud_panel != null and motor_hud_panel.is_visible_in_tree()
    var body_panel := body_drag_debug_panel.get("_panel") as Control if body_drag_debug_panel != null else null
    var body_surface := body_panel.get("_scroll") as Control if body_panel != null else null
    var default_right_stack_offset_y := 0.0
    if dashboard_panel != null and dashboard_panel.is_visible_in_tree():
        default_right_stack_offset_y = maxf(0.0, dashboard_panel.get_global_rect().end.y + 8.0 - float(OsdProfile.DEFAULT_POSITIONS["battery"].y) * viewport_size.y)
    var active := screen in ["preflight", "flight", "finish", "osd"] and not (paused and screen == "flight")
    var snapshot := _osd_snapshot()
    var battery: Dictionary = snapshot.get("battery", {})
    var armed := bool(snapshot.get("armed", _flight_control_armed()))
    var mode := String(snapshot.get("mode", flight_mode))
    var lap_text := ""
    if time_trial != null:
        var trial_state := _t("ui.hud.time_trial_finished") if time_trial.finished else _format("ui.hud.time_trial_next", [time_trial.next_checkpoint_index + 1, time_trial.checkpoint_positions.size()])
        lap_text = _format("ui.osd.lap", [trial_state])
    var values := {
        "battery": _format("ui.osd.battery", [float(battery.get("voltage_v", 0.0)), float(battery.get("sag_v", 0.0)), float(battery.get("remaining_mah", 0.0))]),
        "armed": _format("ui.osd.armed", [_localized_arm_state(armed)]),
        "flight_mode": _format("ui.osd.mode", [_localized_flight_mode(mode)]),
        "timer": _format("ui.osd.timer", [time_trial.elapsed_seconds if time_trial != null else 0.0]),
        "lap_checkpoint": lap_text,
        "signal": _t("ui.osd.signal_live") if not snapshot.is_empty() else _t("ui.osd.signal_offline"),
        "warnings": _localize_fallback_message(last_error_message) if not last_error_message.is_empty() else _t("ui.osd.ready"),
        "reset_hint": _t("ui.osd.reset_hint"),
    }
    for element in OsdProfile.ELEMENTS:
        var label: Label = osd_labels[element]
        label.text = String(values[element])
        label.visible = active and bool(osd_profile.elements[element]) and not (time_trial == null and element in ["timer", "lap_checkpoint"])
        var position: Dictionary = osd_profile.positions[element]
        label.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
        label.size = Vector2(minf(280.0, viewport_size.x * 0.24), 56.0 if element == "warnings" else 28.0)
        label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART if element == "warnings" else TextServer.AUTOWRAP_OFF
        var label_position := Vector2(float(position.x) * viewport_size.x, float(position.y) * viewport_size.y)
        if element in ["battery", "armed", "flight_mode", "signal"] and position == OsdProfile.DEFAULT_POSITIONS[element]:
            label_position.y += default_right_stack_offset_y
        if element == "warnings" and position == OsdProfile.DEFAULT_POSITIONS["warnings"]:
            var rendered_height := maxf(label.size.y, label.get_combined_minimum_size().y)
            if status_panel != null and status_panel.is_visible_in_tree():
                label_position.y = maxf(label_position.y, status_panel.get_global_rect().end.y + 8.0)
            if body_surface != null and body_surface.is_visible_in_tree():
                label_position.y = minf(label_position.y, body_surface.get_global_rect().position.y - rendered_height - 8.0)
        if element == "reset_hint" and motor_hud_visible and position == OsdProfile.DEFAULT_POSITIONS["reset_hint"]:
            label_position = Vector2(viewport_size.x * 0.35, maxf(viewport_size.y * 0.16, status_panel.get_global_rect().end.y + 8.0) if status_panel != null and status_panel.is_visible_in_tree() else viewport_size.y * 0.16)
        label.position = label_position
    if analog_noise_overlay != null:
        analog_noise_overlay.visible = active and bool(camera_profile.analog_noise)



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


func validate_quick_adjust_profile(candidate: Variant) -> Dictionary:
    var profile_result := InputProfiles.QuickAdjustProfile.validate_profile(candidate)
    if not bool(profile_result.get("ok", false)):
        return profile_result
    if _gsp_external_authority_active():
        return {"ok": false, "error": "external_authority", "authority": "px4"}
    var profile: Dictionary = profile_result.profile
    for slot_index in profile.slots.size():
        var slot_value = profile.slots[slot_index]
        if slot_value == null:
            continue
        var slot: Dictionary = slot_value
        var parameter := String(slot.parameter)
        var descriptor: Dictionary = {}
        for descriptor_value in _gsp_tuning_registry:
            var candidate_descriptor: Dictionary = descriptor_value
            if String(candidate_descriptor.get("key", "")) == parameter:
                descriptor = candidate_descriptor
                break
        if descriptor.is_empty():
            return {"ok": false, "error": "unknown_parameter", "slot": slot_index}
        if not bool(descriptor.get("quick_adjust_eligible", false)):
            return {"ok": false, "error": "quick_adjust_ineligible", "slot": slot_index, "parameter": parameter}
        var timing := String(descriptor.get("apply_timing", "unknown"))
        if timing in ["reset_required", "restart_required"]:
            return {"ok": false, "error": timing, "slot": slot_index, "parameter": parameter}
        var descriptor_min := float(descriptor.get("min", NAN))
        var descriptor_max := float(descriptor.get("max", NAN))
        if not is_finite(descriptor_min) or not is_finite(descriptor_max) or \
                float(slot.subset_min) < descriptor_min or float(slot.subset_max) > descriptor_max:
            return {"ok": false, "error": "quick_adjust_subset_out_of_descriptor", "slot": slot_index}
        if float(slot.rate_limit) > 120.0:
            return {"ok": false, "error": "quick_adjust_rate_limit_too_high", "slot": slot_index}
        if String(slot.binding_type) == "key_pair":
            for key_value in [int(slot.negative_key), int(slot.positive_key)]:
                for action_name in InputMap.get_actions():
                    if not String(action_name).begins_with("flight_"):
                        continue
                    for event_value in InputMap.action_get_events(action_name):
                        if event_value is InputEventKey:
                            var event := event_value as InputEventKey
                            if int(event.keycode) == key_value or int(event.physical_keycode) == key_value:
                                return {"ok": false, "error": "quick_adjust_binding_conflict", "slot": slot_index, "action": String(action_name)}
        else:
            if int(slot.axis) in [0, 1, 2, 3]:
                return {"ok": false, "error": "quick_adjust_binding_conflict", "slot": slot_index, "axis": int(slot.axis)}
            if _has_active_gamepad_profile() and int(slot.device) == session_gamepad_device_id and int(slot.axis) in session_gamepad_profile.axis_for_role.values():
                return {"ok": false, "error": "quick_adjust_binding_conflict", "slot": slot_index}
    return {"ok": true, "error": "", "profile": profile.duplicate(true)}


func configure_quick_adjust(candidate: Variant, persist: bool = true) -> Dictionary:
    var validation := validate_quick_adjust_profile(candidate)
    if not bool(validation.get("ok", false)):
        return validation
    var profile: Dictionary = validation.profile
    if _replay_recording_active and native != null and native.has_method("record_replay_quick_adjust_binding"):
        if not _set_replay_physics_tick():
            return {"ok": false, "error": "replay_recording_failed", "detail": _replay_recording_failure}
        var replay_result: Dictionary = native.call(
                "record_replay_quick_adjust_binding", _replay_timestamp_us(), _replay_canonical_json(profile))
        if not bool(replay_result.get("ok", false)):
            _fail_replay_recording(String(replay_result.get("diagnostic_message", "Quick Adjust binding recording failed")))
            return {"ok": false, "error": "replay_recording_failed", "detail": _replay_recording_failure}
    if persist:
        if settings_store == null:
            if _replay_recording_active:
                _fail_replay_recording("Quick Adjust settings persistence is unavailable")
                return {"ok": false, "error": "replay_recording_failed", "detail": _replay_recording_failure}
            return {"ok": false, "error": "settings_unavailable"}
        var loaded: Dictionary = settings_store.load_document()
        if not bool(loaded.get("ok", false)):
            if _replay_recording_active:
                _fail_replay_recording("Quick Adjust settings could not be loaded")
                return {"ok": false, "error": "replay_recording_failed", "detail": _replay_recording_failure}
            return {"ok": false, "error": "settings_unavailable", "detail": loaded.get("error", "")}
        loaded.document["quick_adjust"] = profile.duplicate(true)
        var saved: Dictionary = settings_store.save_document(loaded.document)
        if not bool(saved.get("ok", false)):
            if _replay_recording_active:
                _fail_replay_recording("Quick Adjust settings could not be saved")
                return {"ok": false, "error": "replay_recording_failed", "detail": _replay_recording_failure}
            return {"ok": false, "error": "settings_save_failed", "detail": saved.get("error", "")}
    _quick_adjust_profile = profile.duplicate(true)
    _reset_quick_adjust_rate_limits()
    return {"ok": true, "profile": _quick_adjust_profile.duplicate(true)}


func gsp_quick_adjust_request(peer_id: int, connection_id: int, request_seq: int, profile: Variant) -> Dictionary:
    var result := configure_quick_adjust(profile)
    result["peer_id"] = peer_id
    result["connection_id"] = connection_id
    result["request_seq"] = request_seq
    return result


func gsp_marker_request(peer_id: int, connection_id: int, request_seq: int, label: String, note: String = "") -> Dictionary:
    var result := {"peer_id": peer_id, "connection_id": connection_id, "request_seq": request_seq}
    if not _replay_recording_active or native == null or not native.has_method("record_replay_marker"):
        result["ok"] = false
        result["error"] = "replay_unavailable"
        return result
    if not _set_replay_physics_tick():
        result["ok"] = false
        result["error"] = "replay_recording_failed"
        return result
    var recorded: Dictionary = native.call("record_replay_marker", _replay_timestamp_us(), label, note)
    for key in recorded:
        result[key] = recorded[key]
    if not bool(recorded.get("ok", false)):
        _fail_replay_recording(String(recorded.get("diagnostic_message", "marker recording failed")))
    return result


func gsp_simulation_request(peer_id: int, connection_id: int, request_seq: int, command: String) -> Dictionary:
    var result := {"peer_id": peer_id, "connection_id": connection_id, "request_seq": request_seq, "cmd": command}
    if command not in ["pause", "resume"]:
        result["ok"] = false
        result["error"] = "unsupported_simulation_command"
        return result
    var was_paused := paused
    if not _set_paused_checked(command == "pause"):
        result["ok"] = false
        result["error"] = "replay_recording_failed"
        return result
    result["ok"] = true
    result["changed"] = was_paused != paused
    return result


func gsp_quick_adjust_profile() -> Dictionary:
    return _quick_adjust_profile.duplicate(true)


func _reset_quick_adjust_rate_limits() -> void:
    _quick_adjust_next_allowed_usec.clear()
    for _index in InputProfiles.QuickAdjustProfile.SLOT_COUNT:
        _quick_adjust_next_allowed_usec.append(0)


func _quick_adjust_input(slot: Dictionary) -> float:
    var input_value := 0.0
    if String(slot.binding_type) == "axis":
        var axis_key := "%d:%d" % [int(slot.device), int(slot.axis)]
        input_value = float(_quick_adjust_axis_values.get(axis_key, Input.get_joy_axis(int(slot.device), int(slot.axis))))
    else:
        if bool(_quick_adjust_pressed_keys.get(int(slot.positive_key), false)) or Input.is_key_pressed(int(slot.positive_key)):
            input_value += 1.0
        if bool(_quick_adjust_pressed_keys.get(int(slot.negative_key), false)) or Input.is_key_pressed(int(slot.negative_key)):
            input_value -= 1.0
    var deadzone := float(slot.deadzone)
    if absf(input_value) <= deadzone:
        return 0.0
    return sign(input_value) * ((absf(input_value) - deadzone) / (1.0 - deadzone))


func _quick_adjust_value(slot: Dictionary, current: float, input_value: float) -> float:
    if String(slot.mode) == "absolute":
        return lerpf(float(slot.subset_min), float(slot.subset_max), (input_value + 1.0) * 0.5)
    return current + input_value * float(slot.step)


func _apply_quick_adjust_inputs(_delta: float) -> void:
    if native == null or screen != "flight" or paused or _gsp_external_authority_active():
        return
    var slots: Array = _quick_adjust_profile.get("slots", [])
    var has_binding := false
    for slot_value in slots:
        if slot_value != null:
            has_binding = true
            break
    if not has_binding:
        return
    var active_values: Dictionary = native.call("flight_tuning_configuration") if native.has_method("flight_tuning_configuration") else {}
    var now_usec := Time.get_ticks_usec()
    for slot_index in slots.size():
        var slot_value = slots[slot_index]
        if slot_value == null:
            continue
        var slot: Dictionary = slot_value
        var input_value := _quick_adjust_input(slot)
        if is_zero_approx(input_value) or now_usec < int(_quick_adjust_next_allowed_usec[slot_index]):
            continue
        var parameter := String(slot.parameter)
        if not active_values.has(parameter):
            continue
        var current := float(active_values[parameter])
        var target := _quick_adjust_value(slot, current, input_value)
        target = clampf(target, float(slot.subset_min), float(slot.subset_max))
        target = clampf(snappedf(target - float(slot.subset_min), float(slot.step)) + float(slot.subset_min), float(slot.subset_min), float(slot.subset_max))
        if is_equal_approx(target, current):
            continue
        _quick_adjust_request_seq += 1
        var result := gsp_tuning_request(-1, -1, _quick_adjust_request_seq, parameter, target, "quick_adjust", slot_index)
        if bool(result.get("ok", false)):
            _quick_adjust_next_allowed_usec[slot_index] = now_usec + int(1_000_000.0 / float(slot.rate_limit))
            _quick_adjust_active_slot = slot_index
            _quick_adjust_last_value = target


func gsp_tuning_request(peer_id: int, connection_id: int, request_seq: int, parameter: Variant, value: Variant = null, source: String = "panel", quick_adjust_slot: int = -1) -> Dictionary:
    if typeof(parameter) == TYPE_ARRAY:
        return gsp_tuning_batch_request(peer_id, connection_id, request_seq, parameter, source, quick_adjust_slot)
    return gsp_tuning_batch_request(peer_id, connection_id, request_seq, [{"parameter": parameter, "value": value}], source, quick_adjust_slot)


func gsp_tuning_batch_request(peer_id: int, connection_id: int, request_seq: int, changes: Array, source: String = "panel", quick_adjust_slot: int = -1, atomic_barrier: bool = false, preset_provenance: Dictionary = {}) -> Dictionary:
    _sync_native_external_authority()
    if _gsp_external_authority_active():
        var result := {
            "peer_id": peer_id,
            "connection_id": connection_id,
            "request_seq": request_seq,
            "ok": false,
            "error": "external_authority",
            "authority": "px4",
        }
        _remember_gsp_tuning_result(result)
        return result
    var timing_result := _gsp_tuning_timings(changes)
    if not bool(timing_result.get("ok", false)):
        var invalid_timing := {
            "peer_id": peer_id,
            "connection_id": connection_id,
            "request_seq": request_seq,
            "ok": false,
            "error": String(timing_result.get("error", "invalid_apply_timing")),
        }
        _remember_gsp_tuning_result(invalid_timing)
        return invalid_timing
    var apply_timing := String(timing_result.get("apply_timing", "unknown"))
    if apply_timing == "restart_required" or apply_timing == "reset_required":
        var deferred_result := {
            "peer_id": peer_id,
            "connection_id": connection_id,
            "request_seq": request_seq,
            "ok": false,
            "error": apply_timing,
            "apply_timing": apply_timing,
        }
        _remember_gsp_tuning_result(deferred_result)
        return deferred_result
    if apply_timing == "immediate" or paused:
        var provenance: Dictionary = preset_provenance.duplicate(true)
        for change_value in changes:
            if typeof(change_value) == TYPE_DICTIONARY:
                var key := String(change_value.get("parameter", ""))
                if not provenance.has(key):
                    provenance[key] = {
                        "source": source,
                        "request_seq": request_seq,
                        "quick_adjust_slot": quick_adjust_slot,
                        "request_id": 0,
                    }
        return _commit_gsp_tuning_batch(peer_id, connection_id, request_seq, changes, _gsp_public_physics_tick(), true, source, quick_adjust_slot, provenance)
    _gsp_tuning_pending.append({
        "peer_id": peer_id,
        "connection_id": connection_id,
        "request_seq": request_seq,
        "changes": changes.duplicate(true),
        "source": source,
        "quick_adjust_slot": quick_adjust_slot,
        "atomic_barrier": atomic_barrier,
        "provenance": preset_provenance.duplicate(true),
    })
    return {"ok": true, "pending": true, "apply_timing": apply_timing}


func gsp_tuning_results() -> Array:
    var results := _gsp_tuning_completed.duplicate(true)
    _gsp_tuning_completed.clear()
    return results


func _apply_gsp_tuning_requests(public_physics_tick: int) -> void:
    if _gsp_tuning_pending.is_empty():
        return
    var pending := _gsp_tuning_pending
    _gsp_tuning_pending = []
    var ordinary_group: Array[Dictionary] = []
    var deferred_group: Array[Dictionary] = []
    var migration_keys: Dictionary = {}
    for request in pending:
        if bool(request.get("atomic_barrier", false)):
            _commit_gsp_tuning_group(ordinary_group, public_physics_tick)
            ordinary_group.clear()
            var migration_changes: Array = request.get("changes", [])
            var migration_provenance: Dictionary = request.get("provenance", {}).duplicate(true)
            for change_value in migration_changes:
                if typeof(change_value) == TYPE_DICTIONARY:
                    var migration_change: Dictionary = change_value
                    var migration_key := String(migration_change.get("parameter", ""))
                    migration_keys[migration_key] = true
                    if not migration_provenance.has(migration_key):
                        migration_provenance[migration_key] = {
                            "source": "preset",
                            "request_seq": int(request.get("request_seq", -1)),
                            "quick_adjust_slot": -1,
                            "request_id": 0,
                        }
            var migration_commit := _commit_gsp_tuning_batch(
                    -1, -1, -1, migration_changes, public_physics_tick, false, "preset", -1,
                    migration_provenance)
            var migration_ack := _gsp_tuning_request_ack(migration_commit, request)
            migration_ack["commit_request_seq"] = int(migration_commit.get("request_seq", -1))
            migration_ack["peer_id"] = int(request.get("peer_id", -1))
            migration_ack["connection_id"] = int(request.get("connection_id", -1))
            migration_ack["request_seq"] = int(request.get("request_seq", -1))
            migration_ack["coalesced"] = false
            _remember_gsp_tuning_result(migration_ack)
            _gsp_tuning_completed.append(migration_ack)
            continue
        var conflicts_with_migration := false
        for change_value in request.get("changes", []):
            if typeof(change_value) == TYPE_DICTIONARY and migration_keys.has(String(change_value.get("parameter", ""))):
                conflicts_with_migration = true
                break
        if conflicts_with_migration:
            _commit_gsp_tuning_group(ordinary_group, public_physics_tick)
            ordinary_group.clear()
            deferred_group.append(request)
        else:
            ordinary_group.append(request)
    _commit_gsp_tuning_group(ordinary_group, public_physics_tick)
    _gsp_tuning_pending.append_array(deferred_group)


func _commit_gsp_tuning_group(pending: Array[Dictionary], public_physics_tick: int) -> void:
    if pending.is_empty():
        return
    var coalesced: Dictionary = {}
    var provenance: Dictionary = {}
    var ordered_keys: Array[String] = []
    for request_index in pending.size():
        var request: Dictionary = pending[request_index]
        for change_value in request.get("changes", []):
            var change: Dictionary = change_value
            var key := String(change.get("parameter", ""))
            if not coalesced.has(key):
                ordered_keys.append(key)
            coalesced[key] = {"parameter": key, "value": change.get("value", null)}
            provenance[key] = {
                "source": String(request.get("source", "panel")),
                "request_seq": int(request.get("request_seq", -1)),
                "quick_adjust_slot": int(request.get("quick_adjust_slot", -1)),
                "request_id": request_index,
            }
    var changes: Array = []
    for key in ordered_keys:
        changes.append(coalesced[key])
    var commit := _commit_gsp_tuning_batch(
            -1, -1, -1, changes, public_physics_tick, false, "mixed", -1, provenance)
    for request in pending:
        var acknowledged := _gsp_tuning_request_ack(commit, request)
        acknowledged["commit_request_seq"] = int(commit.get("request_seq", -1))
        acknowledged["peer_id"] = int(request.get("peer_id", -1))
        acknowledged["connection_id"] = int(request.get("connection_id", -1))
        acknowledged["request_seq"] = int(request.get("request_seq", -1))
        acknowledged["coalesced"] = pending.size() > 1
        _remember_gsp_tuning_result(acknowledged)
        _gsp_tuning_completed.append(acknowledged)


func _commit_gsp_tuning_batch(peer_id: int, connection_id: int, request_seq: int, changes: Array, public_physics_tick: int, remember_result: bool = true, source: String = "panel", quick_adjust_slot: int = -1, provenance: Dictionary = {}) -> Dictionary:
    var result: Dictionary = {"peer_id": peer_id, "connection_id": connection_id, "request_seq": request_seq}
    _sync_native_external_authority()
    if _gsp_external_authority_active():
        result["ok"] = false
        result["error"] = "external_authority"
        result["authority"] = "px4"
        if remember_result:
            _remember_gsp_tuning_result(result)
        return result
    var timing_result := _gsp_tuning_timings(changes)
    if not bool(timing_result.get("ok", false)):
        result["ok"] = false
        result["error"] = String(timing_result.get("error", "invalid_apply_timing"))
        if remember_result:
            _remember_gsp_tuning_result(result)
        return result
    var timing := String(timing_result.get("apply_timing", "unknown"))
    if timing == "reset_required" or timing == "restart_required":
        result["ok"] = false
        result["error"] = timing
        result["apply_timing"] = timing
        if remember_result:
            _remember_gsp_tuning_result(result)
        return result
    if native == null or not native.has_method("stage_flight_tuning_batch") or not native.has_method("commit_flight_tuning"):
        result["ok"] = false
        result["error"] = "tuning_unavailable"
        if remember_result:
            _remember_gsp_tuning_result(result)
        return result
    var preset_migration := false
    var preset_keys: Dictionary = {}
    for change_value in changes:
        if typeof(change_value) != TYPE_DICTIONARY:
            continue
        var change: Dictionary = change_value
        var key := String(change.get("parameter", ""))
        var metadata: Dictionary = provenance.get(key, {})
        if metadata.has("preset_original"):
            preset_migration = true
            preset_keys[key] = true
            var descriptor: Dictionary = {}
            for descriptor_value in _gsp_tuning_registry:
                if String(descriptor_value.get("key", "")) == key:
                    descriptor = descriptor_value
                    break
            var staged_value := float(change.get("value", NAN))
            if descriptor.is_empty() or not metadata.has("requested_value") or not metadata.has("staged_value") or \
                    not metadata.has("corrected_value") or metadata.get("staged_value") != metadata.get("corrected_value") or \
                    staged_value != float(metadata.get("staged_value", NAN)) or not is_finite(staged_value) or \
                    staged_value < float(descriptor.get("min", INF)) or staged_value > float(descriptor.get("max", -INF)) or \
                    not is_finite(float(metadata.get("requested_value", NAN))):
                result["ok"] = false
                result["error"] = "migration_invariant"
                if remember_result:
                    _remember_gsp_tuning_result(result)
                return result
    if preset_migration and (preset_keys.size() != _gsp_tuning_registry.size() or not _gsp_preset_values_match_registry(_changes_to_values(changes), true) or provenance.size() != changes.size()):
        result["ok"] = false
        result["error"] = "migration_invariant"
        if remember_result:
            _remember_gsp_tuning_result(result)
        return result
    var staged_result: Dictionary = native.call("stage_flight_tuning_batch", changes)
    if not bool(staged_result.get("ok", false)):
        for key in staged_result:
            result[key] = staged_result[key]
        if remember_result:
            _remember_gsp_tuning_result(result)
        return result
    var native_commit_started_usec := Time.get_ticks_usec()
    var native_result: Dictionary = native.call("commit_flight_tuning", public_physics_tick)
    var native_commit_finished_usec := Time.get_ticks_usec()
    for key in native_result:
        result[key] = native_result[key]
    if bool(native_result.get("ok", false)):
        result["native_commit_monotonic_usec"] = native_commit_finished_usec
        result["native_commit_latency_ms"] = float(native_commit_finished_usec - native_commit_started_usec) / 1000.0
        if _replay_recording_active and not _set_replay_physics_tick():
            result["ok"] = false
            result["error"] = "replay_recording_failed"
            result["diagnostic_message"] = _replay_recording_failure
            if remember_result:
                _remember_gsp_tuning_result(result)
            return result
        result["apply_timing"] = _gsp_tuning_timings(changes).get("apply_timing", "unknown")
        var winners: Array = []
        var enriched_changes: Array = []
        for change_value in native_result.get("changes", []):
            var change: Dictionary = change_value.duplicate(true)
            var parameter := String(change.get("parameter", ""))
            var winner: Dictionary = provenance.get(parameter, {
                "source": source,
                "request_seq": request_seq,
                "quick_adjust_slot": quick_adjust_slot,
                "request_id": 0,
            })
            change["source"] = String(winner.get("source", source))
            change["request_seq"] = int(winner.get("request_seq", request_seq))
            if preset_migration:
                var native_clamped := bool(change.get("clamped", false))
                var clamp_reason: Array = winner.get("clamp_reason", [])
                change["native_requested_value"] = change.get("requested_value", null)
                change["native_clamped"] = native_clamped
                change["native_clamp_reason"] = change.get("native_clamp_reason", "")
                change["requested_value"] = winner.get("requested_value")
                change["staged_value"] = winner.get("staged_value")
                change["corrected_value"] = winner.get("corrected_value")
                change["clamp_reason"] = clamp_reason.duplicate(true)
                change["clamped"] = native_clamped or not clamp_reason.is_empty()
            var winner_slot := int(winner.get("quick_adjust_slot", -1))
            if winner_slot >= 0:
                change["quick_adjust_slot"] = winner_slot
            enriched_changes.append(change)
            winners.append(winner)
        var winner_sources: Array[String] = []
        var common_slot := -1
        var all_winners_have_one_slot := not winners.is_empty()
        var winner_requests: Array[String] = []
        for winner in winners:
            var winner_source := String(winner.get("source", source))
            if winner_source not in winner_sources:
                winner_sources.append(winner_source)
            var winner_slot := int(winner.get("quick_adjust_slot", -1))
            if winner_slot < 0:
                all_winners_have_one_slot = false
            elif common_slot < 0:
                common_slot = winner_slot
            elif common_slot != winner_slot:
                all_winners_have_one_slot = false
            var winner_request_id := str(int(winner.get("request_id", 0)))
            if winner_request_id not in winner_requests:
                winner_requests.append(winner_request_id)
        result["changes"] = enriched_changes
        if preset_migration and not enriched_changes.is_empty():
            var committed_keys: Dictionary = {}
            for change_value in enriched_changes:
                var committed_change: Dictionary = change_value
                var committed_key := String(committed_change.get("parameter", ""))
                committed_keys[committed_key] = true
                if not preset_keys.has(committed_key) or not native_result.get("committed_values", {}).has(committed_key) or \
                        float(native_result.committed_values[committed_key]) != float(provenance[committed_key].get("staged_value", NAN)):
                    result["ok"] = false
                    result["error"] = "migration_invariant"
                    if remember_result:
                        _remember_gsp_tuning_result(result)
                    return result
            if committed_keys != preset_keys:
                result["ok"] = false
                result["error"] = "migration_invariant"
                if remember_result:
                    _remember_gsp_tuning_result(result)
                return result
            var first_preset_change: Dictionary = enriched_changes[0]
            for field in ["requested_value", "staged_value", "corrected_value", "clamp_reason", "native_clamped", "native_clamp_reason", "clamped"]:
                if first_preset_change.has(field):
                    result[field] = first_preset_change[field]
        result["source"] = winner_sources[0] if winner_sources.size() == 1 else "mixed"
        if all_winners_have_one_slot and common_slot >= 0:
            result["quick_adjust_slot"] = common_slot
        if winner_requests.size() == 1 and winners.size() > 0:
            result["request_seq"] = int(winners[0].get("request_seq", request_seq))
        else:
            result.erase("request_seq")
        if bool(native_result.get("changed", false)) and _replay_recording_active and native.has_method("record_replay_tuning"):
            for change_value in enriched_changes:
                var change: Dictionary = change_value
                var replay_timestamp_us := _replay_timestamp_us()
                var replay_result: Dictionary = native.call(
                        "record_replay_tuning",
                        replay_timestamp_us,
                        _airsim_vehicle_name,
                        int(change.get("request_seq", request_seq)),
                        int(native_result.get("commit_id", 0)),
                        String(change.get("parameter", "")),
                        float(change.get("requested_value", 0.0)),
                        float(change.get("committed_value", 0.0)),
                        bool(change.get("clamped", false)),
                        String(change.get("source", source)),
                        int(change.get("quick_adjust_slot", -1)))
                if not bool(replay_result.get("ok", false)):
                    _fail_replay_recording(String(replay_result.get("diagnostic_message", "tuning recording failed")))
                    result["ok"] = false
                    result["error"] = "replay_recording_failed"
                    result["diagnostic_message"] = _replay_recording_failure
                    if remember_result:
                        _remember_gsp_tuning_result(result)
                    return result
        if source == "quick_adjust" and bool(native_result.get("changed", false)):
            _quick_adjust_active_slot = quick_adjust_slot
            _quick_adjust_last_value = float(native_result.get("committed_value", _quick_adjust_last_value))
    var acknowledged := _gsp_tuning_request_ack(result, {"changes": changes})
    if remember_result:
        _remember_gsp_tuning_result(acknowledged)
    return acknowledged


func _gsp_tuning_timings(changes: Array) -> Dictionary:
    if changes.is_empty():
        return {"ok": false, "error": "empty_tuning_batch"}
    var timings: Array[String] = []
    for change_value in changes:
        if typeof(change_value) != TYPE_DICTIONARY:
            return {"ok": false, "error": "malformed_tuning_batch"}
        var change: Dictionary = change_value
        var parameter := String(change.get("parameter", ""))
        var timing := _gsp_tuning_descriptor_timing(parameter)
        if timing == "unknown":
            return {"ok": false, "error": "unknown_parameter"}
        if timing not in timings:
            timings.append(timing)
    if timings.size() != 1:
        return {"ok": false, "error": "mixed_apply_timing"}
    var timing := timings[0]
    if timing not in ["immediate", "next_physics_step", "reset_required", "restart_required"]:
        return {"ok": false, "error": "invalid_apply_timing"}
    return {"ok": true, "apply_timing": timing}


func _gsp_tuning_request_ack(commit: Dictionary, request: Dictionary) -> Dictionary:
    var acknowledged := commit.duplicate(true)
    var requested_values: Dictionary = {}
    var keys: Array[String] = []
    for change_value in request.get("changes", []):
        if typeof(change_value) != TYPE_DICTIONARY:
            continue
        var change: Dictionary = change_value
        var key := String(change.get("parameter", ""))
        if key not in keys:
            keys.append(key)
        requested_values[key] = change.get("value", null)
    var committed_values: Dictionary = commit.get("committed_values", commit.get("values", {}))
    var request_changes: Array = []
    for key in keys:
        if not committed_values.has(key):
            continue
        var committed_change: Dictionary = {}
        for change_value in commit.get("changes", []):
            if typeof(change_value) == TYPE_DICTIONARY and String(change_value.get("parameter", "")) == key:
                committed_change = change_value.duplicate(true)
                break
        if committed_change.is_empty():
            committed_change = {"parameter": key, "committed_value": committed_values[key], "changed": true}
        if requested_values.has(key) and (not committed_change.has("staged_value") or not committed_change.has("requested_value")):
            committed_change["requested_value"] = requested_values[key]
        request_changes.append(committed_change)
    var request_values: Dictionary = {}
    for key in keys:
        if committed_values.has(key):
            request_values[key] = committed_values[key]
    acknowledged["changes"] = request_changes
    acknowledged["values"] = request_values
    acknowledged["committed_values"] = request_values
    acknowledged["commit_changes"] = commit.get("changes", []).duplicate(true)
    acknowledged["commit_values"] = committed_values.duplicate(true)
    var changed := false
    for change_value in request_changes:
        changed = changed or bool(change_value.get("changed", true))
    acknowledged["changed"] = changed
    if request_changes.size() == 1:
        var scalar: Dictionary = request_changes[0]
        for key in ["parameter", "requested_value", "staged_value", "corrected_value", "clamp_reason", "native_clamped", "native_clamp_reason", "committed_value", "clamped"]:
            if scalar.has(key):
                acknowledged[key] = scalar[key]
    else:
        for key in ["parameter", "requested_value", "staged_value", "corrected_value", "clamp_reason", "native_clamped", "native_clamp_reason", "committed_value", "clamped"]:
            acknowledged.erase(key)
    return acknowledged


func _gsp_tuning_descriptor_timing(parameter: String) -> String:
    for descriptor_value in _gsp_tuning_registry:
        var descriptor: Dictionary = descriptor_value
        if String(descriptor.get("key", "")) == parameter:
            return String(descriptor.get("apply_timing", "unknown"))
    return "unknown"


func _gsp_active_tuning_values() -> Dictionary:
    var active: Dictionary = native.call("flight_tuning_configuration") if native != null and native.has_method("flight_tuning_configuration") else {}
    var values: Dictionary = {}
    for descriptor_value in _gsp_tuning_registry:
        var descriptor: Dictionary = descriptor_value
        var key := String(descriptor.get("key", ""))
        if active.has(key):
            values[key] = float(active[key])
    return values


func gsp_list_presets() -> Dictionary:
    return GspPresetStore.new().list_presets()


func gsp_save_preset(name: String, note: String = "") -> Dictionary:
    var values := _gsp_active_tuning_values()
    if not _gsp_preset_values_match_registry(values):
        return {"ok": false, "error": "tuning_unavailable"}
    var sim_version := String(ProjectSettings.get_setting("application/config/version", "")).strip_edges()
    if sim_version.is_empty():
        sim_version = "unavailable"
    return GspPresetStore.new().save_preset(
            name,
            values,
            _gsp_tuning_registry_hash,
            sim_version,
            note)


func gsp_retrieve_preset(name: String) -> Dictionary:
    return GspPresetStore.new().retrieve_preset(name)


func gsp_compare_presets(left_name: String, right_name: String) -> Dictionary:
    var store := GspPresetStore.new()
    var left_values := _gsp_active_tuning_values() if left_name.is_empty() else {}
    if not left_name.is_empty():
        var left_result: Dictionary = store.retrieve_preset(left_name)
        if not bool(left_result.get("ok", false)):
            return left_result
        var left_preset: Dictionary = left_result.preset
        if String(left_preset.get("registry_hash", "")) != _gsp_tuning_registry_hash:
            return {"ok": false, "error": "registry_mismatch"}
        if not _gsp_preset_values_match_registry(left_preset.get("values", {})):
            return {"ok": false, "error": "registry_values_mismatch"}
        left_values = left_preset.values
    var right_values := _gsp_active_tuning_values() if right_name.is_empty() else {}
    if not right_name.is_empty():
        var right_result: Dictionary = store.retrieve_preset(right_name)
        if not bool(right_result.get("ok", false)):
            return right_result
        var right_preset: Dictionary = right_result.preset
        if String(right_preset.get("registry_hash", "")) != _gsp_tuning_registry_hash:
            return {"ok": false, "error": "registry_mismatch"}
        if not _gsp_preset_values_match_registry(right_preset.get("values", {})):
            return {"ok": false, "error": "registry_values_mismatch"}
        right_values = right_preset.values
    return {
        "ok": true,
        "left": left_name if not left_name.is_empty() else "current",
        "right": right_name if not right_name.is_empty() else "current",
        "changes": GspPresetStore.diff_values(left_values, right_values),
    }


func gsp_load_preset(peer_id: int, connection_id: int, request_seq: int, name: String) -> Dictionary:
    var loaded: Dictionary = gsp_retrieve_preset(name)
    if not bool(loaded.get("ok", false)):
        loaded["peer_id"] = peer_id
        loaded["connection_id"] = connection_id
        loaded["request_seq"] = request_seq
        return loaded
    var preset: Dictionary = loaded.preset
    if String(preset.get("registry_hash", "")) != _gsp_tuning_registry_hash:
        return {"ok": false, "error": "registry_mismatch", "peer_id": peer_id, "connection_id": connection_id, "request_seq": request_seq}
    if not _gsp_preset_values_match_registry(preset.get("values", {})):
        return {"ok": false, "error": "registry_values_mismatch", "peer_id": peer_id, "connection_id": connection_id, "request_seq": request_seq}
    var changes: Array = []
    for descriptor_value in _gsp_tuning_registry:
        var descriptor: Dictionary = descriptor_value
        var key := String(descriptor.get("key", ""))
        if preset.values.has(key):
            changes.append({"parameter": key, "value": preset.values[key]})
    return gsp_tuning_batch_request(peer_id, connection_id, request_seq, changes, "preset", -1)


func gsp_preview_preset_migration(name: String) -> Dictionary:
    var loaded: Dictionary = gsp_retrieve_preset(name)
    if not bool(loaded.get("ok", false)):
        return loaded
    var preset: Dictionary = loaded.preset
    var classification := GspPresetStore.classify_migration(preset.get("values", {}), _gsp_tuning_registry)
    if not bool(classification.get("ok", false)):
        return classification
    _prune_gsp_migration_capabilities()
    var migration_id := _new_gsp_migration_id()
    _gsp_migration_capabilities.append({
        "id": migration_id,
        "name": name,
        "content_hash": String(loaded.get("content_hash", "")),
        "registry_hash": _gsp_tuning_registry_hash,
        "values": classification.values.duplicate(true),
        "corrections": classification.corrections.duplicate(true),
        "created_at_ms": Time.get_ticks_msec(),
        "expires_at_ms": Time.get_ticks_msec() + GSP_MIGRATION_CAPABILITY_TTL_MS,
    })
    while _gsp_migration_capabilities.size() > GSP_MIGRATION_CAPABILITY_LIMIT:
        _gsp_expired_migration_ids.append(String(_gsp_migration_capabilities.pop_front().id))
        _trim_gsp_migration_id_history(_gsp_expired_migration_ids)
    classification.erase("values")
    classification.erase("requested_values")
    classification["ok"] = true
    classification["operation"] = "preview_preset_migration"
    classification["preset_name"] = name
    classification["preset_registry_hash"] = String(preset.get("registry_hash", ""))
    classification["registry_mismatch"] = String(preset.get("registry_hash", "")) != _gsp_tuning_registry_hash
    classification["registry_hash"] = _gsp_tuning_registry_hash
    classification["migration_id"] = migration_id
    classification["expires_in_ms"] = GSP_MIGRATION_CAPABILITY_TTL_MS
    return classification


func gsp_apply_preset_migration(peer_id: int, connection_id: int, request_seq: int, name: String, migration_id: String, confirmed: bool) -> Dictionary:
    var invalid_context := {"peer_id": peer_id, "connection_id": connection_id, "request_seq": request_seq}
    if not confirmed:
        invalid_context["ok"] = false
        invalid_context["error"] = "migration_confirmation_required"
        return invalid_context
    if migration_id.is_empty():
        invalid_context["ok"] = false
        invalid_context["error"] = "migration_missing"
        return invalid_context
    if migration_id in _gsp_used_migration_ids:
        invalid_context["ok"] = false
        invalid_context["error"] = "migration_reused"
        return invalid_context
    _prune_gsp_migration_capabilities()
    var capability_index := -1
    for index in _gsp_migration_capabilities.size():
        if String(_gsp_migration_capabilities[index].get("id", "")) == migration_id:
            capability_index = index
            break
    if capability_index < 0:
        invalid_context["ok"] = false
        invalid_context["error"] = "migration_expired" if migration_id in _gsp_expired_migration_ids else "migration_wrong"
        return invalid_context
    var capability: Dictionary = _gsp_migration_capabilities[capability_index]
    if String(capability.get("name", "")) != name or String(capability.get("registry_hash", "")) != _gsp_tuning_registry_hash:
        _gsp_migration_capabilities.remove_at(capability_index)
        invalid_context["ok"] = false
        invalid_context["error"] = "migration_stale"
        return invalid_context
    var loaded: Dictionary = gsp_retrieve_preset(name)
    if not bool(loaded.get("ok", false)) or String(loaded.get("content_hash", "")) != String(capability.get("content_hash", "")):
        _gsp_migration_capabilities.remove_at(capability_index)
        invalid_context["ok"] = false
        invalid_context["error"] = "migration_stale"
        return invalid_context
    var classification := GspPresetStore.classify_migration(loaded.preset.get("values", {}), _gsp_tuning_registry)
    if not bool(classification.get("ok", false)) or classification.get("values", {}) != capability.get("values", {}) or \
            classification.get("corrections", {}) != capability.get("corrections", {}) or \
            not _gsp_preset_values_match_registry(capability.get("values", {}), true):
        _gsp_migration_capabilities.remove_at(capability_index)
        _gsp_used_migration_ids.append(migration_id)
        _trim_gsp_migration_id_history(_gsp_used_migration_ids)
        invalid_context["ok"] = false
        invalid_context["error"] = "migration_stale"
        return invalid_context
    _gsp_migration_capabilities.remove_at(capability_index)
    _gsp_used_migration_ids.append(migration_id)
    _trim_gsp_migration_id_history(_gsp_used_migration_ids)
    var changes: Array = []
    var provenance: Dictionary = {}
    for descriptor_value in _gsp_tuning_registry:
        var descriptor: Dictionary = descriptor_value
        var key := String(descriptor.get("key", ""))
        var effective_value := float(capability.values[key])
        var correction: Dictionary = capability.corrections[key]
        changes.append({"parameter": key, "value": effective_value})
        provenance[key] = {
            "source": "preset",
            "request_seq": request_seq,
            "quick_adjust_slot": -1,
            "request_id": 0,
            "preset_original": true,
            "requested_value": float(correction.requested_value),
            "staged_value": effective_value,
            "corrected_value": effective_value,
            "clamp_reason": correction.get("clamp_reason", []).duplicate(true),
        }
    var result := gsp_tuning_batch_request(peer_id, connection_id, request_seq, changes, "preset", -1, true, provenance)
    result["source"] = "preset"
    return result


func _new_gsp_migration_id() -> String:
    var crypto := Crypto.new()
    var migration_id := crypto.generate_random_bytes(32).hex_encode()
    while migration_id in _gsp_used_migration_ids:
        migration_id = crypto.generate_random_bytes(32).hex_encode()
    return migration_id


func _prune_gsp_migration_capabilities() -> void:
    var now_ms := Time.get_ticks_msec()
    for capability in _gsp_migration_capabilities.duplicate():
        if now_ms >= int(capability.get("expires_at_ms", 0)):
            _gsp_migration_capabilities.erase(capability)
            _gsp_expired_migration_ids.append(String(capability.get("id", "")))
    _trim_gsp_migration_id_history(_gsp_expired_migration_ids)


func _trim_gsp_migration_id_history(history: Array[String]) -> void:
    while history.size() > GSP_MIGRATION_CAPABILITY_LIMIT:
        history.pop_front()


func _gsp_preset_values_match_registry(values: Variant, require_bounds: bool = false) -> bool:
    if typeof(values) != TYPE_DICTIONARY or values.size() != _gsp_tuning_registry.size():
        return false
    var registry_keys := {}
    for descriptor_value in _gsp_tuning_registry:
        var descriptor: Dictionary = descriptor_value
        var key := String(descriptor.get("key", ""))
        if key.is_empty() or registry_keys.has(key) or not values.has(key):
            return false
        registry_keys[key] = true
    for key in values.keys():
        if typeof(key) != TYPE_STRING or not registry_keys.has(String(key)):
            return false
        if require_bounds:
            var value := float(values[key])
            var descriptor: Dictionary = {}
            for descriptor_value in _gsp_tuning_registry:
                if String(descriptor_value.get("key", "")) == String(key):
                    descriptor = descriptor_value
                    break
            if descriptor.is_empty() or not is_finite(value) or value < float(descriptor.get("min", INF)) or value > float(descriptor.get("max", -INF)):
                return false
    return true


func _changes_to_values(changes: Array) -> Dictionary:
    var values: Dictionary = {}
    for change_value in changes:
        if typeof(change_value) == TYPE_DICTIONARY:
            var change: Dictionary = change_value
            values[String(change.get("parameter", ""))] = change.get("value", null)
    return values


func gsp_preset_request(peer_id: int, connection_id: int, request_seq: int, operation: String, data: Dictionary) -> Dictionary:
    match operation:
        "list_presets":
            return gsp_list_presets()
        "save_preset":
            var saved: Dictionary = gsp_save_preset(String(data.get("name", "")), String(data.get("note", "")))
            if bool(saved.get("ok", false)):
                saved["presets"] = gsp_list_presets().get("presets", [])
            return saved
        "retrieve_preset":
            return gsp_retrieve_preset(String(data.get("name", "")))
        "load_preset":
            return gsp_load_preset(peer_id, connection_id, request_seq, String(data.get("name", "")))
        "preview_preset_migration":
            return gsp_preview_preset_migration(String(data.get("name", "")))
        "apply_preset_migration":
            return gsp_apply_preset_migration(peer_id, connection_id, request_seq, String(data.get("name", "")),
                    String(data.get("migration_id", "")), bool(data.get("confirmed", false)))
        "compare_presets":
            return gsp_compare_presets(String(data.get("left", "")), String(data.get("right", "")))
    return {"ok": false, "error": "unsupported_preset_operation"}


func gsp_validate_all() -> Dictionary:
    var active: Dictionary = native.call("flight_tuning_configuration") if native != null and native.has_method("flight_tuning_configuration") else {}
    var mismatches: Array[Dictionary] = []
    for descriptor_value in _gsp_tuning_registry:
        var descriptor: Dictionary = descriptor_value
        var key := String(descriptor.get("key", ""))
        if not active.has(key):
            mismatches.append({"key": key, "error": "active_memory_missing"})
            continue
        var value := float(active[key])
        if not is_finite(value) or value < float(descriptor.get("min", -INF)) or value > float(descriptor.get("max", INF)):
            mismatches.append({"key": key, "error": "active_memory_out_of_range", "value": value})
    return {"ok": mismatches.is_empty(), "mismatches": mismatches, "registry_hash": _gsp_tuning_registry_hash}


func _remember_gsp_tuning_result(result: Dictionary) -> void:
    var recent := result.duplicate(true)
    recent.erase("peer_id")
    _gsp_tuning_recent_results.append(recent)
    if _gsp_tuning_recent_results.size() > 16:
        _gsp_tuning_recent_results.pop_front()


func _gsp_external_authority_active() -> bool:
    return px4_sitl_bridge != null and px4_sitl_bridge.is_authority_active()


func _sync_native_external_authority() -> void:
    var external_authority_active := _gsp_external_authority_active()
    if native != null and native.has_method("set_external_authority_active") and _native_external_authority_state != external_authority_active:
        native.call("set_external_authority_active", external_authority_active)
        _native_external_authority_state = external_authority_active


func _gsp_public_physics_tick() -> int:
    return airsim_session.frame_index if airsim_session != null else 0


func gsp_identity_snapshot() -> Dictionary:
    var telemetry: Dictionary = native.call("telemetry_snapshot") if native != null and native.has_method("telemetry_snapshot") else {}
    var registry_parameters: Array = _gsp_tuning_registry.duplicate(true)
    var active_tuning: Dictionary = native.call("flight_tuning_configuration") if native != null and native.has_method("flight_tuning_configuration") else {}
    for descriptor_value in registry_parameters:
        var descriptor: Dictionary = descriptor_value
        if active_tuning.has(String(descriptor.get("key", ""))):
            descriptor["active_value"] = active_tuning[String(descriptor.get("key", ""))]
    var preset_listing: Dictionary = gsp_list_presets()
    return {
        "sim_version": String(ProjectSettings.get_setting("application/config/version", "unavailable")),
        "proto_v": 2,
        "physics_hz": Engine.physics_ticks_per_second,
        "pid": OS.get_process_id(),
        "instance_name": _airsim_vehicle_name,
        "vehicle_instance": _airsim_vehicle_name,
        "authority": String(telemetry.get("control_authority", "unavailable")),
        "registry": {
            "vehicle_instances": _airsim_vehicle_names.duplicate(),
            "parameters": registry_parameters,
            "tuning": active_tuning,
            "tuning_recent_results": _gsp_tuning_recent_results.duplicate(true),
            "quick_adjust": _quick_adjust_profile.duplicate(true),
            "presets": preset_listing.get("presets", []),
        },
        "registry_hash": _gsp_tuning_registry_hash,
        "tick": airsim_session.frame_index if airsim_session != null else 0,
    }


func gsp_telemetry_snapshot() -> Dictionary:
    if native == null or not native.has_method("telemetry_snapshot"):
        return {}
    var snapshot: Dictionary = native.call("telemetry_snapshot")
    var publish_count := int(snapshot.get("publish_count", -1))
    if publish_count == _gsp_telemetry_publish_count and not _gsp_telemetry_cache.is_empty():
        return _gsp_telemetry_cache.duplicate(true)
    var position: Vector3 = drone_body.global_position if drone_body != null else _spawn_position()
    var orientation: Quaternion = drone_body.global_transform.basis.get_rotation_quaternion() if drone_body != null else Quaternion.IDENTITY
    var velocity: Vector3 = drone_body.linear_velocity if drone_body != null else Vector3.ZERO
    var angular_velocity: Vector3 = _jolt_angular_velocity_body_y_up(drone_body) if drone_body != null else Vector3.ZERO
    var position_ned: Vector3 = AirSimCoordinateContract.godot_world_to_ned(position, _spawn_position())
    var velocity_ned: Vector3 = AirSimCoordinateContract.godot_direction_to_ned(velocity)
    var attitude_ned: Quaternion = AirSimCoordinateContract.godot_orientation_to_ned(orientation)
    var rates_frd: Vector3 = AirSimCoordinateContract.godot_body_to_frd(angular_velocity)
    var tick: int = airsim_session.frame_index if airsim_session != null else 0
    var position_payload := _airsim_vector3(position_ned)
    var velocity_payload := _airsim_vector3(velocity_ned)
    var rates_payload := _airsim_vector3(rates_frd)
    snapshot["pos_ned"] = position_payload
    snapshot["vel_ned"] = velocity_payload
    snapshot["att_euler_deg"] = AirSimCoordinateContract.ned_orientation_to_zyx_euler_degrees(attitude_ned)
    snapshot["gyro_body"] = rates_payload
    var rpm: Array[float] = []
    for motor_value in snapshot.get("motors", []):
        var motor: Dictionary = motor_value
        rpm.append(float(motor.get("speed_rad_s", 0.0)) * 60.0 / TAU)
    snapshot["rpm"] = rpm
    snapshot["vehicle_instance"] = _airsim_vehicle_name
    snapshot["authority"] = String(snapshot.get("control_authority", "unavailable"))
    snapshot["registry_hash"] = _gsp_tuning_registry_hash
    snapshot["tuning"] = native.call("flight_tuning_configuration") if native != null and native.has_method("flight_tuning_configuration") else {}
    snapshot["tick"] = tick
    _gsp_telemetry_publish_count = publish_count
    _gsp_telemetry_cache = snapshot.duplicate(true)
    return _gsp_telemetry_cache.duplicate(true)

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
    _refresh_motor_hud()
    if body_drag_debug_panel != null and body_drag_debug_panel.has_method("update_from_snapshot"):
        body_drag_debug_panel.call("update_from_snapshot", primary_snapshot)
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
    var visible_error_message := _localize_fallback_message(last_error_message)
    if status_diagram != null:
        status_diagram.call("set_layout_mode", "full" if screen == "lab_mode" or status_diagram_fullscreen else "compact")
    if main_menu_layer != null:
        main_menu_layer.visible = screen in ["main_menu", "flight_setup", "settings", "controller_settings", "rates", "graphics"]
    if body_drag_debug_panel != null and body_drag_debug_panel.has_method("set_screen_visible"):
        body_drag_debug_panel.call("set_screen_visible", screen == "lab_mode")
    if main_menu_entries_container != null:
        main_menu_entries_container.visible = screen == "main_menu"
    if flight_setup_panel != null:
        flight_setup_panel.visible = screen == "flight_setup"
    if settings_panel != null:
        settings_panel.visible = screen == "settings"
    if settings_status_label != null:
        settings_status_label.text = visible_error_message if not last_error_message.is_empty() else _t("ui.settings.ready")
    if controller_settings_panel != null:
        controller_settings_panel.visible = screen == "controller_settings"
    if rates_panel != null:
        rates_panel.visible = screen == "rates"
    if graphics_panel != null:
        graphics_panel.visible = screen == "graphics"
    if flight_hud_layer != null:
        flight_hud_layer.visible = screen not in ["main_menu", "flight_setup", "settings", "controller_settings", "rates", "graphics"]
        var cockpit_visible := screen in ["preflight", "flight", "finish", "error"]
        for region_name in ["LeftRail", "FlightViewRegion", "RightRail"]:
            var cockpit_region := flight_hud_layer.get_node_or_null(region_name) as Control
            if cockpit_region != null:
                cockpit_region.visible = cockpit_visible
        var status_margin := flight_hud_layer.get_node_or_null("StatusMargin") as Control
        if status_margin != null:
            status_margin.visible = screen != "controller_confirmation" and not (paused and screen == "flight")
    if pause_panel != null:
        pause_panel.visible = paused and screen == "flight" and not status_diagram_fullscreen
    if camera_panel != null:
        camera_panel.visible = screen == "camera"
    if osd_panel != null:
        osd_panel.visible = screen == "osd"
    if controller_safety_panel != null:
        controller_safety_panel.visible = controller_safety_latched and screen not in ["controller_confirmation", "fallback_prompt"] and not (paused and screen == "flight")
    if controller_safety_label != null:
        controller_safety_label.text = visible_error_message
    if controller_confirmation_panel != null:
        controller_confirmation_panel.visible = screen == "controller_confirmation"
    if finish_panel != null:
        finish_panel.visible = screen == "finish"
    if license_panel != null:
        var license_snapshot := get_license_snapshot()
        var license_status := String(license_snapshot.get("status", "invalid_token"))
        license_panel.visible = screen == "license_blocked"
        license_status_label.text = _format("ui.license.blocked", [_localized_license_status(license_status)])
        var actions := license_actions()
        var key_status := license_status in ["not_activated", "offline_grace_expired", "invalid_token"] and not license_snapshot.has("fatal")
        license_key_input.visible = screen == "license_blocked" and key_status
        if not license_key_input.visible:
            license_key_input.clear()
        license_activate_button.visible = actions.has("activate_license")
        license_retry_button.visible = actions.has("retry_license")
        license_diagnostics_button.visible = screen == "license_blocked" and actions.has("diagnostics")
        license_exit_button.visible = actions.has("exit")
    key_hints_label.text = _t("ui.hints.gamepad" if _has_active_gamepad_profile() else "ui.hints")
    if player_view_label != null:
        player_view_label.visible = loaded_map != null and screen in ["preflight", "flight", "finish"]
        player_view_label.text = _t("ui.view.third_person" if third_person_view else "ui.view.fpv")
    _refresh_quick_adjust_hud()
    _refresh_rates_panel()
    _refresh_graphics_panel()
    arm_takeoff_button.disabled = screen in ["main_menu", "license_blocked"] or (controller_safety_latched and screen != "fallback_prompt")
    if lab_back_button != null:
        lab_back_button.visible = screen == "lab_mode"
        lab_back_button.disabled = false
    if acro_mode_button != null:
        acro_mode_button.disabled = screen != "flight" or paused or controller_safety_latched
        acro_mode_button.text = _format("ui.hud.acro", [_t("ui.hud.on") if flight_mode == "ACRO" else _t("ui.hud.off")])
    if time_trial_status_label != null:
        time_trial_status_label.visible = time_trial != null and screen in ["preflight", "flight", "finish"]
        if time_trial != null:
            var trial_state := _t("ui.hud.time_trial_finished") if time_trial.finished else _format("ui.hud.time_trial_next", [time_trial.next_checkpoint_index + 1, time_trial.checkpoint_positions.size()])
            time_trial_status_label.text = _format("ui.hud.time_trial", [trial_state, time_trial.elapsed_seconds])
    _refresh_motor_hud()
    _refresh_gamepad_hud()
    _refresh_osd()
    if screen == "preflight":
        var armed := _flight_control_armed()
        arm_status_label.text = _format("ui.hud.preflight", [_px4_status_text(), _profile_input_status(), _localized_arm_state(armed)])
        arm_takeoff_button.text = _t("ui.hud.arm_takeoff")
    elif screen == "flight":
        var armed := _flight_control_armed()
        arm_status_label.text = _format("ui.hud.flight", [_px4_status_text(), _profile_input_status(), _localized_arm_state(armed), _t("ui.hud.paused") if paused else _t("ui.hud.takeoff")])
        arm_takeoff_button.text = _t("ui.hud.arm_takeoff")
    elif screen == "fallback_prompt":
        arm_status_label.text = visible_error_message
        arm_takeoff_button.text = _t("ui.controller.use_keyboard")
    elif screen == "controller_confirmation":
        arm_status_label.text = _t("ui.hud.confirm_controller")
        arm_takeoff_button.text = _t("ui.action.back_to_menu")
    elif screen == "error":
        arm_status_label.text = visible_error_message
        arm_takeoff_button.text = _t("ui.action.back_to_menu")
    elif screen == "exit":
        arm_status_label.text = _t("ui.hud.exit_requested")
        arm_takeoff_button.text = _t("ui.action.exit")


    elif screen == "finish":
        arm_status_label.text = _t("ui.hud.time_trial_complete")
        arm_takeoff_button.text = _t("ui.action.retry")
    elif screen == "controller_disconnected":
        arm_status_label.text = visible_error_message
        arm_takeoff_button.text = _t("ui.hud.wait_controller")
    elif screen == "license_blocked":
        arm_status_label.text = visible_error_message
        arm_takeoff_button.text = _t("ui.license.blocked_button")
    else:
        arm_status_label.text = _t("ui.hud.quick_fly_hint")
        arm_takeoff_button.text = _t("ui.hud.arm_takeoff")


func _refresh_motor_hud() -> void:
    if motor_hud_panel == null:
        return
    motor_hud_panel.visible = screen in ["flight", "error"]
    var motor_hud := {"cells": []}
    if status_diagram != null and status_diagram.has_method("get_motor_hud_state"):
        motor_hud = status_diagram.call("get_motor_hud_state", paused, last_error_message if screen == "error" else "", motor_hud_spin_directions)
    if motor_hud_rotor_panel != null and motor_hud_rotor_panel.has_method("set_motor_hud"):
        motor_hud_rotor_panel.call("set_motor_hud", motor_hud)


func _refresh_quick_adjust_hud() -> void:
    if quick_adjust_status_label == null:
        return
    quick_adjust_status_label.visible = screen == "flight"
    if _quick_adjust_active_slot >= 0 and _quick_adjust_active_slot < _quick_adjust_profile.slots.size() and _quick_adjust_profile.slots[_quick_adjust_active_slot] != null:
        var quick_slot: Dictionary = _quick_adjust_profile.slots[_quick_adjust_active_slot]
        quick_adjust_status_label.text = _format("ui.hud.quick_adjust_active", [_quick_adjust_active_slot + 1, String(quick_slot.parameter), _quick_adjust_last_value])
    else:
        quick_adjust_status_label.text = _t("ui.hud.quick_adjust_none")

func _refresh_gamepad_hud() -> void:
    if gamepad_hud_panel == null or gamepad_hud_display == null:
        return
    gamepad_hud_panel.visible = screen in ["flight", "error"]
    var connected := _has_active_gamepad_profile() and session_gamepad_device_id >= 0
    gamepad_hud_display.call("set_controller_state", {
        "connected": connected,
        "title": _t("ui.gamepad_hud.title"),
        "left_label": "%s / %s" % [_localized_controller_role("yaw"), _t("ui.gamepad_hud.climb")],
        "right_label": "%s / %s" % [_localized_controller_role("roll"), _localized_controller_role("pitch")],
        "actions": _t("ui.gamepad_hud.actions"),
        "connection": _t("ui.gamepad_hud.connected") if connected else _t("ui.gamepad_hud.unavailable"),
        "mode": _localized_flight_mode(flight_mode),
        "yaw": _profile_axis("yaw") if connected else 0.0,
        "throttle": _profile_axis("throttle") if connected else 0.0,
        "roll": _profile_axis("roll") if connected else 0.0,
        "pitch": _profile_axis("pitch") if connected else 0.0,
    })

func _handle_primary_action() -> void:
    if screen == "fallback_prompt":
        accept_fallback()
    elif screen in ["preflight", "flight"]:
        arm_and_takeoff()
    elif screen in ["controller_confirmation", "error"]:
        if controller_confirmation_panel != null:
            controller_confirmation_panel.hide()
        last_error_message = ""
        if screen == "controller_confirmation":
            _cancel_controller_route()
        else:
            show_main_menu()
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
    gamepad_pause_pressed = false
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
    var mapping_lines := [_t("ui.controller.mapping_header")]
    var live_axis_lines := [_t("ui.controller.live_axes")]
    for role in ["roll", "pitch", "yaw", "throttle"]:
        var axis := int(controller_confirmation_profile.axis_for_role[role])
        var raw := Input.get_joy_axis(controller_confirmation_device_id, axis)
        var normalized := _normalize_gamepad_axis(raw, controller_confirmation_profile.deadzone)
        if controller_confirmation_profile.reversed_for_role[role]:
            normalized = -normalized
        if is_zero_approx(normalized):
            normalized = 0.0
        mapping_lines.append(_format("ui.controller.mapping_line", [_localized_controller_role(role), axis, _localized_reversed_suffix() if controller_confirmation_profile.reversed_for_role[role] else ""]))
        live_axis_lines.append(_format("ui.controller.live_axis_line", [_localized_controller_role(role), raw, normalized]))
    confirmation_mapping_label.text = "\n".join(mapping_lines)
    confirmation_axes_label.text = "\n".join(live_axis_lines)

func _refresh_controller_settings() -> void:
    if controller_settings_panel == null or not controller_settings_panel.visible:
        return
    controller_monitor_refresh_count += 1
    var device_id := _first_connected_device()
    if device_id < 0:
        controller_settings_device_label.text = _t("ui.controller.device_none")
    else:
        var support := _t("ui.controller.support_sdl") if InputProfiles.GamepadProfile.is_supported_device(device_id, gamepad_device_state) else _t("ui.controller.support_unknown")
        controller_settings_device_label.text = _format("ui.controller.device", [device_id, gamepad_device_state.joy_name(device_id), support])
    if not _has_active_gamepad_profile():
        controller_settings_mapping_label.text = _t("ui.controller.mapping_unavailable")
        controller_settings_monitor_label.text = "\n".join([
            _t("ui.controller.monitor_header"),
            _format("ui.controller.channel_unavailable", [_localized_controller_role("roll"), " ".repeat(10 - "roll:".length())]),
            _format("ui.controller.channel_unavailable", [_localized_controller_role("pitch"), " ".repeat(10 - "pitch:".length())]),
            _format("ui.controller.channel_unavailable", [_localized_controller_role("yaw"), " ".repeat(10 - "yaw:".length())]),
            _format("ui.controller.channel_unavailable", [_localized_controller_role("throttle"), " ".repeat(10 - "throttle:".length())]),
            _format("ui.controller.deadzone", [InputProfiles.GamepadProfile.RAW_AXIS_DEADZONE]),
            _t("ui.controller.arm_unavailable"),
            _t("ui.controller.mode_unavailable"),
        ])
        return
    var profile := session_gamepad_profile
    var mapping_lines := [_t("ui.controller.mapping_header")]
    for role in ["roll", "pitch", "yaw", "throttle"]:
        var axis := int(profile.axis_for_role[role])
        mapping_lines.append(_format("ui.controller.mapping_line", [_localized_controller_role(role), axis, _localized_reversed_suffix() if profile.reversed_for_role[role] else ""]))
    controller_settings_mapping_label.text = "\n".join(mapping_lines)
    var monitor_lines := [_t("ui.controller.monitor_header")]
    for role in ["roll", "pitch", "yaw", "throttle"]:
        var raw := Input.get_joy_axis(session_gamepad_device_id, int(profile.axis_for_role[role]))
        var normalized := _profile_axis(role)
        var role_label := "%s:" % _localized_controller_role(role)
        var line: String = _format("ui.controller.monitor_line", [role_label, " ".repeat(10 - role_label.length()), _controller_monitor_bar(normalized), raw, normalized])
        if role == "throttle":
            line += _format("ui.controller.throttle_state", [_t("ui.hud.low") if _profile_throttle_is_low() else _t("ui.hud.high")])
        monitor_lines.append(line)
    monitor_lines.append(_format("ui.controller.deadzone", [profile.deadzone]))
    monitor_lines.append(_format("ui.controller.arm_state", [_localized_button_state(profile.arm_pressed), _localized_arm_state(_flight_control_armed())]))
    monitor_lines.append(_format("ui.controller.mode_state", [_localized_button_state(profile.mode_pressed), _localized_flight_mode(flight_mode)]))
    controller_settings_monitor_label.text = "\n".join(monitor_lines)

func _controller_monitor_bar(value: float) -> String:
    var marker := clampi(roundi((clampf(value, -1.0, 1.0) + 1.0) * 8.0), 0, 16)
    return "[%s|%s]" % ["-".repeat(marker), "-".repeat(16 - marker)]

func _normalize_gamepad_axis(raw: float, deadzone: float) -> float:
    return InputProfiles.GamepadProfile.normalize_axis(raw, deadzone)

func _handle_gamepad_button(event: InputEventJoypadButton) -> bool:
    if not _has_active_gamepad_profile() or event.device != session_gamepad_device_id:
        return false
    if event.button_index == JOY_BUTTON_START:
        gamepad_pause_pressed = event.pressed
        return false
    if event.button_index == JOY_BUTTON_X and event.pressed and gamepad_pause_pressed and screen == "flight":
        change_spawn()
        return true
    var profile := session_gamepad_profile
    var is_arm := event.button_index == profile.arm_button
    var is_mode := event.button_index == profile.mode_button
    var is_acro := event.button_index == InputProfiles.GamepadProfile.ACRO_BUTTON
    if not is_arm and not is_mode and not is_acro:
        return false
    if is_acro:
        if event.pressed:
            toggle_acro_mode()
        _refresh_flight_hud()
        return true
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
    return 0.0 if is_zero_approx(normalized) else normalized

func _profile_throttle_raw() -> float:
    if not _has_active_gamepad_profile():
        return 0.0
    var axis := int(session_gamepad_profile.axis_for_role["throttle"])
    return Input.get_joy_axis(session_gamepad_device_id, axis)

func _flight_throttle() -> float:
    if not _has_active_gamepad_profile():
        return KEYBOARD_FLIGHT_THROTTLE
    return clampf((_profile_axis("throttle") + 1.0) * 0.5, 0.0, 1.0)

func _configured_hover_throttle() -> float:
    if native != null and native.has_method("hardware_power_diagnostics"):
        var hover_throttle := float(native.call("hardware_power_diagnostics").get("hover_throttle", 0.0))
        if is_finite(hover_throttle) and hover_throttle > 0.0:
            return clampf(hover_throttle, 0.0, 1.0)
    return 0.0

func _profile_throttle_is_low() -> bool:
    return _has_active_gamepad_profile() and session_gamepad_profile.throttle_axis_is_low(_profile_throttle_raw())

func _angle_roll_degrees() -> float:
    return _profile_axis("roll") * ANGLE_MAX_TILT_DEGREES

func _angle_pitch_degrees() -> float:
    return _profile_axis("pitch") * ANGLE_MAX_TILT_DEGREES

func _assisted_hold_horizontal_angles() -> Vector2:
    if not _has_active_gamepad_profile():
        assisted_horizontal_intent_active = false
        return Vector2.ZERO
    var roll := _profile_axis("roll")
    var pitch := _profile_axis("pitch")
    assisted_horizontal_intent_active = InputProfiles.GamepadProfile.assisted_hold_horizontal_intent_active(
        assisted_horizontal_intent_active,
        roll,
        pitch
    )
    if not assisted_horizontal_intent_active:
        return Vector2.ZERO
    return Vector2(roll, pitch) * ANGLE_MAX_TILT_DEGREES

func _angle_yaw_rate_degrees_per_second() -> float:
    return _profile_axis("yaw") * ANGLE_MAX_YAW_RATE_DPS

func _profile_input_status() -> String:
    if not _has_active_gamepad_profile():
        return _t("ui.hud.input_keyboard")
    var throttle := _flight_throttle()
    var is_low := _profile_throttle_is_low()
    return _format("ui.hud.input_profile", [roundi(throttle * 100.0), _t("ui.hud.low") if is_low else _t("ui.hud.high"), _localized_button_state(session_gamepad_profile.arm_pressed), _localized_button_state(session_gamepad_profile.mode_pressed)])

func _update_chase_camera() -> void:
    if chase_camera == null or drone_body == null:
        return
    var player_map_view := _reset_pending_token == 0 and loaded_map != null and screen in ["preflight", "flight", "finish", "controller_confirmation", "fallback_prompt"]
    if player_map_view:
        chase_camera.global_position = drone_body.global_position + drone_body.global_basis * Vector3(0.0, 0.03, 0.0)
        chase_camera.global_basis = drone_body.global_basis * Basis(Vector3.RIGHT, deg_to_rad(float(camera_profile.camera_angle_deg)))
        chase_camera.fov = float(camera_profile.fov_deg)
    else:
        chase_camera.global_position = drone_body.global_position + CHASE_CAMERA_OFFSET
        chase_camera.look_at(drone_body.global_position, Vector3.UP)
    if third_person_camera != null and third_person_view and screen in ["preflight", "flight", "finish", "controller_confirmation", "fallback_prompt"]:
        third_person_camera.global_position = drone_body.global_position + drone_body.global_basis * THIRD_PERSON_CAMERA_OFFSET
        third_person_camera.look_at(drone_body.global_position + drone_body.global_basis * Vector3(0.0, 0.2, 0.0), Vector3.UP)
        third_person_camera.current = true
        chase_camera.current = false
    else:
        chase_camera.current = true
        if third_person_camera != null:
            third_person_camera.current = false
    if secondary_drone_body != null and secondary_chase_camera != null and secondary_drone_body.visible:
        if screen in ["preflight", "flight", "finish"]:
            secondary_chase_camera.global_position = secondary_drone_body.global_position + secondary_drone_body.global_basis * Vector3(0.0, 0.03, 0.0)
            secondary_chase_camera.global_basis = secondary_drone_body.global_basis * Basis(Vector3.RIGHT, deg_to_rad(float(camera_profile.camera_angle_deg)))
            secondary_chase_camera.fov = float(camera_profile.fov_deg)
        else:
            secondary_chase_camera.global_position = secondary_drone_body.global_position + CHASE_CAMERA_OFFSET
            secondary_chase_camera.look_at(secondary_drone_body.global_position, Vector3.UP)


func toggle_player_view() -> void:
    if _reset_pending_token != 0 or loaded_map == null or not screen in ["preflight", "flight", "finish"]:
        return
    third_person_view = not third_person_view
    _update_chase_camera()
    _refresh_flight_hud()


func _apply_camera_profile() -> void:
    _update_chase_camera()
    _refresh_camera_panel()


func _airsim_camera_source(vehicle_name: String = "") -> Camera3D:
    if not _reset_publication_error().is_empty():
        return null
    if _airsim_vehicle_names.size() > 1 and vehicle_name == String(_airsim_vehicle_names[1]):
        return secondary_chase_camera
    return chase_camera


func _airsim_camera_vehicle(vehicle_name: String):
    if not _reset_publication_error().is_empty():
        return null
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
        return _t("ui.hud.local")
    var diagnostics: Dictionary = px4_sitl_bridge.diagnostics()
    var message := String(diagnostics.get("message", ""))
    var localized_message := _localized_px4_message(message)
    return _format("ui.hud.px4", [_localized_px4_state(px4_sitl_bridge.state), " (%s)" % localized_message if not localized_message.is_empty() else ""])


func _localized_px4_state(state: String) -> String:
    match state:
        "disconnected":
            return _t("ui.hud.px4.state.disconnected")
        "starting":
            return _t("ui.hud.px4.state.starting")
        "connected":
            return _t("ui.hud.px4.state.connected")
        "armed":
            return _t("ui.hud.px4.state.armed")
        "stale":
            return _t("ui.hud.px4.state.stale")
        "failed":
            return _t("ui.hud.px4.state.failed")
        _:
            return _format("ui.hud.px4.state.unknown", [state])


func _localized_px4_message(message: String) -> String:
    if message == "PX4 heartbeat received; awaiting actuator output":
        return _t("ui.hud.px4.message.awaiting_actuator")
    if message.contains("; "):
        var localized_parts: Array[String] = []
        for part in message.split("; "):
            localized_parts.append(_localized_px4_message(part))
        return "；".join(localized_parts)
    match message:
        "waiting for PX4 heartbeat":
            return _t("ui.hud.px4.message.waiting")
        "PX4 heartbeat received":
            return _t("ui.hud.px4.message.heartbeat_received")
        "PX4 heartbeat received; awaiting actuator output":
            return _t("ui.hud.px4.message.awaiting_actuator")
        "PX4 heartbeat and actuator output received":
            return _t("ui.hud.px4.message.actuator_received")
        "PX4 TCP simulator channel connected":
            return _t("ui.hud.px4.message.tcp_connected")
        "PX4 simulator TCP channel disconnected":
            return _t("ui.hud.px4.message.tcp_disconnected")
        "PX4 transport stopped":
            return _t("ui.hud.px4.message.transport_stopped")
        "PX4 actuator output is stale":
            return _t("ui.hud.px4.message.actuator_stale")
        "PX4 heartbeat was not received before startup timeout":
            return _t("ui.hud.px4.message.startup_timeout")
        "PX4 disarmed":
            return _t("ui.hud.px4.message.disarmed")
        "PX4 is not connected":
            return _t("ui.hud.px4.message.not_connected")
        "PX4 SITL requires UseTcp=true":
            return _t("ui.hud.px4.message.requires_tcp")
        "PX4 SITL bridge requires VehicleType PX4Multirotor":
            return _t("ui.hud.px4.message.bridge_vehicle_type")
        "PX4 SITL bridge does not support serial/HITL transport":
            return _t("ui.hud.px4.message.bridge_serial")
        "PX4 SITL bridge ports must be in the range 1..65535":
            return _t("ui.hud.px4.message.bridge_ports")
        "PX4 SITL bridge timeouts must be positive and ordered":
            return _t("ui.hud.px4.message.bridge_timeouts")
        "PX4 authority is inactive":
            return _t("ui.hud.px4.message.authority_inactive")
        "PX4 actuator output is pending":
            return _t("ui.hud.px4.message.actuator_pending")
        "PX4 thrust output is pending":
            return _t("ui.hud.px4.message.thrust_pending")
        _:
            if message == "PX4 moveOnPath requires at least one waypoint":
                return _t("ui.hud.px4.message.move_on_path_empty")
            if message.begins_with("PX4 simulator TCP connection failed: "):
                return _format("ui.hud.px4.message.tcp_failed", [message.trim_prefix("PX4 simulator TCP connection failed: ")])
            if message.begins_with("PX4 control UDP bind failed on "):
                var udp_parts := message.trim_prefix("PX4 control UDP bind failed on ").split(":", false, 2)
                if udp_parts.size() == 3:
                    return _format("ui.hud.px4.message.udp_failed", [udp_parts[0], int(udp_parts[1]), udp_parts[2]])
            if message.begins_with("PX4 command ") and message.contains(" rejected with result "):
                var command_parts := message.trim_prefix("PX4 command ").split(" rejected with result ")
                if command_parts.size() == 2:
                    return _format("ui.hud.px4.message.command_rejected", [int(command_parts[0]), int(command_parts[1])])
            if message.begins_with("PX4 arm failed: "):
                return _format("ui.hud.px4.message.arm_failed", [message.trim_prefix("PX4 arm failed: ")])
            if message.begins_with("PX4 SITL does not support AirSim command '"):
                return _format("ui.hud.px4.message.command_unsupported", [message.trim_prefix("PX4 SITL does not support AirSim command '").trim_suffix("' in this slice")])
            if message.begins_with("PX4 heartbeat timeout after "):
                return _format("ui.hud.px4.message.heartbeat_timeout", [message.trim_prefix("PX4 heartbeat timeout after ")])
            if message.begins_with("PX4 heartbeat is stale after "):
                return _format("ui.hud.px4.message.heartbeat_stale", [message.trim_prefix("PX4 heartbeat is stale after ")])
            return _t("ui.error.generic")


func _localized_arm_state(armed: bool) -> String:
    return _t("ui.hud.armed") if armed else _t("ui.hud.disarmed")


func _localized_button_state(pressed: bool) -> String:
    return _t("ui.hud.pressed") if pressed else _t("ui.hud.released")


func _localized_controller_role(role: String) -> String:
    return _t("ui.controller.role.%s" % role)


func _localized_reversed_suffix() -> String:
    return _t("ui.controller.reversed")


func _localized_license_status(status: String) -> String:
    var known_key := "ui.license.status.%s" % status
    if Localization.translate(known_key) != known_key:
        return _t(known_key)
    return _format("ui.license.status", [status])

func _pre_impact_energy(body: Object, target_native = native) -> float:
    for property in body.get_property_list():
        if property.get("name") == &"native_linear_velocity":
            return _kinetic(body.get(&"native_linear_velocity"), body.get(&"native_body_angular_velocity"), target_native)
    return _kinetic(body.linear_velocity, _jolt_angular_velocity_body_y_up(body), target_native)

func _kinetic(linear_velocity: Vector3, angular_velocity: Vector3, target_native = native) -> float:
    var inertia_frd := Vector3.ONE
    if target_native != null and target_native.has_method("hardware_per_motor_diagnostics"):
        var diagnostics: Dictionary = target_native.call("hardware_per_motor_diagnostics")
        var configured_inertia: Variant = diagnostics.get("inertia_frd", inertia_frd)
        if configured_inertia is Vector3 and configured_inertia.x > 0.0 and configured_inertia.y > 0.0 and configured_inertia.z > 0.0:
            inertia_frd = configured_inertia
    var rotational_energy := inertia_frd.x * angular_velocity.x * angular_velocity.x + inertia_frd.z * angular_velocity.y * angular_velocity.y + inertia_frd.y * angular_velocity.z * angular_velocity.z
    return 0.5 * _mass_kg(target_native) * linear_velocity.length_squared() + 0.5 * rotational_energy


func _jolt_angular_velocity_body_y_up(body: Object) -> Vector3:
    var basis: Basis = body.global_transform.basis
    if body is Node3D and not body.is_inside_tree():
        basis = body.transform.basis
    return basis.inverse() * body.angular_velocity


func _mass_kg(target_native = native) -> float:
    if target_native == null or not target_native.has_method("hardware_power_diagnostics"):
        return 1.0
    var diagnostics: Dictionary = target_native.call("hardware_power_diagnostics")
    return maxf(float(diagnostics.get("mass_kg", 1.0)), 0.000001)


func _airsim_name_matches(name: String) -> bool:
    if _airsim_vehicle_names.size() > 1:
        return name in _airsim_vehicle_names
    return name == _airsim_vehicle_name or (_airsim_vehicle_name.is_empty() and name.is_empty())


func _airsim_lifecycle_stopped() -> bool:
    return screen in ["finish", "settings", "controller_settings", "controller_disconnected", "error"] or (screen == "main_menu" and exit_requested)


func _airsim_enable_api_control(enabled: bool, name: String) -> Dictionary:
    if _reset_pending_token != 0 and enabled:
        return {"ok": false, "error": "reset_pending"}
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
    if _reset_pending_token != 0 and armed:
        return {"ok": false, "error": "reset_pending"}
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
    var reset_error := _reset_publication_error()
    if not reset_error.is_empty():
        return {"ok": false, "error": reset_error}
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
    if _reset_pending_token != 0:
        return {"ok": false, "error": "reset_pending"}
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
            var takeoff_velocity := clampf((AIRSIM_TAKEOFF_ALTITUDE_M - _airsim_altitude_above_origin(drone_body)) * 1.5, -3.0, 3.0)
            return _airsim_velocity_controls(Vector3(0.0, takeoff_velocity, 0.0), 0.0)
        "land":
            var landing_velocity := clampf(-_airsim_altitude_above_origin(drone_body) * 1.5, -3.0, 3.0)
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
            return _airsim_velocity_controls(horizontal, (-float(args[2]) - _airsim_altitude_above_origin(drone_body)) * 4.0, args[5])
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
            rotate_to_controls["yaw_rate"] = clampf(-rad_to_deg(delta_yaw) * 3.0, -ANGLE_MAX_YAW_RATE_DPS, ANGLE_MAX_YAW_RATE_DPS)
            return rotate_to_controls
        "rotateByYawRate":
            var rotate_rate_controls := _airsim_velocity_controls(Vector3.ZERO, 0.0)
            rotate_rate_controls["yaw_rate"] = clampf(float(args[0]), -ANGLE_MAX_YAW_RATE_DPS, ANGLE_MAX_YAW_RATE_DPS)
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
        "roll": clampf(horizontal_velocity_error.z * 4.0, -ANGLE_MAX_TILT_DEGREES, ANGLE_MAX_TILT_DEGREES),
        "pitch": clampf(-horizontal_velocity_error.x * 4.0, -ANGLE_MAX_TILT_DEGREES, ANGLE_MAX_TILT_DEGREES),
        "yaw_rate": _airsim_yaw_rate_from_mode(yaw_mode, measured_body),
    }


func _airsim_yaw_rate_from_mode(yaw_mode: Variant, body = null) -> float:
    if typeof(yaw_mode) != TYPE_DICTIONARY:
        return 0.0
    var requested := float(yaw_mode.get("yaw_or_rate", 0.0))
    if bool(yaw_mode.get("is_rate", true)):
        return clampf(requested, -ANGLE_MAX_YAW_RATE_DPS, ANGLE_MAX_YAW_RATE_DPS)
    var yaw_body = body if body != null else drone_body
    if yaw_body == null:
        return 0.0
    var delta_yaw := wrapf(AirSimCoordinateContract.ned_yaw_degrees_to_godot_radians(requested) - yaw_body.rotation.y, -PI, PI)
    return clampf(-rad_to_deg(delta_yaw) * 3.0, -ANGLE_MAX_YAW_RATE_DPS, ANGLE_MAX_YAW_RATE_DPS)


func _airsim_rate_stick(rate_degrees_per_second: float, target_native: Object = null) -> float:
    var rate_native: Object = target_native if target_native != null else native
    if rate_native != null and rate_native.has_method("betaflight_stick_for_rate"):
        return float(rate_native.call("betaflight_stick_for_rate", rate_degrees_per_second, _acro_rate("rc_rate"), _acro_rate("super_rate"), _acro_rate("expo")))
    return clampf(rate_degrees_per_second / 720.0, -1.0, 1.0)


func _airsim_neutral_controls() -> Dictionary:
    return {"mode": "ANGLE", "throttle": 0.50, "roll": 0.0, "pitch": 0.0, "yaw_rate": 0.0}


func _airsim_state(name: String) -> Dictionary:
    var reset_error := _reset_publication_error()
    if not reset_error.is_empty():
        return {"ok": false, "error": reset_error}
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

func _sync_native_from_drone() -> bool:
    var q: Quaternion = drone_body.global_transform.basis.get_rotation_quaternion()
    var angular_velocity_body := _jolt_angular_velocity_body_y_up(drone_body)
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
        angular_velocity_body.x,
        angular_velocity_body.y,
        angular_velocity_body.z
    )
    return not _handle_native_step_failure(native)
