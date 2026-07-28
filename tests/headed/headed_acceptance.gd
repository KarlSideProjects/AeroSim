extends SceneTree

const SmokeScene = preload("res://levels/smoke/smoke.tscn")
const AirSimCoordinateContract = preload("res://common/rpc/airsim_coordinate_contract.gd")
const GamepadDeviceState = preload("res://common/flight/gamepad_device_state.gd")
const CameraProfile = preload("res://common/flight/camera_profile.gd")
const OsdProfile = preload("res://common/flight/osd_profile.gd")

class MutableGamepadDeviceState:
	extends GamepadDeviceState.DeviceState

	var snapshot: Array[int] = []
	var known_device_ids: Dictionary = {}

	func replace_snapshot(device_ids: Array[int], known_ids: Array[int]) -> void:
		snapshot = device_ids.duplicate()
		known_device_ids.clear()
		for device_id in known_ids:
			known_device_ids[device_id] = true

	func connected_joypads() -> Array[int]:
		return snapshot.duplicate()

	func is_joy_known(device_id: int) -> bool:
		return bool(known_device_ids.get(device_id, false))

	func joy_name(device_id: int) -> String:
		return "Xbox Test Controller %d" % device_id


class HeadedLicenseProvider:
	extends Node

	func get_snapshot() -> Dictionary:
		return {"ok": true, "status": "online_valid", "last_online_result": "headed_acceptance"}


var _failures: Array[String] = []
var _out_dir := "build/headed"
var _channel_monitor_evidence: Dictionary = {}
var _motor_hud_evidence: Dictionary = {}
var _known_xbox_physical_evidence: Dictionary = {}
var _assisted_hover_evidence: Dictionary = {}
var _layout_audit_evidence: Dictionary = {}
var _screenshot_comparison: Dictionary = {}
var _ui_animation_count := 0
var _locale_switch_evidence: Array[Dictionary] = []

func _initialize() -> void:
	_run()

