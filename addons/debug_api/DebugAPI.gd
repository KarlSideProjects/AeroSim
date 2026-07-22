# DebugAPI.gd — Central entry point for the Debug API.
#
# This script intentionally has NO `class_name` because Godot 4.4+ rejects
# an autoload that shares its name with a global script class. The script is
# accessed instead through:
#   • The "DebugAPI" autoload registered by the plugin (recommended)
#   • A `preload("res://addons/debug_api/DebugAPI.gd")` for non-autoload setups
#
# Four installation modes are supported (pick one):
#   1. PLUGIN (recommended) → enable "Debug API" in Project Settings → Plugins.
#                              The plugin registers the "DebugAPI" autoload
#                              automatically; just call DebugAPI.method().
#   2. MANUAL AUTOLOAD      → register res://addons/debug_api/DebugAPI.gd as
#                              an autoload named "DebugAPI". Same usage.
#   3. BOOTSTRAP NODE       → drop a DebugBootstrap node into your main scene
#                              (no autoload required). Use bootstrap.api.
#   4. PURE INSTANCE        → const DebugAPIScript = preload("res://addons/debug_api/DebugAPI.gd")
#                              var api := DebugAPIScript.new()
#                              add_child(api); api.enable_monitor("fps")
#
# Zero-code config: drop a DebugSettings resource at one of:
#   res://debug_settings.tres
#   res://addons/debug_api/debug_settings.tres
#   user://debug_settings.tres
# and DebugAPI._ready() will apply it automatically.
extends Node

const DebugPanel = preload("res://addons/debug_api/DebugPanel.gd")
const DebugSettings = preload("res://addons/debug_api/DebugSettings.gd")
const DebugMonitors = preload("res://addons/debug_api/DebugMonitors.gd")
const DebugThemes = preload("res://addons/debug_api/DebugThemes.gd")


# ============================================================================
# Constants & Signals
# ============================================================================

const AUTO_PANEL_NAME: String = "__auto__"

# Export formats — pick when calling export_debug_data() or set auto_export_format.
const EXPORT_TXT: int  = 0
const EXPORT_JSON: int = 1
const EXPORT_CSV: int  = 2

signal panel_registered(panel_name: String)
signal panel_unregistered(panel_name: String)
signal global_visibility_toggled(is_visible: bool)
signal monitor_enabled(monitor_id: String)
signal monitor_disabled(monitor_id: String)
signal data_exported(filepath: String, format: int)


# ============================================================================
# State
# ============================================================================

var global_visible: bool = true:
	set(value):
		global_visible = value
		for panel in _panels.values():
			panel.visible = value
		global_visibility_toggled.emit(value)

# Hotkeys handled at the API level (in addition to per-panel toggle_key).
var global_toggle_key: int = KEY_NONE
var global_toggle_action: String = ""
var export_hotkey: int = KEY_NONE
var export_action: String = ""
var export_path: String = "user://debug_export.txt"
var export_format: int = EXPORT_TXT

# Auto-export — when interval > 0, write the snapshot every N seconds.
var auto_export_path: String = ""
var auto_export_format: int = EXPORT_TXT
var auto_export_interval: float = 0.0

# When true, the API silently skips initialization in non-debug builds.
var only_in_debug_build: bool = false

# When true, _process is short-circuited: no widget updates, no FPS sampling, no
# auto-export. Panels stay rendered with their last value. Cheap on/off switch.
var paused: bool = false:
	set(value):
		if paused == value:
			return
		paused = value
		# Propagate to every panel so per-panel _process also stops.
		for p in _panels.values():
			if is_instance_valid(p):
				p.set_process(not value)

var _panels: Dictionary = {}                 # panel_name -> DebugPanel
var _enabled_monitors: Dictionary = {}       # monitor_id -> widget reference
var _auto_panel_parent: Node = null
var _auto_panel_config: Dictionary = {}
var _auto_export_accum: float = 0.0
var _settings_applied: bool = false           # flips on the first apply_settings call