func _run() -> void:
	_parse_args()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://%s" % _out_dir))
	var runtime := SmokeScene.instantiate()
	var device_state := MutableGamepadDeviceState.new()
	runtime.gamepad_device_state = device_state
	root.add_child(runtime)
	await _settle(30)
	_ui_animation_count = root.find_children("*", "AnimationPlayer", true, false).size()
	_expect(_ui_animation_count == 0, "production UI has no animation players requiring G4B.9 offset-transform review")
	_install_deterministic_valid_license(runtime)

	await _snapshot("00_cold_start")
	_audit_overlay_geometry(runtime, "main_menu")
	_expect(runtime.native != null, "native runtime is registered")
	_expect(root.get_camera_3d() != null, "cold start has an active Camera3D")
	_expect(runtime.screen == "main_menu", "cold start opens the main menu")
	var entries: Array[String] = []
	var entry_rows: Node = runtime.get_node_or_null("MainMenu/Entries")
	if entry_rows != null:
		for entry in entry_rows.get_children():
			entries.append(entry.text)
	_expect(entries == ["Quick Fly", "Lab Mode", "Controller", "Drone", "Map", "Settings", "Quit"], "main menu exposes the exact seven CAP-006 entries in order")
	var drone_entry: Button = runtime.get_node_or_null("MainMenu/Entries/Drone")
	var map_entry: Button = runtime.get_node_or_null("MainMenu/Entries/Map")
	_expect(drone_entry != null and map_entry != null, "main menu exposes Drone and Map setup paths")
	if drone_entry != null:
		_click(drone_entry)
	await _settle(2)
	var flight_setup: Control = runtime.flight_setup_panel
	_expect(runtime.screen == "flight_setup" and flight_setup != null and flight_setup.is_visible_in_tree() and runtime.flight_setup_focus == "drone", "Drone opens shared Flight Setup with Drone focused")
	runtime.show_main_menu()
	await _settle(2)
	if map_entry != null:
		_click(map_entry)
	await _settle(2)
	_expect(runtime.screen == "flight_setup" and runtime.flight_setup_panel == flight_setup and runtime.flight_setup_focus == "map", "Map reuses shared Flight Setup with Map focused")
	runtime.show_main_menu()
	await _settle(2)
	var native_before_lab: Object = runtime.native
	var lab_entry: Button = runtime.get_node_or_null("MainMenu/Entries/LabMode")
	_expect(lab_entry != null, "main menu exposes Lab Mode")
	if lab_entry != null:
		_click(lab_entry)
	await _settle(2)
	_audit_overlay_geometry(runtime, "lab_mode")
	var dashboard: CanvasLayer = runtime.status_diagram
	_expect(runtime.screen == "lab_mode" and runtime.native == native_before_lab, "Lab Mode keeps the same native runtime")
	_expect(dashboard != null and dashboard.call("get_layout_mode") == "full" and bool(dashboard.call("get_render_evidence").get("visible", false)), "Lab Mode shows the full Operations Dashboard")
	var lab_back: Button = runtime.get_node_or_null("FlightHud/StatusMargin/StatusPanel/StatusRows/LabBack")
	_expect(lab_back != null and lab_back.is_visible_in_tree(), "Lab Mode exposes a visible Back control")
	if lab_back != null:
		_click(lab_back)
	await _settle(2)
	_expect(runtime.screen == "main_menu" and dashboard != null and dashboard.call("get_layout_mode") == "compact", "Lab Back returns to compact main menu")
	if lab_entry != null:
		_click(lab_entry)
	await _settle(2)
	_expect(runtime.screen == "lab_mode" and dashboard != null and dashboard.call("get_layout_mode") == "full", "Lab Mode reopens for Escape coverage")
	_tap(KEY_ESCAPE)
	await _settle(2)
	_expect(runtime.screen == "main_menu" and dashboard != null and dashboard.call("get_layout_mode") == "compact", "Escape also returns Lab Mode to compact main menu")
	runtime.quit_on_exit = false
	runtime.exit_requested = false
	var quit_entry: Button = runtime.get_node_or_null("MainMenu/Entries/Quit")
	_expect(quit_entry != null, "main menu exposes Quit")
	if quit_entry != null:
		_click(quit_entry)
	await _settle(2)
	_expect(runtime.exit_requested and runtime.screen == "main_menu", "Quit uses cleanup-safe request_exit")
	runtime.exit_requested = false
	await _navigate_graphics_with_ui_actions(runtime, -1)
	await _navigate_graphics_with_ui_actions(runtime, 7)
	_expect(dashboard != null, "cold start attaches the Operations Dashboard")
	if dashboard != null:
		var dashboard_panel := dashboard.get_node_or_null("DashboardMargin/DashboardPanel") as PanelContainer
		_expect(dashboard_panel != null and dashboard_panel.is_visible_in_tree(), "Operations Dashboard renders its panel")
		var render_evidence: Dictionary = dashboard.call("get_render_evidence")
		_expect(bool(render_evidence.get("visible", false)) and render_evidence.get("layout_mode", "") == "compact", "compact dashboard render evidence is observable")
		_expect(bool(render_evidence.get("selector_visible", false)), "Operations Dashboard renders named vehicle selection")
		runtime.set_dashboard_layout_mode("full")
		_expect(dashboard.call("get_layout_mode") == "full", "Operations Dashboard supports full Lab Mode layout")
		runtime.set_dashboard_layout_mode("compact")
	var no_controller_quick_fly: Button = runtime.get_node_or_null("MainMenu/Entries/QuickFly")
	if no_controller_quick_fly != null:
		_click(no_controller_quick_fly)
	await _await_reset_commit(runtime, "fallback_prompt", false, "terrain3d_range", "initial keyboard fallback Quick Fly")
	await _snapshot("00_keyboard_fallback_preconfirm")
	var fallback_third_person_camera := runtime.get_node_or_null("ThirdPersonCamera") as Camera3D
	_expect(runtime.screen == "fallback_prompt" and runtime.loaded_map_id == "terrain3d_range" and runtime.loaded_map != null and fallback_third_person_camera != null and root.get_camera_3d() == fallback_third_person_camera and runtime.third_person_view and runtime._airsim_camera_source() == runtime.chase_camera, "no-controller Quick Fly shows Terrain Range through the default third-person player camera while AirSim remains FPV before keyboard fallback confirmation")
	var retained_terrain_range: Node3D = runtime.loaded_map
	if fallback_third_person_camera != null:
		var fallback_local_camera_offset: Vector3 = runtime.drone_body.global_basis.inverse() * (fallback_third_person_camera.global_position - runtime.drone_body.global_position)
		_expect(fallback_local_camera_offset.y > 0.0 and fallback_local_camera_offset.z > 0.0, "no-controller Quick Fly keeps the third-person camera above and behind the drone")
	_tap(KEY_R)
	await _settle(2)
	_expect(runtime.screen == "fallback_prompt" and not runtime.takeoff_requested and not runtime.native.call("flight_control_armed"), "reset cannot bypass input confirmation")
	_tap(KEY_ESCAPE)
	await _settle(2)
	_expect(runtime.screen == "main_menu" and runtime.loaded_map == retained_terrain_range and runtime.loaded_map_id == "terrain3d_range" and runtime.paused and runtime.drone_body.freeze and not runtime.native.call("flight_control_armed") and runtime.player_view_label != null and not runtime.player_view_label.visible, "canceling no-controller Quick Fly retains the frozen, disarmed Terrain Range while hiding flight state")
	var known_device_id := await _inject_known_gamepad()
	_expect(known_device_id >= 0, "virtual SDL gamepad registers as a known controller")
	device_state.replace_snapshot([known_device_id], [known_device_id])
	Input.joy_connection_changed.emit(known_device_id, true)
	await _settle(2)
	var menu_controller_button: Button = runtime.get_node_or_null("MainMenu/Entries/Controller")
	_expect(menu_controller_button != null, "main menu exposes Controller")
	if menu_controller_button != null:
		_click(menu_controller_button)
	await _settle(2)
	_expect(runtime.screen == "controller_confirmation", "top-level Controller opens confirmation")
	var menu_controller_confirmation: Button = runtime.get_node_or_null("FlightHud/ControllerConfirmation/Rows/UseXboxDefaultProfile")
	_expect(menu_controller_confirmation != null, "top-level Controller exposes confirmation")
	if menu_controller_confirmation != null:
		_click(menu_controller_confirmation)
	await _settle(2)
	_expect(runtime.screen == "main_menu", "top-level Controller confirmation returns to main menu")
	var settings_button: Button = runtime.get_node_or_null("MainMenu/Entries/Settings")
	_expect(settings_button != null, "main menu exposes Settings")
	if settings_button != null:
		_click(settings_button)
	await _settle(2)
	_expect(runtime.screen == "settings", "Settings entry opens Settings")
	var graphics_button: Button = runtime.get_node_or_null("MainMenu/SettingsPanel/Rows/Graphics")
	_expect(graphics_button != null, "Settings exposes Graphics")
	if graphics_button != null:
		_click(graphics_button)
	await _settle(2)
	_expect(runtime.screen == "graphics", "Graphics entry opens Graphics")
	var scale_slider: HSlider = runtime.get_node_or_null("MainMenu/GraphicsPanel/Rows/RenderScale")
	var apply_button: Button = runtime.get_node_or_null("MainMenu/GraphicsPanel/Rows/Apply")
	_expect(scale_slider != null and apply_button != null, "Graphics exposes scale and Apply")
	_expect(runtime.get_viewport().gui_get_focus_owner() == scale_slider, "Graphics opens with RenderScale focused")
	var back_button: Button = runtime.get_node_or_null("MainMenu/GraphicsPanel/Rows/Back")
	if scale_slider != null and apply_button != null:
		scale_slider.value = 0.75
		await _settle(1)
		_expect(absf(runtime.get_viewport().scaling_3d_scale - 0.75) <= 0.000001, "Graphics slider previews the viewport scale")
		apply_button.pressed.emit()
		await _settle(2)
		_expect_persisted_render_scale(runtime, 0.75, "Graphics Apply persists the render scale")
		scale_slider.value = 0.50
		await _settle(1)
	if back_button != null:
		_click(back_button)
	await _settle(2)
	_expect(absf(runtime.get_viewport().scaling_3d_scale - 0.75) <= 0.000001, "Graphics Back restores the committed scale")
	_expect(runtime.get_viewport().gui_get_focus_owner() == graphics_button, "Graphics Back returns focus to the Settings Graphics entry")
	var rates_button: Button = runtime.get_node_or_null("MainMenu/SettingsPanel/Rows/Rates")
	_expect(rates_button != null, "Settings exposes Rates")
	if rates_button != null:
		_click(rates_button)
	await _settle(2)
	_expect(runtime.screen == "rates", "Rates entry opens Rates")
	_expect(runtime.rates_panel != null and runtime.rates_panel.is_visible_in_tree(), "Rates panel is visible")
	_expect(runtime.rates_json_editor != null and runtime.rates_json_editor.text.contains("rc_rate"), "Rates panel exposes JSON editor")
	var export_button: Button = runtime.get_node_or_null("MainMenu/RatesPanel/Scroll/Rows/Actions/ExportJson")
	var import_button: Button = runtime.get_node_or_null("MainMenu/RatesPanel/Scroll/Rows/Actions/ImportJson")
	var reset_rates_button: Button = runtime.get_node_or_null("MainMenu/RatesPanel/Scroll/Rows/Actions/ResetDefaults")
	_expect(export_button != null and import_button != null and reset_rates_button != null, "Rates panel exposes JSON export, import, and reset")
	if runtime.rates_json_editor != null:
		runtime.rates_json_editor.text = JSON.stringify({
			"schema_version": 1,
			"rc_rate": 1.15,
			"super_rate": 0.72,
			"expo": 0.25,
		})
	await _settle(1)
	_expect(runtime.rates_diff_label.text.contains("CURRENT vs BETAFLIGHT IMPORTED"), "Rates panel shows current-vs-Betaflight diff")
	if import_button != null:
		var rates_scroll: ScrollContainer = runtime.get_node("MainMenu/RatesPanel/Scroll")
		rates_scroll.scroll_vertical = rates_scroll.get_v_scroll_bar().max_value
		await _settle(1)
		import_button.pressed.emit()
	await _settle(2)
	_expect(absf(float(runtime.rates_profile.get("rc_rate", 0.0)) - 1.15) <= 0.000001, "Rates JSON import applies RC Rate")
	_expect(absf(float(runtime.rates_profile.get("expo", 0.0)) - 0.25) <= 0.000001, "Rates JSON import applies Expo")
	var persisted_rates: Dictionary = runtime.settings_store.load_document()
	var persisted_rate_values = persisted_rates.document.get("rates") if persisted_rates.ok else null
	_expect(persisted_rates.ok and typeof(persisted_rate_values) == TYPE_DICTIONARY and absf(float(persisted_rate_values.get("rc_rate", 0.0)) - 1.15) <= 0.000001, "Rates JSON import persists through SettingsStore")
	if export_button != null:
		export_button.pressed.emit()
	_expect(runtime.rates_json_editor.text.contains("1.15"), "Rates panel exports the current JSON")
	var retained_rc_rate := float(runtime.rates_profile.get("rc_rate", 0.0))
	if runtime.rates_json_editor != null:
		runtime.rates_json_editor.text = "{invalid-json"
	if import_button != null:
		import_button.pressed.emit()
	_expect(runtime.rates_status_label.text.contains("Import rejected") and absf(float(runtime.rates_profile.get("rc_rate", 0.0)) - retained_rc_rate) <= 0.000001, "Invalid rates import is rejected without applying")
	if reset_rates_button != null:
		reset_rates_button.pressed.emit()
	_expect(absf(float(runtime.rates_profile.get("rc_rate", 0.0)) - 1.0) <= 0.000001, "Rates reset restores defaults")
	var rates_back_button: Button = runtime.get_node_or_null("MainMenu/RatesPanel/Scroll/Rows/Actions/Back")
	if rates_back_button != null:
		runtime.show_settings()
	await _settle(2)
	_expect(runtime.screen == "settings", "Rates panel returns to Settings")
	var settings_controller_button: Button = runtime.get_node_or_null("MainMenu/SettingsPanel/Rows/Controller")
	_expect(settings_controller_button != null, "Settings exposes Controller")
	if settings_controller_button != null:
		_click(settings_controller_button)
	await _settle(2)
	_expect(runtime.screen == "controller_settings", "Settings Controller entry opens Controller settings")
	var controller_settings: Control = runtime.get_node_or_null("MainMenu/ControllerSettingsPanel")
	var device_label: Label = runtime.get_node_or_null("MainMenu/ControllerSettingsPanel/Rows/CurrentDevice")
	var reset_button: Button = runtime.get_node_or_null("MainMenu/ControllerSettingsPanel/Rows/ResetXboxDefault")
	_expect(controller_settings != null and controller_settings.is_visible_in_tree(), "Controller settings panel is visible")
	_expect(device_label != null and device_label.text.contains(str(known_device_id)), "Controller settings shows the current device")
	_expect(reset_button != null and reset_button.text == "RESET TO XBOX DEFAULT", "Controller settings exposes Xbox reset")
	if reset_button != null:
		_click(reset_button)
	await _settle(2)
	_expect(runtime.screen == "controller_confirmation", "Xbox reset requires confirmation before changing the session profile")
	var reset_confirmation: Button = runtime.get_node_or_null("FlightHud/ControllerConfirmation/Rows/UseXboxDefaultProfile")
	_expect(reset_confirmation != null, "Xbox reset exposes the confirmation action")
	if reset_confirmation != null:
		_click(reset_confirmation)
	await _settle(2)
	_expect(runtime.screen == "controller_settings", "Xbox reset confirmation returns to Controller settings")
	runtime.persisted_gamepad_profile = null
	runtime.session_gamepad_profile = null
	runtime.session_gamepad_device_id = -1
	runtime.show_main_menu()
	var quick_fly_entry: Button = runtime.get_node_or_null("MainMenu/Entries/QuickFly")
	if quick_fly_entry != null:
		_click(quick_fly_entry)
	await _settle(10)
	await _snapshot("01_controller_confirmation")
	_expect(runtime.screen == "controller_confirmation", "known unconfirmed gamepad enters visible Xbox profile confirmation")
	_expect(runtime.loaded_map_id == "terrain3d_range" and runtime.loaded_map == retained_terrain_range and root.get_camera_3d() == runtime.third_person_camera and runtime.third_person_view and runtime._airsim_camera_source() == runtime.chase_camera, "Quick Fly confirmation reuses the retained Terrain Range through the default third-person player camera while AirSim remains FPV")
	_expect(runtime.controller_confirmation_panel != null and runtime.controller_confirmation_panel.is_visible_in_tree(), "Controller confirmation panel is visible")
	var mapping: Label = runtime.get_node_or_null("FlightHud/ControllerConfirmation/Rows/FixedMapping")
	var axes: Label = runtime.get_node_or_null("FlightHud/ControllerConfirmation/Rows/LiveAxes")
	var confirm_button: Button = runtime.get_node_or_null("FlightHud/ControllerConfirmation/Rows/UseXboxDefaultProfile")
	_expect(mapping != null and mapping.text.contains("roll -> Axis 2") and mapping.text.contains("throttle -> Axis 1"), "confirmation shows fixed Xbox mapping")
	for expected_axis in [
		"roll: Raw +0.250 | Normalized +0.167",
		"pitch: Raw -0.750 | Normalized -0.694",
		"yaw: Raw +0.500 | Normalized +0.420",
		"throttle: Raw -0.500 | Normalized +0.420"
	]:
		_expect(axes != null and axes.text.contains(expected_axis), "confirmation shows live axis value %s" % expected_axis)
	for update in [
		{"axis": JOY_AXIS_LEFT_X, "value": -0.5, "expected": "yaw: Raw -0.500 | Normalized -0.420"},
		{"axis": JOY_AXIS_LEFT_Y, "value": 0.5, "expected": "throttle: Raw +0.500 | Normalized -0.420"},
		{"axis": JOY_AXIS_RIGHT_X, "value": -0.25, "expected": "roll: Raw -0.250 | Normalized -0.167"},
		{"axis": JOY_AXIS_RIGHT_Y, "value": 0.75, "expected": "pitch: Raw +0.750 | Normalized +0.694"}
	]:
		_inject_joy_axis(known_device_id, update.axis, update.value)
		await _settle(2)
		_expect(axes != null and axes.text.contains(update.expected), "confirmation updates live axis value %s" % update.expected)
	_expect(confirm_button != null and confirm_button.text == "USE XBOX DEFAULT PROFILE", "confirmation exposes Xbox default profile action")
	if confirm_button != null:
		_click(confirm_button)
	await _settle(10)
	_expect(runtime.screen == "preflight", "confirmation enters low-throttle preflight")
	_expect(runtime.loaded_map_id == "terrain3d_range" and runtime.loaded_map == retained_terrain_range, "Quick Fly preflight reuses the retained Terrain Range")
	var spawn := runtime.loaded_map.get_node_or_null("SpawnNorth") as Marker3D if runtime.loaded_map != null else null
	_expect(spawn != null and runtime.drone_body.global_position.distance_to(spawn.global_position) <= 1e-6, "Terrain Range load places the drone at SpawnNorth")
	var natural_environment := runtime.loaded_map.get_node_or_null("AeroSimEnvironment") as WorldEnvironment if runtime.loaded_map != null else null
	var natural_clouds := runtime.loaded_map.get_node_or_null("CloudLayer") as Node3D if runtime.loaded_map != null else null
	_expect(natural_environment != null and natural_environment.environment != null and natural_environment.environment.background_mode == Environment.BG_SKY and natural_environment.environment.sky != null and natural_environment.environment.fog_enabled and natural_environment.environment.tonemap_mode != Environment.TONE_MAPPER_LINEAR and natural_clouds != null and not natural_clouds.find_children("*", "MeshInstance3D", true, false).is_empty(), "Terrain Range preflight snapshot includes the fixed sky, cloud, fog, and tone-mapped environment")
	var north_platform := runtime.loaded_map.get_node_or_null("SpawnNorthPlatform") as StaticBody3D if runtime.loaded_map != null else null
	var north_platform_mesh := north_platform.get_node_or_null("Mesh") as MeshInstance3D if north_platform != null else null
	var north_platform_collision := north_platform.get_node_or_null("CollisionShape3D") as CollisionShape3D if north_platform != null else null
	_expect(north_platform != null and north_platform_mesh != null and north_platform_mesh.is_visible_in_tree() and north_platform_collision != null and north_platform_collision.shape is BoxShape3D and int(north_platform.get_meta("airsim_segmentation_id", -1)) == 2 and spawn != null and absf(north_platform.global_position.x - spawn.global_position.x) <= 1e-6 and absf(north_platform.global_position.z - spawn.global_position.z) <= 1e-6, "Terrain Range SpawnNorth has a visible, collision-bearing launch platform without moving the canonical spawn")
	var airsim_state: Dictionary = runtime._airsim_state("")
	var airsim_kinematics: Dictionary = airsim_state.get("state", {}).get("kinematics_estimated", {})
	var airsim_position: Dictionary = airsim_kinematics.get("position", {})
	_expect(airsim_state.get("ok", false) and absf(float(airsim_position.get("x_val", 1.0))) <= 1e-6 and absf(float(airsim_position.get("y_val", 1.0))) <= 1e-6 and absf(float(airsim_position.get("z_val", 1.0))) <= 1e-6, "AirSim NED origin follows Terrain Range SpawnNorth")
	var third_person_camera := runtime.get_node_or_null("ThirdPersonCamera") as Camera3D
	_expect(third_person_camera != null and root.get_camera_3d() == third_person_camera and runtime.third_person_view, "Terrain Range Quick Fly preflight defaults the player to the rear third-person camera")
	_expect(runtime._airsim_camera_source() == runtime.chase_camera, "default player third-person view preserves the AirSim FPV source camera")
	var player_view: Label = runtime.get_node_or_null("FlightHud/StatusMargin/StatusPanel/StatusRows/PlayerView")
	_expect(player_view != null and player_view.text == "VIEW: THIRD PERSON" and runtime.key_hints_label.text.contains("BACK View"), "third-person view exposes the localized active-view label and controller hint")
	if third_person_camera != null:
		var local_camera_offset: Vector3 = runtime.drone_body.global_basis.inverse() * (third_person_camera.global_position - runtime.drone_body.global_position)
		_expect(local_camera_offset.y > 0.0 and local_camera_offset.z > 0.0, "third-person camera remains above and behind the drone")
	var terrain_range_terrain: Node3D = runtime.loaded_map.get_node_or_null("Terrain3D") as Node3D if runtime.loaded_map != null else null
	var terrain_range_data: Variant = terrain_range_terrain.data if terrain_range_terrain != null else null
	var terrain_grass_sample: Vector3 = terrain_range_data.get_texture_id(Vector3(80.0, 0.0, -80.0)) if terrain_range_data != null else Vector3(-1.0, -1.0, -1.0)
	var terrain_soil_sample: Vector3 = terrain_range_data.get_texture_id(Vector3(8.0, 0.0, -36.0)) if terrain_range_data != null else Vector3(-1.0, -1.0, -1.0)
	var terrain_rock_sample: Vector3 = terrain_range_data.get_texture_id(Vector3(24.0, 0.0, -44.0)) if terrain_range_data != null else Vector3(-1.0, -1.0, -1.0)
	var north_ridge_rock := runtime.loaded_map.get_node_or_null("NorthRidgeRock") as StaticBody3D if runtime.loaded_map != null else null
	var east_ridge_rock := runtime.loaded_map.get_node_or_null("EastRidgeRock") as StaticBody3D if runtime.loaded_map != null else null
	var north_ridge_collision := north_ridge_rock.get_node_or_null("CollisionShape3D") as CollisionShape3D if north_ridge_rock != null else null
	var east_ridge_collision := east_ridge_rock.get_node_or_null("CollisionShape3D") as CollisionShape3D if east_ridge_rock != null else null
	_expect(terrain_range_terrain != null and terrain_range_data != null and int(terrain_grass_sample.x) == 1 and int(terrain_soil_sample.y) == 2 and terrain_soil_sample.z >= 0.99 and int(terrain_rock_sample.y) == 0 and terrain_rock_sample.z >= 0.99 and terrain_range_data.get_height(Vector3(30.0, 0.0, -72.0)) >= 3.0 and north_platform != null and north_platform_collision != null and north_platform_collision.shape is BoxShape3D and spawn != null and north_platform.global_position.distance_to(Vector3(spawn.global_position.x, north_platform.global_position.y, spawn.global_position.z)) <= 1e-6 and north_ridge_rock != null and north_ridge_collision != null and north_ridge_collision.shape != null and east_ridge_rock != null and east_ridge_collision != null and east_ridge_collision.shape != null and natural_environment != null and natural_environment.environment != null and natural_environment.environment.background_mode == Environment.BG_SKY and natural_environment.environment.fog_enabled and third_person_camera != null and root.get_camera_3d() == third_person_camera and runtime._airsim_camera_source() == runtime.chase_camera, "canonical Terrain Range preflight combines colored ground, elevated natural landmarks, the SpawnNorth platform, authored sky/fog, and separate third-person player and FPV AirSim cameras")
	await _snapshot("01_third_person_preflight")
	_tap(KEY_V)
	await _settle(2)
	_expect(root.get_camera_3d() == runtime.chase_camera and runtime.chase_camera.current and runtime._airsim_camera_source() == runtime.chase_camera and player_view != null and player_view.text == "VIEW: FPV", "V switches the default player view to FPV with the matching HUD label while preserving the AirSim source")
	runtime.quick_fly()
	await _await_reset_commit(runtime, "preflight", false, "terrain3d_range", "second Quick Fly preflight")
	_expect(runtime.screen == "preflight" and root.get_camera_3d() == third_person_camera and runtime.third_person_view and runtime._airsim_camera_source() == runtime.chase_camera and player_view != null and player_view.text == "VIEW: THIRD PERSON", "each Quick Fly session resets the player view to third-person while AirSim remains FPV")
	_inject_joy_button(known_device_id, JOY_BUTTON_BACK, true)
	await _settle(4)
	_inject_joy_button(known_device_id, JOY_BUTTON_BACK, false)
	_expect(root.get_camera_3d() == runtime.chase_camera and not runtime.third_person_view and player_view != null and player_view.text == "VIEW: FPV", "BACK switches the default third-person player view back to FPV with the matching HUD label")
	_expect(runtime.time_trial != null and runtime.time_trial.checkpoint_positions.size() == 3, "Terrain Range exposes a three-checkpoint Time Trial")
	var trial_status: Label = runtime.get_node_or_null("FlightHud/StatusMargin/StatusPanel/StatusRows/TimeTrialStatus")
	_expect(trial_status != null and trial_status.text.contains("TIME TRIAL") and trial_status.text.contains("NEXT 1/3"), "preflight HUD exposes the next Time Trial checkpoint")
	var finish_position: Vector3 = runtime.loaded_map.get_node("TimeTrial/Finish").global_position
	if runtime.time_trial != null:
		runtime.time_trial.advance(finish_position, 0.25)
	_expect(runtime.screen == "preflight" and not runtime.time_trial.finished, "preflight cannot finish a Time Trial before takeoff")
	runtime._airsim_disarm_requested = false
	for axis in [JOY_AXIS_LEFT_X, JOY_AXIS_LEFT_Y, JOY_AXIS_RIGHT_X, JOY_AXIS_RIGHT_Y]:
		_inject_joy_axis(known_device_id, axis, 0.0)
	_inject_joy_axis(known_device_id, JOY_AXIS_LEFT_Y, 1.0)
	_inject_joy_button(known_device_id, JOY_BUTTON_A, true)
	await _settle(1)
	_inject_joy_button(known_device_id, JOY_BUTTON_A, false)
	_expect(runtime.flight_mode == "ASSISTED_HOLD", "A takeoff hands off to Assisted Hold while the arm-low stick remains down")
	_assisted_hover_evidence = {
		"mode": runtime.flight_mode,
		"roll_raw": Input.get_joy_axis(known_device_id, JOY_AXIS_RIGHT_X),
		"pitch_raw": Input.get_joy_axis(known_device_id, JOY_AXIS_RIGHT_Y),
		"roll_normalized": runtime._profile_axis("roll"),
		"pitch_normalized": runtime._profile_axis("pitch"),
		"endurance_gate": "native_headless",
	}
	_audit_cockpit_three_way_split(runtime, "flight_1280x720")
	await _snapshot("01_assisted_hover")
	_inject_joy_axis(known_device_id, JOY_AXIS_LEFT_Y, 0.0)
	await _settle(30)
	runtime.native.call("arm_flight_control", 0.0)
	runtime.request_takeoff()
	await _await_reset_commit(runtime, "flight", false, "terrain3d_range", "Xbox physical input takeoff")
	runtime.flight_mode = "ANGLE"
	runtime.takeoff_assist_active = false
	var xbox_frd_axis_cases := [
		{"role": "roll", "axis": JOY_AXIS_RIGHT_X, "value": -0.5, "component": 0},
		{"role": "pitch", "axis": JOY_AXIS_RIGHT_Y, "value": -0.5, "component": 1},
	]
	for axis_case in xbox_frd_axis_cases:
		for axis in [JOY_AXIS_LEFT_X, JOY_AXIS_LEFT_Y, JOY_AXIS_RIGHT_X, JOY_AXIS_RIGHT_Y]:
			_inject_joy_axis(known_device_id, axis, 0.0)
		runtime.native.call("reset_flight")
		runtime.drone_body.apply_native_state(Vector3(100.0, 100.0, 100.0), Quaternion.IDENTITY, Vector3.ZERO, Vector3.ZERO)
		runtime.drone_body.reset_contact()
		_inject_joy_axis(known_device_id, axis_case.axis, axis_case.value)
		await physics_frame
		await process_frame
		await _settle_physics(30)
		for role in ["roll", "pitch", "yaw"]:
			if role != axis_case.role:
				_expect(is_zero_approx(runtime._profile_axis(role)), "known Xbox %s FRD gate neutralizes %s input" % [axis_case.role, role])
		var known_xbox_diagnostics: Dictionary = runtime.native.call("flight_control_diagnostics")
		var frd_rates := AirSimCoordinateContract.godot_body_to_frd(Vector3(
			float(known_xbox_diagnostics.get("angular_velocity_x_rad_s", 0.0)),
			float(known_xbox_diagnostics.get("angular_velocity_y_rad_s", 0.0)),
			float(known_xbox_diagnostics.get("angular_velocity_z_rad_s", 0.0))
		))
		_known_xbox_physical_evidence[axis_case.role] = {
			"raw": axis_case.value,
			"frd_omega_rad_s": {"roll": frd_rates.x, "pitch": frd_rates.y, "yaw": frd_rates.z},
		}
		_expect(frd_rates[axis_case.component] < -0.01, "known Xbox physical %s input produces negative FRD %s response" % [axis_case.role, axis_case.role])
	for axis in [JOY_AXIS_LEFT_X, JOY_AXIS_LEFT_Y, JOY_AXIS_RIGHT_X, JOY_AXIS_RIGHT_Y]:
		_inject_joy_axis(known_device_id, axis, 0.0)
	runtime.toggle_altitude_hold()
	runtime.set_paused(true)
	await _settle(2)
	var paused_position: Vector3 = runtime.drone_body.global_position
	var paused_time: float = runtime.airsim_session.simulation_time_seconds
	runtime.show_controller_settings()
	await _settle(2)
	var monitor: Label = runtime.controller_settings_monitor_label
	_expect(monitor != null and monitor.is_visible_in_tree(), "paused flight opens the visible Channel Monitor")
	_expect(monitor != null and monitor.text.contains("ARM: RELEASED | flight control: ARMED"), "Channel Monitor starts with physical A released and flight control armed")
	_expect(monitor != null and monitor.text.contains("MODE: RELEASED | flight mode: ALTITUDE_HOLD"), "Channel Monitor starts with physical Y released and Assisted Hold mode")
	var monitor_before_axes := monitor.text if monitor != null else ""
	_inject_joy_button(known_device_id, JOY_BUTTON_A, true)
	await _settle(2)
	_expect(monitor != null and monitor.text.contains("ARM: PRESSED | flight control: ARMED"), "A button physical state remains distinct from already armed control")
	_inject_joy_button(known_device_id, JOY_BUTTON_Y, true)
	await _settle(2)
	_expect(monitor != null and monitor.text.contains("MODE: PRESSED | flight mode: ANGLE"), "Y button physical state shows the actual resulting flight mode")
	var monitor_start_count: int = runtime.controller_monitor_refresh_count
	var monitor_start_ms := Time.get_ticks_msec()
	while Time.get_ticks_msec() - monitor_start_ms < 1_000:
		_inject_joy_axis(known_device_id, JOY_AXIS_LEFT_X, 0.5)
		_inject_joy_axis(known_device_id, JOY_AXIS_LEFT_Y, -0.5)
		_inject_joy_axis(known_device_id, JOY_AXIS_RIGHT_X, 0.25)
		_inject_joy_axis(known_device_id, JOY_AXIS_RIGHT_Y, -0.75)
		await process_frame
	var monitor_elapsed_seconds := float(Time.get_ticks_msec() - monitor_start_ms) / 1000.0
	var monitor_refresh_count: int = runtime.controller_monitor_refresh_count - monitor_start_count
	var monitor_rate_hz: float = float(monitor_refresh_count) / monitor_elapsed_seconds
	var position_frozen: bool = runtime.drone_body.global_position.distance_to(paused_position) <= 1e-6
	var simulation_time_frozen: bool = absf(runtime.airsim_session.simulation_time_seconds - paused_time) <= 1e-6
	_expect(position_frozen, "Channel Monitor leaves paused physics position frozen")
	_expect(simulation_time_frozen, "Channel Monitor leaves paused simulation time frozen")
	_expect(monitor != null and monitor.text != monitor_before_axes, "Channel Monitor renders injected axes while paused")
	for expected_axis_row in [
		"roll:     [---------|-------] raw +0.250 | normalized +0.167",
		"pitch:    [--|--------------] raw -0.750 | normalized -0.694",
		"yaw:      [-----------|-----] raw +0.500 | normalized +0.420",
		"throttle: [-----------|-----] raw -0.500 | normalized +0.420 | HIGH",
	]:
		_expect(monitor != null and monitor.text.contains(expected_axis_row), "Channel Monitor renders canonical axis row %s" % expected_axis_row)
	await _snapshot("07_channel_monitor_paused")
	_inject_joy_button(known_device_id, JOY_BUTTON_A, false)
	_inject_joy_button(known_device_id, JOY_BUTTON_Y, false)
	await _settle(2)
	_expect(monitor != null and monitor.text.contains("ARM: RELEASED | flight control: ARMED"), "A release keeps flight control armed")
	_expect(monitor != null and monitor.text.contains("MODE: RELEASED | flight mode: ANGLE"), "Y release keeps the actual flight mode")
	_channel_monitor_evidence = {
		"elapsed_wall_time_seconds": monitor_elapsed_seconds,
		"refresh_count": monitor_refresh_count,
		"refresh_rate_hz": monitor_rate_hz,
		"position_frozen": position_frozen,
		"simulation_time_frozen": simulation_time_frozen,
		"screenshot_path": "%s/07_channel_monitor_paused.png" % _out_dir,
	}
	runtime.screen = "flight"
	runtime._refresh_flight_hud()
	var pause_rates_button: Button = runtime.get_node_or_null("FlightHud/PausePanel/Rows/Rates")
	var pause_camera_button: Button = runtime.get_node_or_null("FlightHud/PausePanel/Rows/Camera")
	var pause_osd_button: Button = runtime.get_node_or_null("FlightHud/PausePanel/Rows/OSD")
	var pause_controller_monitor_button: Button = runtime.get_node_or_null("FlightHud/PausePanel/Rows/ControllerMonitor")
	var pause_status_diagram_button: Button = runtime.get_node_or_null("FlightHud/PausePanel/Rows/StatusDiagram")
	_expect(runtime.paused and pause_rates_button != null, "Pause Overlay exposes Rates")
	_expect(pause_camera_button != null and pause_osd_button != null, "Pause Overlay exposes Camera and OSD")
	_expect(pause_controller_monitor_button != null and pause_status_diagram_button != null, "Pause Overlay exposes Controller Monitor and Status Diagram")
	if pause_controller_monitor_button != null:
		_click(pause_controller_monitor_button)
		await _settle(2)
		_expect(runtime.screen == "controller_settings" and runtime.controller_settings_monitor_label != null and runtime.controller_settings_monitor_label.is_visible_in_tree(), "Pause Overlay Controller Monitor opens its live panel")
		var pause_controller_back: Button = runtime.get_node_or_null("MainMenu/ControllerSettingsPanel/Rows/Back")
		if pause_controller_back != null:
			_click(pause_controller_back)
		await _settle(2)
		_expect(runtime.screen == "flight" and runtime.paused, "Controller Monitor Back returns to the paused flight")
	if pause_status_diagram_button != null:
		_click(pause_status_diagram_button)
		await _settle(2)
		_expect(runtime.status_diagram_fullscreen and runtime.status_diagram != null and runtime.status_diagram.call("get_layout_mode") == "full", "Pause Overlay Status Diagram opens its fullscreen dashboard")
		var status_diagram_back_button: Button = runtime.status_diagram_back_button
		_expect(status_diagram_back_button != null and status_diagram_back_button.is_visible_in_tree(), "Status Diagram exposes a user-accessible Back button")
		if status_diagram_back_button != null:
			_click(status_diagram_back_button)
		await _settle(2)
		_expect(not runtime.status_diagram_fullscreen and runtime.paused and pause_status_diagram_button.is_visible_in_tree(), "Status Diagram Back returns to the paused overlay")
	_expect(runtime.get_node_or_null("FlightHud/FpvOsd") != null and runtime.get_node_or_null("FlightHud/AnalogNoise") != null, "flight HUD owns the FPV OSD and analog-noise overlay")
	var camera_candidate: Dictionary = runtime.camera_profile.duplicate(true)
	camera_candidate["camera_angle_deg"] = 35.0
	camera_candidate["fov_deg"] = 135.0
	var camera_save: Dictionary = runtime.call("_save_camera_profile", camera_candidate)
	_expect(camera_save.ok and absf(runtime.chase_camera.fov - 135.0) <= 0.000001, "Camera settings apply immediately to the live FPV camera")
	var race_profile: Dictionary = OsdProfile.profile_for_preset("Race")
	var osd_save: Dictionary = runtime.call("_save_osd_profile", race_profile)
	var persisted_osd: Dictionary = runtime.settings_store.load_document()
	_expect(osd_save.ok and persisted_osd.ok and persisted_osd.document.osd.preset == "Race", "Race OSD preset persists through SettingsStore")
	var lap_label: Label = runtime.get_node_or_null("FlightHud/FpvOsd/LapCheckpoint")
	_expect(lap_label != null and runtime.time_trial != null and lap_label.text.contains("%d/3" % (runtime.time_trial.next_checkpoint_index + 1)), "Race OSD lap/checkpoint uses ordered TimeTrial truth: %s" % (lap_label.text if lap_label != null else "<missing>"))
	var acro_key := InputEventKey.new()
	acro_key.keycode = KEY_C
	acro_key.physical_keycode = KEY_C
	acro_key.pressed = true
	runtime._unhandled_input(acro_key)
	_expect(runtime.flight_mode == "ANGLE", "C cannot switch to ACRO while paused")
	runtime.show_rates("flight")
	await _settle(2)
	_expect(runtime.screen == "rates" and runtime.paused, "Rates opened from Pause Overlay keeps pause state")
	runtime._close_rates_panel()
	_expect(runtime.screen == "flight" and runtime.paused, "Rates returns to paused flight")
	runtime.set_paused(false)
	runtime._unhandled_input(acro_key)
	_expect(runtime.flight_mode == "ACRO", "C switches to ACRO during flight")
	var curve_before: PackedVector2Array = runtime.rates_curve_line.points
	var rc_slider: HSlider = runtime.rates_sliders["rc_rate"]
	rc_slider.value = 1.25
	await _settle(2)
	_expect(absf(float(runtime.rates_profile.get("rc_rate", 0.0)) - 1.25) <= 0.000001, "Rates slider updates the live ACRO profile")
	var curve_after: PackedVector2Array = runtime.rates_curve_line.points
	_expect(curve_before.size() == curve_after.size() and curve_before.size() > 0 and absf(curve_before[curve_before.size() - 1].y - curve_after[curve_after.size() - 1].y) > 0.000001, "Rates slider updates the native curve preview")
	_complete_time_trial(runtime)
	await _settle(2)
	_expect(runtime.screen == "finish" and runtime.paused, "reaching Finish stops flight and opens the Time Trial result state")
	await _snapshot("06_finish")
	var finish_panel: Control = runtime.get_node_or_null("FlightHud/FinishPanel")
	var finish_summary: Label = runtime.get_node_or_null("FlightHud/FinishPanel/Rows/Summary")
	_expect(finish_panel != null and finish_panel.is_visible_in_tree() and finish_summary != null and finish_summary.text.contains("Time"), "finish panel shows the completed trial time")
	_tap(KEY_P)
	await _settle(2)
	_expect(runtime.screen == "finish" and runtime.paused, "P cannot resume a finished Time Trial")
	var finish_retry: Button = runtime.get_node_or_null("FlightHud/FinishPanel/Rows/Retry")
	_expect(finish_retry != null and finish_retry.text == "RETRY", "finish panel exposes Retry")
	if finish_retry != null:
		_click(finish_retry)
	await _await_reset_commit(runtime, "flight", false, "terrain3d_range", "finish Retry")
	_expect(runtime.screen == "flight" and not runtime.paused and runtime.time_trial.active and runtime.time_trial.next_checkpoint_index == 0, "Retry respawns at the start and restarts the trial")
	_tap(KEY_P)
	await _settle(2)
	var pause_panel: Control = runtime.get_node_or_null("FlightHud/PausePanel")
	_expect(runtime.paused and pause_panel != null and pause_panel.is_visible_in_tree(), "P opens the pause overlay")
	var paused_trial_time: float = runtime.time_trial.elapsed_seconds
	await _settle(8)
	_expect(absf(runtime.time_trial.elapsed_seconds - paused_trial_time) <= 1e-6, "pause freezes the Time Trial simulation clock")
	var resume_button: Button = runtime.get_node_or_null("FlightHud/PausePanel/Rows/Resume")
	if resume_button != null:
		_click(resume_button)
	await _settle(2)
	_expect(not runtime.paused, "pause overlay resumes the same flight")
	_tap(KEY_P)
	await _settle(2)
	var change_spawn_button: Button = runtime.get_node_or_null("FlightHud/PausePanel/Rows/ChangeSpawn")
	var north_spawn_before_change := runtime.loaded_map.get_node_or_null("SpawnNorth") as Marker3D
	if change_spawn_button != null:
		_click(change_spawn_button)
	await _await_reset_commit(runtime, "flight", false, "terrain3d_range", "Change Spawn")
	var south_spawn_after_change := runtime.loaded_map.get_node_or_null("SpawnSouth") as Marker3D
	var south_platform_after_change := runtime.loaded_map.get_node_or_null("SpawnSouthPlatform") as StaticBody3D if runtime.loaded_map != null else null
	var south_platform_collision := south_platform_after_change.get_node_or_null("CollisionShape3D") as CollisionShape3D if south_platform_after_change != null else null
	_expect(runtime.screen == "flight" and runtime.loaded_map_id == "terrain3d_range" and not runtime.paused and north_spawn_before_change != null and south_spawn_after_change != null and runtime.drone_body.global_position.distance_to(south_spawn_after_change.global_position) <= 1e-6 and south_platform_after_change != null and south_platform_collision != null and south_platform_collision.shape is BoxShape3D and int(south_platform_after_change.get_meta("airsim_segmentation_id", -1)) == 8 and absf(south_platform_after_change.global_position.x - south_spawn_after_change.global_position.x) <= 1e-6 and absf(south_platform_after_change.global_position.z - south_spawn_after_change.global_position.z) <= 1e-6, "Change Spawn reaches the retained South spawn on its collision-bearing platform")
	var south_spawn_airsim_state: Dictionary = runtime._airsim_state("")
	var south_spawn_airsim_position: Dictionary = south_spawn_airsim_state.get("state", {}).get("kinematics_estimated", {}).get("position", {})
	_expect(south_spawn_airsim_state.get("ok", false) and absf(float(south_spawn_airsim_position.get("x_val", 1.0))) <= 1e-6 and absf(float(south_spawn_airsim_position.get("y_val", 1.0))) <= 1e-6 and absf(float(south_spawn_airsim_position.get("z_val", 1.0))) <= 1e-6, "Change Spawn keeps the AirSim NED origin at the active formal spawn")
	runtime._airsim_disarm_requested = false
	runtime.native.call("arm_flight_control", 0.0)
	runtime.request_takeoff()
	await _await_reset_commit(runtime, "flight", false, "terrain3d_range", "finish Change Map takeoff")
	_complete_time_trial(runtime)
	await _settle(2)
	var finish_change_map: Button = runtime.get_node_or_null("FlightHud/FinishPanel/Rows/ChangeMap")
	_expect(finish_change_map != null and finish_change_map.is_visible_in_tree(), "finish panel exposes Change Map")
	if finish_change_map != null:
		_click(finish_change_map)
	await _await_reset_commit(runtime, "preflight", false, "terrain3d_range", "finish Change Map")
	_expect(runtime.screen == "preflight" and runtime.loaded_map_id == "terrain3d_range", "finish Change Map returns to Terrain Range preflight")
	runtime._airsim_disarm_requested = false
	runtime.native.call("arm_flight_control", 0.0)
	runtime.request_takeoff()
	await _await_reset_commit(runtime, "flight", false, "terrain3d_range", "finish Exit takeoff")
	_complete_time_trial(runtime)
	await _settle(2)
	var finish_exit: Button = runtime.get_node_or_null("FlightHud/FinishPanel/Rows/Exit")
	_expect(finish_exit != null and finish_exit.is_visible_in_tree(), "finish panel exposes Exit")
	runtime.quit_on_exit = false
	if finish_exit != null:
		_click(finish_exit)
	await _settle(4)
	_expect(runtime.screen == "main_menu" and runtime.loaded_map == null, "finish Exit unloads the map and returns to the main menu")
	_tap(KEY_P)
	await _settle(2)
	_expect(runtime.screen == "main_menu", "P cannot resume after Exit")
	runtime.enter_preflight()
	await _await_reset_commit(runtime, "preflight", false, "terrain3d_range", "fresh Terrain Range preflight")
	var terrain_range_frame := await _snapshot("01_terrain_range_preflight")
	_expect(_max_color_ratio(terrain_range_frame) < 0.99, "Terrain Range preflight capture is not monochrome")
	var canonical_camera_reset: Dictionary = runtime.call("_save_camera_profile", CameraProfile.default_profile())
	_expect(canonical_camera_reset.ok and absf(runtime.chase_camera.fov - CameraProfile.DEFAULT_FOV_DEG) <= 0.000001, "Terrain Range AirSim ground capture restores the canonical FPV camera profile after settings coverage")
	var camera_rpc: Array = runtime.airsim_rpc_server.dispatch([0, 142, "simGetImages", [[
		{"camera_name": "0", "image_type": 0, "pixels_as_float": false, "compress": true},
		{"camera_name": "0", "image_type": 1, "pixels_as_float": true, "compress": false},
		{"camera_name": "0", "image_type": 5, "pixels_as_float": false, "compress": false},
	], "", false]])
	_expect(camera_rpc[2] == null and camera_rpc[3].size() == 3, "simGetImages returns all requested Terrain Range camera responses in order")
	if camera_rpc[2] == null and camera_rpc[3].size() == 3:
		var scene_response: Dictionary = camera_rpc[3][0]
		var depth_response: Dictionary = camera_rpc[3][1]
		var segmentation_response: Dictionary = camera_rpc[3][2]
		_expect(scene_response.image_type == 0 and scene_response.width == 256 and scene_response.height == 144 and scene_response.image_data_uint8.size() > 8, "Scene response has AirSim dimensions and PNG bytes")
		var scene_image := Image.new()
		var scene_decode := scene_image.load_png_from_buffer(scene_response.image_data_uint8)
		_expect(scene_decode == OK and not scene_image.is_empty() and _max_color_ratio(scene_image) < 0.99, "Scene PNG decodes to an observable rendered view")
		var natural_ground_colors := _natural_ground_color_counts(scene_image)
		_expect(int(natural_ground_colors.grass) >= 12 and int(natural_ground_colors.soil_sand) >= 12, "Terrain Range AirSim scene capture contains visible grass and soil/sand ground colors")
		_expect(depth_response.image_type == 1 and depth_response.pixels_as_float and depth_response.image_data_float.size() == 256 * 144, "DepthPlanar response has one float per pixel")
		_expect(segmentation_response.image_type == 5 and segmentation_response.image_data_uint8.size() == 256 * 144 * 3, "Segmentation raw response has RGB bytes")
		var segmentation_ids := {}
		for offset in range(0, segmentation_response.image_data_uint8.size(), 3):
			var segmentation_id := int(segmentation_response.image_data_uint8[offset]) | (int(segmentation_response.image_data_uint8[offset + 1]) << 8) | (int(segmentation_response.image_data_uint8[offset + 2]) << 16)
			if segmentation_id > 0:
				segmentation_ids[segmentation_id] = true
		_expect(segmentation_ids.has(1), "Segmentation raw response includes the catalog-backed Ground ID")
		_expect(scene_response.time_stamp == depth_response.time_stamp and depth_response.time_stamp == segmentation_response.time_stamp, "multi-request camera responses share one simulation timestamp")
		runtime.airsim_rpc_server.dispatch([0, 144, "simPause", [true]])
		var paused_camera_rpc: Array = runtime.airsim_rpc_server.dispatch([0, 143, "simGetImages", [[{"camera_name": "0", "image_type": 1, "pixels_as_float": true, "compress": false}], "", false]])
		var paused_camera_rpc_again: Array = runtime.airsim_rpc_server.dispatch([0, 145, "simGetImages", [[{"camera_name": "0", "image_type": 1, "pixels_as_float": true, "compress": false}], "", false]])
		_expect(paused_camera_rpc[3][0].time_stamp == depth_response.time_stamp and paused_camera_rpc_again[3][0].time_stamp == paused_camera_rpc[3][0].time_stamp, "paused camera reads keep the simulation timestamp frozen")
		_expect(paused_camera_rpc_again[3][0].image_data_float == paused_camera_rpc[3][0].image_data_float, "paused camera reads repeat the same depth frame")
		runtime.airsim_rpc_server.dispatch([0, 146, "simPause", [false]])
	_expect(not runtime.load_map("missing_map") and runtime.last_error_message.contains("missing_map"), "missing map load names the missing map explicitly")
	_expect(runtime.loaded_map_id == "terrain3d_range" and runtime.loaded_map != null, "missing map load keeps Terrain Range active without a smoke fallback")

	var unknown_device_id := known_device_id + 1
	device_state.replace_snapshot([], [])
	Input.joy_connection_changed.emit(known_device_id, false)
	await _settle(2)
	_expect(runtime.last_profile_status.contains("No controller"), "connection handler refreshes fallback status from the empty adapter snapshot")
	device_state.replace_snapshot([unknown_device_id], [])
	Input.joy_connection_changed.emit(unknown_device_id, true)
	await _settle(10)
	_expect(not device_state.is_joy_known(unknown_device_id) and runtime._first_connected_device() == unknown_device_id, "replacement device is connected and lacks an SDL mapping")
	runtime.quick_fly()
	await _await_reset_commit(runtime, "fallback_prompt", false, "terrain3d_range", "unknown-controller Quick Fly")
	_expect(runtime.screen == "fallback_prompt", "Quick Fly blocks the replaced unknown controller at KeyboardProfile fallback")
	_expect(runtime.arm_status_label != null and runtime.arm_status_label.text.contains("Unsupported controller"), "unknown controller fallback is explicit")

	await _snapshot("02_keyboard_fallback")
	var fallback_button: Button = runtime.arm_takeoff_button
	_expect(fallback_button != null and fallback_button.text == "USE KEYBOARD FALLBACK", "unknown controller exposes the KeyboardProfile fallback control")
	if fallback_button != null:
		_click(fallback_button)
	await _settle(10)
	_expect(runtime.screen == "preflight", "KeyboardProfile fallback enters low-throttle preflight")

	_tap(KEY_T)
	await _await_reset_commit(runtime, "flight", false, "terrain3d_range", "keyboard takeoff")
	await _settle(60)
	_audit_overlay_geometry(runtime, "flight")
	await _snapshot("03_takeoff")
	_expect(runtime.takeoff_requested, "T requests takeoff after Quick Fly")
	var motor_panel: PanelContainer = runtime.get_node_or_null("FlightHud/MotorHudMargin/MotorHudPanel")
	var rotor_panel: Control = runtime.get_node_or_null("FlightHud/MotorHudMargin/MotorHudPanel/RotorTelemetryPanel")
	_expect(rotor_panel != null and rotor_panel.is_visible_in_tree(), "Motor HUD renders the persistent telemetry-driven four-rotor panel")
	var gamepad_panel: Control = runtime.get_node_or_null("FlightHud/GamepadHudMargin/GamepadHudPanel/GamepadTelemetryPanel")
	_expect(gamepad_panel != null and gamepad_panel.is_visible_in_tree(), "Flight HUD renders the persistent Xbox Mode 2 panel")
	runtime.osd_profile = OsdProfile.profile_for_preset("Minimal")
	runtime.call("_refresh_flight_hud")
	_expect(motor_panel != null and motor_panel.is_visible_in_tree(), "Minimal OSD cannot hide the persistent Motor HUD")
	_motor_hud_evidence = {
		"visible": motor_panel != null and motor_panel.is_visible_in_tree(),
		"minimal_visible": motor_panel != null and motor_panel.is_visible_in_tree(),
		"rotor_panel": rotor_panel != null and rotor_panel.is_visible_in_tree(),
		"gamepad_panel": gamepad_panel != null and gamepad_panel.is_visible_in_tree(),
		"screenshot_path": "%s/03_takeoff.png" % _out_dir,
	}

	_tap(KEY_P)
	await _settle(10)
	await _snapshot("04_paused")
	_expect(runtime.paused, "P pauses flight")

	_tap(KEY_P)
	_tap(KEY_R)
	await _await_reset_commit(runtime, "flight", false, "terrain3d_range", "keyboard reset")
	await _snapshot("05_reset")
	_expect(runtime.reset_count >= 1, "R resets flight after resume")
	spawn = runtime.loaded_map.get_node_or_null("SpawnNorth") as Marker3D if runtime.loaded_map != null else null
	_expect(spawn != null and runtime.drone_body.global_position.distance_to(spawn.global_position) <= 1e-6 and runtime.drone_body.linear_velocity.length() <= 1e-6 and runtime.drone_body.angular_velocity.length() <= 1e-6, "reset returns to the default SpawnNorth with cleared velocities after a fresh map load")

	runtime.quit_on_exit = false
	_tap(KEY_P)
	await _settle(2)
	var pause_reset_button: Button = runtime.get_node_or_null("FlightHud/PausePanel/Rows/Reset")
	_expect(runtime.paused and pause_reset_button != null, "Pause Overlay exposes an actionable Reset button")
	var reset_count_before_button: int = runtime.reset_count
	if pause_reset_button != null:
		_click(pause_reset_button)
	await _await_reset_commit(runtime, "flight", false, "terrain3d_range", "Pause Overlay Reset")
	_expect(runtime.reset_count > reset_count_before_button and not runtime.paused, "Pause Overlay Reset resumes the flight with reset semantics")
	_tap(KEY_P)
	await _settle(2)
	var pause_exit_button: Button = runtime.get_node_or_null("FlightHud/PausePanel/Rows/Exit")
	_expect(runtime.paused and pause_exit_button != null, "Pause Overlay exposes an actionable Exit button")
	if pause_exit_button != null:
		_click(pause_exit_button)
	await _settle(2)
	await _snapshot("06_exit")
	_expect(runtime.exit_requested and runtime.screen == "main_menu" and runtime.loaded_map == null and runtime.get_node_or_null("LoadedMap") == null, "Pause Overlay Exit frees the map and returns to the main menu stub")
	await _audit_localization(runtime)
	if not _write_report():
		quit(1)
		return
	if not _failures.is_empty():
		for failure in _failures:
			print("HEADED FAILURE: %s" % failure)
		quit(1)
		return
	quit(0)

func _parse_args() -> void:
	var args := OS.get_cmdline_user_args()
	for index in range(args.size() - 1):
		if args[index] == "--out-dir":
			_out_dir = args[index + 1].trim_suffix("/")


func _install_deterministic_valid_license(runtime: Node) -> void:
	if runtime.license_provider != null:
		runtime.remove_child(runtime.license_provider)
		runtime.license_provider.queue_free()
	var provider := HeadedLicenseProvider.new()
	runtime.license_provider = provider
	runtime.add_child(provider)
	runtime.show_main_menu()


func _settle(frames: int) -> void:
	for _frame in frames:
		await process_frame


func _settle_physics(frames: int) -> void:
	for _frame in frames:
		await physics_frame


func _await_reset_commit(runtime: Node, expected_screen: String, expected_paused: bool, expected_map_id: String, context: String) -> bool:
	var token := int(runtime._reset_pending_token)
	for _frame in 180:
		var body: Variant = runtime.drone_body
		var body_ack: bool = token <= 0 or (body != null and body.has_method("reset_acknowledged") and bool(body.call("reset_acknowledged", token)))
		if int(runtime._reset_pending_token) == 0 and not bool(runtime._reset_publication_blocked) and body_ack and runtime.screen == expected_screen and bool(runtime.paused) == expected_paused and String(runtime.loaded_map_id) == expected_map_id:
			return true
		await process_frame
	var body: Variant = runtime.drone_body
	var diagnostics := {
		"context": context,
		"requested_token": token,
		"pending_token": int(runtime._reset_pending_token),
		"screen": String(runtime.screen),
		"paused": bool(runtime.paused),
		"map": String(runtime.loaded_map_id),
		"publication_blocked": bool(runtime._reset_publication_blocked),
		"body_acknowledged": token <= 0 or (body != null and body.has_method("reset_acknowledged") and bool(body.call("reset_acknowledged", token))),
		"body_position": body.global_position if body != null else null,
		"body_frozen": bool(body.freeze) if body != null else null,
		"body_sleeping": bool(body.sleeping) if body != null else null,
		"native_armed": runtime.native != null and bool(runtime.native.call("flight_control_armed")),
		"last_error": String(runtime.last_error_message),
	}
	_expect(false, "reset commit did not reach %s: %s" % [context, JSON.stringify(diagnostics)])
	return false