var _default_config: Dictionary = {
	"font_size":        13,
	"font_color":       Color(0.764, 0.867, 1.0, 1.0),
	"shadow_color":     Color(0, 0, 0, 0.85),
	"shadow_offset":    Vector2(1, 1),
	"background_color": Color(0, 0, 0, 0.7),
	"border_color":     Color(0.5, 0.5, 0.5, 0.8),
	"section_color":    Color(1, 1, 0.5, 1),
	"title_color":      Color(1, 1, 1, 1),
	"value_color":      Color(1, 1, 1, 1),
	"spacing":          4,
	"panel_padding":    6,
	"layer":            100,
	"position":         Vector2(8, 8),
	"anchor":           DebugPanel.ANCHOR_TOP_LEFT,
	"edge_margin":      Vector2(8, 8),
	"toggle_key":       KEY_F1,
	"toggle_action":    "",
	"start_visible":    true,
	"update_interval":  0.0,
	"min_width":        250,
	"max_height":       0.0,
	"click_through":    true,
	"show_title":       false,
	"title_text":       "",
	"collapsible_sections": false,
	"corner_radius":    0,
	"border_width":     1,
	"font":             null,
}


# ============================================================================
# Lifecycle
# ============================================================================

# Common locations searched for a DebugSettings .tres on _ready().
# Drop a file at any of these paths and DebugAPI applies it automatically.
const SETTINGS_AUTO_PATHS: Array[String] = [
	"res://debug_settings.tres",
	"res://addons/debug_api/debug_settings.tres",
	"user://debug_settings.tres",
]


func _ready() -> void:
	name = "DebugAPI"
	process_mode = Node.PROCESS_MODE_ALWAYS
	_try_autoload_settings()


# Searches SETTINGS_AUTO_PATHS for a DebugSettings .tres and applies the first found.
# Skipped when settings were already applied explicitly (e.g. by DebugBootstrap).
# Returns true if any were applied. Safe to call manually too.
func _try_autoload_settings() -> bool:
	if _settings_applied:
		return false
	for path in SETTINGS_AUTO_PATHS:
		if not ResourceLoader.exists(path):
			continue
		var res: Resource = load(path)
		if res is DebugSettings:
			apply_settings(res)
			return true
	return false


# Public counterpart for users who want to trigger the search manually
# (e.g. after dropping a settings .tres at runtime).
func reload_auto_settings() -> bool:
	return _try_autoload_settings()


# Always-on FPS sampler for avg/min/max monitors + auto-export tick.
# Skips when paused, in non-debug builds with only_in_debug_build, or when no monitors are active.
func _process(delta: float) -> void:
	if paused:
		return
	DebugMonitors.tick()
	if auto_export_interval > 0.0 and auto_export_path != "":
		_auto_export_accum += delta
		if _auto_export_accum >= auto_export_interval:
			_auto_export_accum = 0.0
			export_debug_data(auto_export_path, auto_export_format)


# Listen for the global toggle / export hotkeys.
func _input(event: InputEvent) -> void:
	if global_toggle_action != "" and event.is_action_pressed(global_toggle_action):
		toggle_global_visibility()
		return
	if export_action != "" and event.is_action_pressed(export_action):
		export_debug_data(export_path, export_format)
		return
	if event is InputEventKey and event.pressed and not event.echo:
		if global_toggle_key != KEY_NONE and event.keycode == global_toggle_key:
			toggle_global_visibility()
		elif export_hotkey != KEY_NONE and event.keycode == export_hotkey:
			export_debug_data(export_path, export_format)


# ============================================================================
# Static singleton accessor — finds the shared instance whether installed as
# an autoload, a DebugBootstrap-managed node, or a manually parented instance.
# ============================================================================

# Returns the shared DebugAPI as Node (its true type is DebugAPI's script):
#   • Autoload mode: returns the autoload registered by plugin.gd.
#   • Bootstrap mode: returns the node that DebugBootstrap parented to root.
#   • Returns null if no DebugAPI is in the scene tree yet.
#
# It does NOT auto-create an instance — DebugBootstrap does that when needed.
# This keeps instance() free of hardcoded paths and safe to call from anywhere.
static func instance() -> Node:
	var st := Engine.get_main_loop() as SceneTree
	if st == null or st.root == null:
		return null

	# Plugin / autoload fast-path: a node named "DebugAPI" under root.
	var existing: Node = st.root.get_node_or_null("DebugAPI")
	if existing != null:
		return existing

	# Cover oddly named autoloads or manual setups by walking root's children.
	for child in st.root.get_children():
		if child.name == "DebugAPI":
			return child
	return null


# ============================================================================
# Panels (custom panels API — kept fully backwards-compatible)
# ============================================================================

func create_panel(panel_name: String, parent_node: Node,
		config: Dictionary = {}) -> DebugPanel:
	if _panels.has(panel_name):
		push_warning("DebugAPI: panel '%s' already exists." % panel_name)
		return _panels[panel_name]
	if parent_node == null:
		push_error("DebugAPI: parent_node is null when creating panel '%s'." % panel_name)
		return null

	var panel: DebugPanel = DebugPanel.new()
	panel.setup(panel_name, _default_config.duplicate(), config)

	var canvas_layer: CanvasLayer = CanvasLayer.new()
	canvas_layer.layer = int(panel.get_config("layer", 100))
	canvas_layer.name = "%sDebugCanvas" % panel_name
	canvas_layer.add_child(panel)
	parent_node.add_child(canvas_layer)

	_panels[panel_name] = panel
	if paused:
		panel.set_process(false)
	panel_registered.emit(panel_name)
	return panel


func get_panel(panel_name: String) -> DebugPanel:
	return _panels.get(panel_name)


func has_panel(panel_name: String) -> bool:
	return _panels.has(panel_name)


func remove_panel(panel_name: String) -> void:
	if not _panels.has(panel_name):
		return
	var panel: DebugPanel = _panels[panel_name]
	if panel.get_parent():
		panel.get_parent().queue_free()
	_panels.erase(panel_name)
	if panel_name == AUTO_PANEL_NAME:
		_enabled_monitors.clear()
	panel_unregistered.emit(panel_name)


func list_panels() -> Array:
	return _panels.keys()


func update_all() -> void:
	for panel in _panels.values():
		if panel.auto_update and panel.visible:
			panel.update_display()


func toggle_global_visibility() -> void:
	global_visible = not global_visible


# Export every panel's current state to a file.
# format: EXPORT_TXT (default), EXPORT_JSON, or EXPORT_CSV. Pass -1 to auto-detect by extension.
func export_debug_data(filepath: String = "user://debug_export.txt", format: int = -1) -> bool:
	if format < 0:
		match filepath.get_extension().to_lower():
			"json": format = EXPORT_JSON
			"csv":  format = EXPORT_CSV
			_:      format = EXPORT_TXT

	var ok: bool
	match format:
		EXPORT_JSON: ok = _export_json(filepath)
		EXPORT_CSV:  ok = _export_csv(filepath)
		_:           ok = _export_txt(filepath)

	if ok:
		data_exported.emit(filepath, format)
		print("DebugAPI: exported to %s" % filepath)
	return ok


func _export_txt(filepath: String) -> bool:
	var file: FileAccess = FileAccess.open(filepath, FileAccess.WRITE)
	if not file:
		push_error("DebugAPI: cannot open file for export: %s" % filepath)
		return false

	file.store_string("=== DEBUG EXPORT ===\n")
	file.store_string("Timestamp: %s\n\n" % Time.get_datetime_string_from_system())

	for panel_name in _panels:
		var panel: DebugPanel = _panels[panel_name]
		file.store_string("--- Panel: %s ---\n" % panel_name)
		file.store_string(panel.get_text_export())
		file.store_string("\n\n")
	file.close()
	return true