func _complete_time_trial(runtime: Node) -> void:
	if runtime.time_trial == null:
		return
	for checkpoint in runtime.time_trial.checkpoint_positions:
		runtime.time_trial.advance(checkpoint, 1.0 / 240.0)
	var finish_position: Vector3 = runtime.loaded_map.get_node("TimeTrial/Finish").global_position
	runtime.time_trial.advance(finish_position, 1.0 / 240.0)

func _snapshot(name: String) -> Image:
	await RenderingServer.frame_post_draw
	var image := root.get_texture().get_image()
	if image.save_png("%s/%s.png" % [_out_dir, name]) != OK:
		_failures.append("cannot save screenshot %s" % name)
	_expect(_max_color_ratio(image) < 0.99, "%s is not a monochrome frame" % name)
	return image

func _max_color_ratio(image: Image) -> float:
	image.convert(Image.FORMAT_RGBA8)
	var counts := {}
	var max_count := 0
	var data := image.get_data()
	for offset in range(0, data.size(), 4):
		var color := (int(data[offset]) << 16) | (int(data[offset + 1]) << 8) | int(data[offset + 2])
		counts[color] = int(counts.get(color, 0)) + 1
		max_count = maxi(max_count, counts[color])
	return float(max_count) / float(image.get_width() * image.get_height())