func _export_json(filepath: String) -> bool:
	var file: FileAccess = FileAccess.open(filepath, FileAccess.WRITE)
	if not file:
		push_error("DebugAPI: cannot open file for export: %s" % filepath)
		return false

	var payload: Dictionary = {
		"timestamp": Time.get_datetime_string_from_system(),
		"panels":    [],
	}
	for panel_name in _panels:
		var panel: DebugPanel = _panels[panel_name]
		payload.panels.append(panel.get_data_snapshot())

	file.store_string(JSON.stringify(payload, "\t"))
	file.close()
	return true


func _export_csv(filepath: String) -> bool:
	var file: FileAccess = FileAccess.open(filepath, FileAccess.WRITE)
	if not file:
		push_error("DebugAPI: cannot open file for export: %s" % filepath)
		return false

	file.store_string("panel,section,label,value\n")
	for panel_name in _panels:
		var panel: DebugPanel = _panels[panel_name]
		var snap: Dictionary = panel.get_data_snapshot()
		for section in snap.sections.keys():
			var entries: Dictionary = snap.sections[section]
			for label in entries.keys():
				file.store_string("%s,%s,%s,%s\n" % [
					_csv_escape(panel_name),
					_csv_escape(section),
					_csv_escape(label),
					_csv_escape(str(entries[label])),
				])
	file.close()
	return true


static func _csv_escape(value: String) -> String:
	if value.contains(",") or value.contains("\"") or value.contains("\n"):
		return "\"%s\"" % value.replace("\"", "\"\"")
	return value


# ============================================================================
# Auto-monitor API — built-in metrics that just work
# ============================================================================

# Enable a single monitor by id (e.g. "fps", "memory_static", "window_size").
func enable_monitor(id: String) -> bool:
	if not DebugMonitors.has_monitor(id):
		push_warning("DebugAPI: monitor '%s' not found." % id)
		return false
	if _enabled_monitors.has(id):
		return true

	var panel: DebugPanel = _ensure_auto_panel()
	if panel == null:
		return false

	var monitor: Dictionary = DebugMonitors.get_monitor(id)
	var widget: Object = panel.add_monitor(monitor)
	if widget == null:
		return false

	_enabled_monitors[id] = widget
	monitor_enabled.emit(id)
	return true


# Enable several monitors at once. Ids are reordered by category for stable section layout.
func enable_monitors(ids: Array) -> void:
	for id in DebugMonitors.sort_ids_by_category(ids):
		enable_monitor(id)


# Enable every monitor of a category (e.g. "performance", "memory", "display").
func enable_monitor_category(category: String) -> void:
	enable_monitors(DebugMonitors.get_monitors_by_category(category))


# Enable monitors from a named preset (e.g. "essential", "performance", "full").
func enable_monitor_preset(preset_name: String) -> void:
	var ids: Array = DebugMonitors.resolve_preset(preset_name)
	if ids.is_empty():
		push_warning("DebugAPI: unknown preset '%s'." % preset_name)
		return
	enable_monitors(ids)


# Enable every available monitor.
func enable_all_monitors() -> void:
	enable_monitors(DebugMonitors.get_all_ids())


func disable_monitor(id: String) -> void:
	if not _enabled_monitors.has(id):
		return
	var panel: DebugPanel = get_panel(AUTO_PANEL_NAME)
	if panel:
		panel.remove_widget(_enabled_monitors[id])
	_enabled_monitors.erase(id)
	monitor_disabled.emit(id)


func disable_monitors(ids: Array) -> void:
	for id in ids:
		disable_monitor(id)


func disable_monitor_category(category: String) -> void:
	var to_remove: Array = []
	var cat_ids: Array = DebugMonitors.get_monitors_by_category(category)
	for id in _enabled_monitors.keys():
		if cat_ids.has(id):
			to_remove.append(id)
	disable_monitors(to_remove)