func _natural_ground_color_counts(image: Image) -> Dictionary:
	image.convert(Image.FORMAT_RGBA8)
	var grass := 0
	var soil_sand := 0
	var data := image.get_data()
	for offset in range(0, data.size(), 4):
		var red := int(data[offset])
		var green := int(data[offset + 1])
		var blue := int(data[offset + 2])
		if green >= red + 10 and green >= blue + 10 and green >= 40:
			grass += 1
		elif red >= green + 25 and green >= blue + 10 and red >= 70:
			soil_sand += 1
	return {"grass": grass, "soil_sand": soil_sand}

func _tap(keycode: Key) -> void:
	for pressed in [true, false]:
		var event := InputEventKey.new()
		event.keycode = keycode
		event.physical_keycode = keycode
		event.pressed = pressed
		Input.parse_input_event(event)

func _send_ui_action(action: String, device: int) -> void:
	for pressed in [true, false]:
		var event := InputEventAction.new()
		event.action = action
		event.device = device
		event.pressed = pressed
		event.strength = 1.0
		Input.parse_input_event(event)

func _navigate_graphics_with_ui_actions(runtime: Node, device: int) -> void:
	var reset_result: Dictionary = runtime.settings_store.factory_reset()
	_expect(reset_result.ok, "UI action flow resets SettingsStore")
	runtime.render_scale = 1.0
	runtime.graphics_committed_scale = 1.0
	runtime.get_viewport().scaling_3d_scale = 1.0
	runtime.show_main_menu()
	await _settle(1)
	var quick_fly := runtime.get_node_or_null("MainMenu/Entries/QuickFly") as Button
	_expect(runtime.get_viewport().gui_get_focus_owner() == quick_fly, "UI action flow starts on Quick Fly")
	for _step in range(5):
		_send_ui_action("ui_down", device)
		await _settle(1)
	_send_ui_action("ui_accept", device)
	await _settle(2)
	_expect(runtime.screen == "settings", "UI actions open Settings")
	var graphics_button := runtime.get_node_or_null("MainMenu/SettingsPanel/Rows/Graphics") as Button
	_expect(runtime.get_viewport().gui_get_focus_owner() == graphics_button, "Settings hands focus to Graphics")
	_send_ui_action("ui_accept", device)
	await _settle(2)
	_expect(runtime.screen == "graphics", "UI actions open Graphics")
	var slider := runtime.get_node_or_null("MainMenu/GraphicsPanel/Rows/RenderScale") as HSlider
	_expect(runtime.get_viewport().gui_get_focus_owner() == slider, "Graphics UI actions focus RenderScale")
	for _step in range(10):
		_send_ui_action("ui_right", device)
		await _settle(1)
	for _step in range(5):
		_send_ui_action("ui_left", device)
		await _settle(1)
	_expect(absf(runtime.get_viewport().scaling_3d_scale - 0.75) <= 0.000001, "UI actions change Graphics scale")
	_expect((runtime.get_node("MainMenu/GraphicsPanel/Rows/RenderScaleValue") as Label).text == "RENDER SCALE: 75%", "Graphics shows integer percent")
	_send_ui_action("ui_down", device)
	await _settle(1)
	_send_ui_action("ui_accept", device)
	await _settle(2)
	_expect_persisted_render_scale(runtime, 0.75, "UI actions Apply Graphics")
	for _step in range(2):
		_send_ui_action("ui_down", device)
		await _settle(1)
	_send_ui_action("ui_accept", device)
	await _settle(2)
	_expect(runtime.screen == "settings", "UI actions return from Graphics")
	_expect(runtime.get_viewport().gui_get_focus_owner() == graphics_button, "UI actions return Settings focus")
	for _step in range(2):
		_send_ui_action("ui_down", device)
		await _settle(1)
	_send_ui_action("ui_accept", device)
	await _settle(2)
	_expect(runtime.screen == "main_menu", "UI actions return to main menu")

func _click(control: Control) -> void:
	var position := control.get_global_rect().get_center()
	for pressed in [true, false]:
		var event := InputEventMouseButton.new()
		event.position = position
		event.button_index = MOUSE_BUTTON_LEFT
		event.pressed = pressed
		Input.parse_input_event(event)

func _audit_localization(runtime: Node) -> void:
	var switch_started_us := Time.get_ticks_usec()
	var switched_to_zh_tw: bool = runtime.set_locale("zh_TW")
	var switch_elapsed_us := Time.get_ticks_usec() - switch_started_us
	_locale_switch_evidence.append({"from": "en", "to": "zh_TW", "elapsed_us": switch_elapsed_us, "threshold_us": 100_000})
	_expect(switched_to_zh_tw, "UI locale switches to Traditional Chinese")
	if not switched_to_zh_tw:
		var language_load: Dictionary = runtime.settings_store.load_document()
		_failures.append("locale switch diagnostic: %s runtime=%s" % [language_load.get("error", "unknown"), runtime.last_error_message])
	await _settle(2)
	runtime.show_main_menu()
	await _settle(1)
	var quick_fly: Button = runtime.get_node_or_null("MainMenu/Entries/QuickFly")
	_expect(quick_fly != null and quick_fly.text == "快速飛行", "Traditional Chinese localizes the main menu immediately")
	_audit_visible_controls(runtime, "main_menu_zh_tw")
	runtime.show_settings()
	await _settle(1)
	var settings_title: Label = runtime.get_node_or_null("MainMenu/SettingsPanel/Rows/Title")
	var language_selector: OptionButton = runtime.get_node_or_null("MainMenu/SettingsPanel/Rows/Language")
	_expect(settings_title != null and settings_title.text == "設定", "Traditional Chinese localizes Settings immediately")
	_expect(language_selector != null and language_selector.get_item_text(1) == "繁體中文", "Language selector localizes its own options")
	var settings_status: Label = runtime.get_node_or_null("MainMenu/SettingsPanel/Rows/Status")
	_expect(settings_status != null and settings_status.text.contains("不支援"), "Traditional Chinese localizes the visible controller diagnostic")
	_expect(settings_status == null or not settings_status.text.contains("Unsupported controller"), "Traditional Chinese removes the visible English controller diagnostic")
	_audit_visible_controls(runtime, "settings_zh_tw")
	runtime.show_main_menu()
	await _settle(1)
	var drone_entry: Button = runtime.get_node_or_null("MainMenu/Entries/Drone")
	if drone_entry != null:
		_click(drone_entry)
	await _settle(1)
	var flight_mode_label: Label = runtime.get_node_or_null("MainMenu/FlightSetupPanel/Rows/Mode")
	_expect(flight_mode_label != null and flight_mode_label.text == "模式：角度", "Traditional Chinese localizes the dynamic Flight Setup mode")
	runtime.flight_mode = "UNSUPPORTED_RUNTIME_MODE"
	runtime.update_fallback_status()
	_expect(runtime.fallback_status_label != null and runtime.fallback_status_label.text.contains("未知模式"), "Traditional Chinese wraps unknown runtime modes in the catalog")
	_expect(runtime.fallback_status_label == null or not runtime.fallback_status_label.text.contains("UNSUPPORTED_RUNTIME_MODE"), "Traditional Chinese hides unknown runtime mode tokens")
	runtime.flight_mode = "ANGLE"
	runtime.update_fallback_status()
	_audit_visible_controls(runtime, "flight_setup_zh_tw")
	runtime.show_settings()
	await _settle(1)
	runtime.show_controller_settings()
	await _settle(1)
	_audit_visible_controls(runtime, "controller_settings_zh_tw")
	runtime.show_rates()
	await _settle(1)
	_audit_visible_controls(runtime, "rates_zh_tw")
	runtime.show_graphics()
	await _settle(1)
	_audit_visible_controls(runtime, "graphics_zh_tw")
	await _audit_transient_localization(runtime, "zh_tw")
	runtime.show_settings()
	await _settle(1)
	_expect(runtime.load_map("industrial_yard"), "Traditional Chinese can load the Industrial Yard")
	await _settle(2)
	var north_spawn_label: Label3D = runtime.loaded_map.get_node_or_null("SpawnNorth/DirectionLabel") if runtime.loaded_map != null else null
	_expect(north_spawn_label != null and north_spawn_label.text == "北側起飛點", "Industrial Yard Label3D localizes with the active locale")
	runtime.unload_map()
	var zh_tw_image := await _snapshot("08_zh_tw_settings")
	var switch_back_started_us := Time.get_ticks_usec()
	var switched_to_en: bool = runtime.set_locale("en")
	var switch_back_elapsed_us := Time.get_ticks_usec() - switch_back_started_us
	_locale_switch_evidence.append({"from": "zh_TW", "to": "en", "elapsed_us": switch_back_elapsed_us, "threshold_us": 100_000})
	_expect(switched_to_en, "UI locale switches back to English")
	await _settle(2)
	_expect(settings_title != null and settings_title.text == "SETTINGS", "English locale restores Settings immediately")
	runtime.show_main_menu()
	await _settle(1)
	_audit_visible_controls(runtime, "main_menu_en")
	var english_drone_entry: Button = runtime.get_node_or_null("MainMenu/Entries/Drone")
	if english_drone_entry != null:
		_click(english_drone_entry)
	await _settle(1)
	var english_flight_mode_label: Label = runtime.get_node_or_null("MainMenu/FlightSetupPanel/Rows/Mode")
	_expect(english_flight_mode_label != null and english_flight_mode_label.text == "MODE: ANGLE", "English localizes the dynamic Flight Setup mode")
	_audit_visible_controls(runtime, "flight_setup_en")
	runtime.show_settings()
	await _settle(1)
	_audit_visible_controls(runtime, "settings_en")
	runtime.show_controller_settings()
	await _settle(1)
	_audit_visible_controls(runtime, "controller_settings_en")
	runtime.show_rates()
	await _settle(1)
	_audit_visible_controls(runtime, "rates_en")
	runtime.show_graphics()
	await _settle(1)
	_audit_visible_controls(runtime, "graphics_en")
	await _audit_transient_localization(runtime, "en")
	runtime.show_settings()
	await _settle(1)
	var en_image := await _snapshot("09_en_settings_roundtrip")
	_compare_locale_screenshots(zh_tw_image, en_image)