func disable_all_monitors() -> void:
	var ids: Array = _enabled_monitors.keys()
	var panel: DebugPanel = get_panel(AUTO_PANEL_NAME)
	if panel:
		panel.clear()
	_enabled_monitors.clear()
	for id in ids:
		monitor_disabled.emit(id)


func is_monitor_enabled(id: String) -> bool:
	return _enabled_monitors.has(id)


func list_enabled_monitors() -> Array:
	return _enabled_monitors.keys()


func list_available_monitors() -> Array:
	return DebugMonitors.get_all_ids()


func list_categories() -> Array:
	return DebugMonitors.get_categories()


func list_presets() -> Array:
	return DebugMonitors.get_preset_names()


func get_monitor_info(id: String) -> Dictionary:
	return DebugMonitors.get_monitor(id)


# Register a custom monitor at runtime (must include 'id', 'getter';
# optionally 'label', 'category', 'widget_type', 'format', etc.).
func register_custom_monitor(monitor: Dictionary) -> bool:
	return DebugMonitors.register_custom_monitor(monitor)


# ============================================================================
# Settings — apply / save / load a DebugSettings resource in one shot
# ============================================================================

# Apply a DebugSettings resource: configures the auto-panel and enables
# every monitor implied by the preset, categories and explicit ids in the resource.
# Re-applies cleanly — calling this again with different settings rebuilds the panel.
# When settings.only_in_debug_build is true and the build is non-debug, this is a no-op.
func apply_settings(settings: DebugSettings) -> void:
	if settings == null:
		push_warning("DebugAPI.apply_settings: settings is null.")
		return

	if settings.only_in_debug_build and not OS.is_debug_build():
		# Silently skip — production users won't see anything.
		_settings_applied = true
		return

	_settings_applied = true

	# Tear down any previous auto-panel so new appearance settings take effect.
	if has_panel(AUTO_PANEL_NAME):
		disable_all_monitors()
		remove_panel(AUTO_PANEL_NAME)

	# Build the merged panel config (theme overlaid with custom values).
	var config: Dictionary = settings.to_panel_config()
	if settings.theme_preset > 0:
		var theme_dict: Dictionary = DebugThemes.get_theme_by_index(settings.theme_preset)
		# Theme provides defaults; settings can override individual keys ON TOP of theme.
		# In practice, when theme_preset != 0, DebugSettings.to_panel_config() omits the
		# overridable color keys so the theme wins — see DebugSettings.gd.
		for k in theme_dict.keys():
			if not config.has(k):
				config[k] = theme_dict[k]

	configure_auto_panel(config)

	# Hotkeys / export configuration from settings (only when set on the resource).
	if settings.export_hotkey != KEY_NONE:
		export_hotkey = settings.export_hotkey
	if settings.export_action != "":
		export_action = settings.export_action
	if settings.export_path != "":
		export_path = settings.export_path
	export_format = settings.export_format
	if settings.global_toggle_key != KEY_NONE:
		global_toggle_key = settings.global_toggle_key
	if settings.global_toggle_action != "":
		global_toggle_action = settings.global_toggle_action

	# Auto-export configuration
	auto_export_path     = settings.auto_export_path
	auto_export_interval = settings.auto_export_interval
	auto_export_format   = settings.auto_export_format
	_auto_export_accum   = 0.0

	only_in_debug_build = settings.only_in_debug_build

	var ids: Array = settings.collect_monitor_ids()
	if not ids.is_empty():
		enable_monitors(ids)


# Apply a built-in theme by name ("default", "dark", "light", "neon", "retro", "minimal", "solarized").
# Tears down and recreates the auto-panel so the colors are applied immediately.
func apply_theme(theme_name: String) -> void:
	var theme_dict: Dictionary = DebugThemes.get_theme(theme_name)
	if theme_dict.is_empty():
		push_warning("DebugAPI.apply_theme: unknown theme '%s'." % theme_name)
		return

	# Remember currently enabled monitors so we can restore them.
	var ids: Array = list_enabled_monitors()

	if has_panel(AUTO_PANEL_NAME):
		disable_all_monitors()
		remove_panel(AUTO_PANEL_NAME)

	# Merge theme into the existing auto-panel config (theme overrides colors).
	var config: Dictionary = _auto_panel_config.duplicate()
	for k in theme_dict.keys():
		config[k] = theme_dict[k]
	configure_auto_panel(config)

	if not ids.is_empty():
		enable_monitors(ids)


# Save a DebugSettings resource to disk (.tres / .res).
static func save_settings(settings: DebugSettings, path: String) -> int:
	if settings == null:
		push_error("DebugAPI.save_settings: settings is null.")
		return ERR_INVALID_PARAMETER
	return ResourceSaver.save(settings, path)


# Load a DebugSettings resource from disk; returns null if missing or wrong type.
static func load_settings(path: String) -> DebugSettings:
	if not ResourceLoader.exists(path):
		return null
	var res: Resource = ResourceLoader.load(path)
	if res is DebugSettings:
		return res
	return null


# Build a DebugSettings reflecting the current API state — useful for "save my customization".
func snapshot_settings() -> DebugSettings:
	var s: DebugSettings = DebugSettings.new()
	s.monitor_ids = list_enabled_monitors()
	var cfg: Dictionary = _auto_panel_config

	if cfg.has("toggle_key"):       s.toggle_key       = int(cfg.toggle_key)
	if cfg.has("toggle_action"):    s.toggle_action    = String(cfg.toggle_action)
	if cfg.has("update_interval"):  s.update_interval  = float(cfg.update_interval)
	if cfg.has("min_width"):        s.min_width        = int(cfg.min_width)
	if cfg.has("max_height"):       s.max_height       = float(cfg.max_height)
	if cfg.has("anchor"):           s.anchor           = int(cfg.anchor)
	if cfg.has("edge_margin"):      s.edge_margin      = cfg.edge_margin
	if cfg.has("position"):         s.free_position    = cfg.position
	if cfg.has("layer"):            s.canvas_layer     = int(cfg.layer)
	if cfg.has("spacing"):          s.spacing          = int(cfg.spacing)
	if cfg.has("panel_padding"):    s.panel_padding    = int(cfg.panel_padding)
	if cfg.has("border_width"):     s.border_width     = int(cfg.border_width)
	if cfg.has("corner_radius"):    s.corner_radius    = int(cfg.corner_radius)
	if cfg.has("font_size"):        s.font_size        = int(cfg.font_size)
	if cfg.has("background_color"): s.background_color = cfg.background_color
	if cfg.has("border_color"):     s.border_color     = cfg.border_color
	if cfg.has("font_color"):       s.font_color       = cfg.font_color
	if cfg.has("section_color"):    s.section_color    = cfg.section_color
	if cfg.has("title_color"):      s.title_color      = cfg.title_color
	if cfg.has("value_color"):      s.value_color      = cfg.value_color
	if cfg.has("shadow_color"):     s.shadow_color     = cfg.shadow_color
	if cfg.has("shadow_offset"):    s.shadow_offset    = cfg.shadow_offset
	if cfg.has("show_title"):       s.show_title       = bool(cfg.show_title)
	if cfg.has("title_text"):       s.title_text       = String(cfg.title_text)
	if cfg.has("collapsible_sections"): s.collapsible_sections = bool(cfg.collapsible_sections)
	if cfg.has("click_through"):    s.click_through    = bool(cfg.click_through)
	if cfg.has("font"):             s.custom_font      = cfg.font

	s.global_toggle_key    = global_toggle_key
	s.global_toggle_action = global_toggle_action
	s.export_hotkey        = export_hotkey
	s.export_action        = export_action
	s.export_path          = export_path
	s.export_format        = export_format
	s.auto_export_path     = auto_export_path
	s.auto_export_interval = auto_export_interval
	s.auto_export_format   = auto_export_format
	s.only_in_debug_build  = only_in_debug_build
	s.theme_preset         = 0  # snapshots are always "Custom"
	s.anchor               = int(cfg.get("anchor", DebugPanel.ANCHOR_TOP_LEFT))

	return s