func _audit_transient_localization(runtime: Node, locale_suffix: String) -> void:
	runtime.screen = "flight"
	runtime.set_paused(true, false)
	runtime.call("_refresh_flight_hud")
	await _settle(1)
	_audit_visible_controls(runtime, "pause_%s" % locale_suffix)
	await _audit_osd_presets(runtime, locale_suffix)

	runtime.call("_on_trial_finished", 12.34)
	await _settle(1)
	_audit_visible_controls(runtime, "finish_%s" % locale_suffix)

	runtime.call("_show_license_blocked", "Quick Fly unavailable: license invalid_token")
	await _settle(1)
	_audit_visible_controls(runtime, "license_%s" % locale_suffix)

	runtime.call("_show_keyboard_fallback", "Unsupported controller; Xbox default profile is unavailable. KeyboardProfile fallback active (non-sim control)")
	await _settle(1)
	_audit_visible_controls(runtime, "fallback_%s" % locale_suffix)

	var connected_devices: Array[int] = [0]
	runtime.gamepad_device_state.call("replace_snapshot", connected_devices, connected_devices)
	runtime.controller_safety_latched = true
	runtime.call("begin_controller_confirmation", 0)
	await _settle(1)
	_expect(runtime.screen == "controller_confirmation", "controller confirmation transient state opens")
	_expect(runtime.controller_safety_panel != null and not runtime.controller_safety_panel.is_visible_in_tree(), "controller safety banner yields to confirmation modal")
	_audit_visible_controls(runtime, "controller_confirmation_%s" % locale_suffix)

	runtime.controller_safety_latched = false
	runtime.last_error_message = "Flight Setup contains an unsupported selection"
	runtime.screen = "error"
	runtime.call("_refresh_flight_hud")
	await _settle(1)
	_audit_visible_controls(runtime, "error_%s" % locale_suffix)

	runtime.set_paused(false, false)
	runtime.last_error_message = ""
	var no_devices: Array[int] = []
	runtime.gamepad_device_state.call("replace_snapshot", no_devices, no_devices)
	runtime.session_gamepad_device_id = -1
	runtime.show_settings()
	await _settle(1)

func _audit_osd_presets(runtime: Node, locale_suffix: String) -> void:
	var original_size := root.size
	for requested_size in [Vector2i(1152, 648), Vector2i(1280, 720), Vector2i(1280, 800), Vector2i(1920, 1080)]:
		root.size = requested_size
		await _settle(2)
		var viewport_size := root.get_viewport().get_visible_rect().size
		var center_third := Rect2(viewport_size.x / 3.0, 0.0, viewport_size.x / 3.0, viewport_size.y)
		_expect(Vector2i(viewport_size) == requested_size, "OSD %s audit uses %s viewport" % [locale_suffix, requested_size])
		for preset in OsdProfile.PRESETS:
			runtime.osd_profile = OsdProfile.profile_for_preset(preset)
			runtime.call("_refresh_flight_hud")
			var visible_area := 0.0
			for element in OsdProfile.ELEMENTS:
				var label := runtime.osd_labels[element] as Label
				if label == null or not label.visible:
					continue
				var rect := label.get_global_rect()
				visible_area += rect.get_area()
				_expect(root.get_viewport().get_visible_rect().encloses(rect), "OSD %s %s %s label stays inside the viewport: %s" % [locale_suffix, requested_size, preset, element])
				if element == "warnings":
					var outside_center_third := rect.end.x <= center_third.position.x or rect.position.x >= center_third.end.x
					_expect(outside_center_third, "OSD %s %s %s warnings stay out of the center third: %s" % [locale_suffix, requested_size, preset, rect])
			var obstruction_ratio := visible_area / (viewport_size.x * viewport_size.y)
			_expect(obstruction_ratio <= 0.08, "OSD %s %s %s obstruction %.4f stays at or below 8%%" % [locale_suffix, requested_size, preset, obstruction_ratio])
			_audit_overlay_geometry(runtime, "osd_%s_%s_%s" % [locale_suffix, preset.to_lower(), requested_size])
	root.size = original_size
	await _settle(2)

func _audit_visible_controls(node: Node, screen_name: String) -> void:
	var viewport_rect := root.get_viewport().get_visible_rect()
	var text_controls: Array[Control] = []
	_collect_visible_text_controls(node, text_controls)
	var overlap_count := 0
	var clipping_count := 0
	for control in text_controls:
		var rect := control.get_global_rect()
		_expect(viewport_rect.encloses(rect), "localized control remains inside viewport: %s" % control.get_path())
		_expect(not String(control.text).begins_with("ui."), "localized control does not expose a translation key: %s" % control.get_path())
		var minimum_size := control.get_combined_minimum_size()
		if minimum_size.x > rect.size.x + 1.0 or minimum_size.y > rect.size.y + 1.0:
			clipping_count += 1
			_expect(false, "localized control text exceeds its allocated rect: %s" % control.get_path())
	for first_index in range(text_controls.size()):
		var first := text_controls[first_index]
		for second_index in range(first_index + 1, text_controls.size()):
			var second := text_controls[second_index]
			if first.get_global_rect().intersection(second.get_global_rect()).get_area() > 0.5:
				overlap_count += 1
				_expect(false, "localized text controls overlap: %s and %s" % [first.get_path(), second.get_path()])
	var screens: Dictionary = _layout_audit_evidence.get("screens", {})
	screens[screen_name] = {"text_controls": text_controls.size(), "clipping_count": clipping_count, "overlap_count": overlap_count}
	_layout_audit_evidence["screens"] = screens

func _collect_visible_text_controls(node: Node, controls: Array[Control]) -> void:
	for child in node.get_children():
		if child is Control:
			var control := child as Control
			if control.is_visible_in_tree() and (control is Label or control is Button or control is OptionButton or control is LineEdit or control is TextEdit):
				controls.append(control)
		_collect_visible_text_controls(child, controls)

func _audit_overlay_geometry(runtime: Node, screen_name: String) -> void:
	var surfaces: Array[Dictionary] = []
	_add_overlay_surface(surfaces, "main_menu", runtime.get_node_or_null("MainMenu/Entries"))
	_add_overlay_surface(surfaces, "flight_hud", runtime.get_node_or_null("FlightHud/StatusMargin/StatusPanel"))
	_add_overlay_surface(surfaces, "gamepad_hud", runtime.get_node_or_null("FlightHud/GamepadHudMargin/GamepadHudPanel"))
	_add_overlay_surface(surfaces, "motor_hud", runtime.get_node_or_null("FlightHud/MotorHudMargin/MotorHudPanel"))
	var dashboard: CanvasLayer = runtime.status_diagram
	if dashboard != null:
		_add_overlay_surface(surfaces, "operations_dashboard", dashboard.get_node_or_null("DashboardMargin/DashboardPanel"))
	var body_drag: Node = runtime.body_drag_debug_panel
	if body_drag != null:
		var body_panel: Control = body_drag.get("_panel")
		if body_panel != null:
			var body_surface: Control = body_panel.get("_scroll") if body_panel.get("_scroll") != null else body_panel.get("container")
			_add_overlay_surface(surfaces, "body_drag", body_surface)
	for element in OsdProfile.ELEMENTS:
		_add_overlay_surface(surfaces, "osd_%s" % element, runtime.osd_labels.get(element))

	var viewport_rect := root.get_viewport().get_visible_rect()
	var geometry: Dictionary = {}
	for surface in surfaces:
		var control: Control = surface.control
		var rect := control.get_global_rect()
		_expect(viewport_rect.encloses(rect), "%s overlay remains inside viewport: %s" % [screen_name, surface.name])
		geometry[surface.name] = {
			"left": rect.position.x,
			"top": rect.position.y,
			"right": rect.end.x,
			"bottom": rect.end.y,
			"width": rect.size.x,
			"height": rect.size.y,
		}
	for first_index in range(surfaces.size()):
		var first: Control = surfaces[first_index].control
		for second_index in range(first_index + 1, surfaces.size()):
			var second: Control = surfaces[second_index].control
			var first_name := String(surfaces[first_index].name)
			var second_name := String(surfaces[second_index].name)
			var first_is_osd := first_name.begins_with("osd_")
			var second_is_osd := second_name.begins_with("osd_")
			var checks_requested_geometry := (
				first_is_osd == second_is_osd
				or (first_is_osd and second_name in ["operations_dashboard", "body_drag"])
				or (second_is_osd and first_name in ["operations_dashboard", "body_drag"])
				or first_name in ["osd_warnings", "osd_reset_hint"]
				or second_name in ["osd_warnings", "osd_reset_hint"]
			)
			if not checks_requested_geometry:
				continue
			var first_rect := first.get_global_rect()
			var second_rect := second.get_global_rect()
			_expect(first_rect.grow(8.0).intersection(second_rect).get_area() <= 0.5,
					"%s overlays keep 8 px spacing: %s and %s" % [screen_name, surfaces[first_index].name, surfaces[second_index].name])
	var overlays: Dictionary = _layout_audit_evidence.get("overlays", {})
	overlays[screen_name] = geometry
	_layout_audit_evidence["overlays"] = overlays


func _audit_cockpit_three_way_split(runtime: Node, screen_name: String) -> void:
	var left_rail := runtime.get_node_or_null("FlightHud/LeftRail") as Control
	var flight_view := runtime.get_node_or_null("FlightHud/FlightViewRegion") as Control
	var right_rail := runtime.get_node_or_null("FlightHud/RightRail") as Control
	_expect(left_rail != null and flight_view != null and right_rail != null, "%s exposes explicit left, flight-view, and right regions" % screen_name)
	if left_rail == null or flight_view == null or right_rail == null:
		return
	var viewport_rect := root.get_viewport().get_visible_rect()
	var left_rect := left_rail.get_global_rect()
	var flight_rect := flight_view.get_global_rect()
	var right_rect := right_rail.get_global_rect()
	_expect(viewport_rect.encloses(left_rect) and viewport_rect.encloses(flight_rect) and viewport_rect.encloses(right_rect), "%s three regions stay inside the viewport" % screen_name)
	_expect(left_rect.end.x <= flight_rect.position.x + 0.5 and flight_rect.end.x <= right_rect.position.x + 0.5, "%s three regions do not overlap" % screen_name)
	_expect(flight_rect.size.x >= viewport_rect.size.x / 3.0, "%s preserves at least the center third for unobstructed flight" % screen_name)
	var status_panel := runtime.get_node_or_null("FlightHud/StatusMargin/StatusPanel") as Control
	var gamepad_panel := runtime.get_node_or_null("FlightHud/GamepadHudMargin/GamepadHudPanel") as Control
	var motor_panel := runtime.get_node_or_null("FlightHud/MotorHudMargin/MotorHudPanel") as Control
	var dashboard_panel := runtime.status_diagram.get_node_or_null("DashboardMargin/DashboardPanel") as Control if runtime.status_diagram != null else null
	_expect(status_panel != null and left_rect.encloses(status_panel.get_global_rect()), "%s keeps status inside the left region" % screen_name)
	_expect(gamepad_panel != null and left_rect.encloses(gamepad_panel.get_global_rect()), "%s keeps the Xbox graphic inside the left region" % screen_name)
	_expect(motor_panel != null and right_rect.encloses(motor_panel.get_global_rect()), "%s keeps the four-rotor graphic inside the right region" % screen_name)
	_expect(dashboard_panel != null and right_rect.encloses(dashboard_panel.get_global_rect()), "%s keeps telemetry inside the right region" % screen_name)
	var body_drag_surface := runtime.body_drag_debug_panel.get("_panel") as Control if runtime.body_drag_debug_panel != null else null
	_expect(body_drag_surface == null or not body_drag_surface.is_visible_in_tree(), "%s hides the lab aerodynamic debug surface from the player cockpit" % screen_name)


func _add_overlay_surface(surfaces: Array[Dictionary], name: String, node: Node) -> void:
	if node is Control and node.is_visible_in_tree():
		surfaces.append({"name": name, "control": node})

func _compare_locale_screenshots(zh_tw_image: Image, en_image: Image) -> void:
	var same_dimensions := zh_tw_image.get_size() == en_image.get_size()
	_expect(same_dimensions, "locale screenshots keep the same viewport dimensions")
	if not same_dimensions:
		return
	var changed_pixels := 0
	var total_pixels := zh_tw_image.get_width() * zh_tw_image.get_height()
	for y in range(zh_tw_image.get_height()):
		for x in range(zh_tw_image.get_width()):
			var zh_color := zh_tw_image.get_pixel(x, y)
			var en_color := en_image.get_pixel(x, y)
			if absf(zh_color.r - en_color.r) + absf(zh_color.g - en_color.g) + absf(zh_color.b - en_color.b) > 0.03:
				changed_pixels += 1
	var changed_ratio := float(changed_pixels) / float(total_pixels)
	_expect(changed_ratio >= 0.001, "locale screenshot comparison detects the translated UI")
	_screenshot_comparison = {"width": zh_tw_image.get_width(), "height": zh_tw_image.get_height(), "changed_pixels": changed_pixels, "changed_ratio": changed_ratio}


func _inject_known_gamepad() -> int:
	_inject_joy_axis(0, JOY_AXIS_LEFT_X, 0.5)
	_inject_joy_axis(0, JOY_AXIS_LEFT_Y, -0.5)
	_inject_joy_axis(0, JOY_AXIS_RIGHT_X, 0.25)
	_inject_joy_axis(0, JOY_AXIS_RIGHT_Y, -0.75)
	await process_frame
	for device_id in Input.get_connected_joypads():
		if Input.is_joy_known(device_id):
			return device_id
	return -1

func _inject_joy_axis(device_id: int, axis: JoyAxis, value: float) -> void:
	var event := InputEventJoypadMotion.new()
	event.device = device_id
	event.axis = axis
	event.axis_value = value
	Input.parse_input_event(event)

func _inject_joy_button(device_id: int, button: JoyButton, pressed: bool) -> void:
	var event := InputEventJoypadButton.new()
	event.device = device_id
	event.button_index = button
	event.pressed = pressed
	Input.parse_input_event(event)

func _expect_persisted_render_scale(runtime: Node, expected_scale: float, message: String) -> void:
	var persisted: Dictionary = runtime.settings_store.load_document()
	var quality: Variant = persisted.document.get("quality") if persisted.ok else null
	var persisted_quality: Dictionary = quality if quality is Dictionary else {}
	_expect(persisted.ok and quality is Dictionary and absf(float(persisted_quality.get("render_scale", 0.0)) - expected_scale) <= 0.000001, message)

func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)

func _write_report() -> bool:
	var report := FileAccess.open("%s/report.json" % _out_dir, FileAccess.WRITE)
	if report == null:
		push_error("Cannot write headed acceptance report")
		return false
	var version_info := Engine.get_version_info()
	var provenance := {
		"commit_sha": OS.get_environment("AEROSIM_HEADED_COMMIT_SHA"),
		"godot_version": String(version_info.get("string", "")),
		"os": OS.get_name(),
		"display_driver": DisplayServer.get_name(),
		"gpu_adapter": RenderingServer.get_video_adapter_name(),
		"vulkan_icd": OS.get_environment("VK_ICD_FILENAMES"),
	}
	report.store_string(JSON.stringify({"provenance": provenance, "channel_monitor": _channel_monitor_evidence, "motor_hud": _motor_hud_evidence, "known_xbox_physical": _known_xbox_physical_evidence, "assisted_hover": _assisted_hover_evidence, "layout_audit": _layout_audit_evidence, "screenshot_comparison": _screenshot_comparison, "locale_switches": _locale_switch_evidence, "ui_animation_count": _ui_animation_count, "failures": _failures, "passed": _failures.is_empty()}))
	report.close()
	return true