# ============================================================================
# Auto-panel configuration
# ============================================================================

# Configure the appearance of the auto-monitor panel.
# Apply BEFORE enabling monitors, or call disable_all_monitors() and re-enable
# after configuring to rebuild the panel with the new settings.
func configure_auto_panel(config: Dictionary) -> void:
	_auto_panel_config = config.duplicate()


func set_auto_panel_parent(parent: Node) -> void:
	_auto_panel_parent = parent


func get_auto_panel() -> DebugPanel:
	return get_panel(AUTO_PANEL_NAME)


func _ensure_auto_panel() -> DebugPanel:
	var panel: DebugPanel = get_panel(AUTO_PANEL_NAME)
	if panel:
		return panel

	if not is_inside_tree():
		attach_to_main_loop()

	var parent: Node = _auto_panel_parent if _auto_panel_parent else self
	if parent == null or not parent.is_inside_tree():
		var st := Engine.get_main_loop() as SceneTree
		if st and st.root:
			parent = st.root
		else:
			push_error("DebugAPI: cannot create auto-panel — no scene tree available.")
			return null

	return create_panel(AUTO_PANEL_NAME, parent, _auto_panel_config)


# Attach this DebugAPI instance to the SceneTree root so its _process runs
# and the FPS sampler stays alive. Useful when used as an instance instead of an autoload.
func attach_to_main_loop() -> void:
	if is_inside_tree():
		return
	var st := Engine.get_main_loop() as SceneTree
	if st == null or st.root == null:
		return
	if st.root.is_inside_tree():
		st.root.add_child(self)
	else:
		st.root.add_child.call_deferred(self)


# ============================================================================
# Performance & introspection
# ============================================================================

# Returns a dict with live counts useful for instrumentation:
#   panels, total_widgets, enabled_monitors, fps_history_size, paused.
# Cheap — only iterates panels.
func get_perf_stats() -> Dictionary:
	var total_widgets: int = 0
	for panel in _panels.values():
		if is_instance_valid(panel):
			total_widgets += panel.widget_count()
	return {
		"panels":            _panels.size(),
		"enabled_monitors":  _enabled_monitors.size(),
		"total_widgets":     total_widgets,
		"fps_history_size":  DebugMonitors._fps_history.size(),
		"paused":            paused,
		"only_in_debug":     only_in_debug_build,
	}


# Override the refresh interval of an enabled monitor at runtime.
# 0 = update every panel tick. >0 = throttle to N seconds.
func set_monitor_update_interval(monitor_id: String, interval: float) -> bool:
	var widget = _enabled_monitors.get(monitor_id)
	if widget == null:
		return false
	widget.update_interval = max(0.0, interval)
	return true


# Walk every panel and drop widgets whose UI nodes are gone. Returns how many were pruned.
# Worth calling occasionally if you free nodes that hold widget references.
func prune_stale_widgets() -> int:
	var total: int = 0
	for panel in _panels.values():
		if is_instance_valid(panel):
			total += panel.prune_stale()
	return total


# ============================================================================
# Threading note
# ============================================================================
#
# DebugAPI is NOT thread-safe. All public methods (enable_monitor, create_panel,
# apply_settings, etc.) must be called from the main (scene-tree) thread.
# Worker threads can update game state freely; the main thread reads it via the
# monitor getters. If you absolutely need to push values from another thread,
# marshal them through call_deferred() onto the main thread first.
