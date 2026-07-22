# DebugMonitors.gd
# Built-in monitor registry for the Debug API.
# Each monitor wraps a metric (FPS, memory, screen resolution, GPU, physics, etc.)
# that can be enabled individually, by category or via named presets through DebugAPI.
#
# A monitor is just a Dictionary with the following keys:
#   id           - Unique string identifier (used by DebugAPI.enable_monitor)
#   label        - Human readable label
#   category     - One of CATEGORIES keys
#   widget_type  - "text" | "colored" | "graph" | "progress" | "conditional" | "vector"
#   format       - printf-style format string applied by the widget
#   getter       - Callable returning the raw value
#   color_ranges - (optional) for "colored" widgets: [{condition, color}, ...]
#   condition    - (optional) for "conditional" widgets: Callable(value) -> bool
#   true_text    - (optional) for "conditional" widgets
#   false_text   - (optional) for "conditional" widgets
#   history_size - (optional) for "graph" widgets
#   min / max    - (optional) for "progress" widgets
#
# The registry is built lazily on first access and cached.

class_name DebugMonitors
extends RefCounted

# ============================================================================
# Categories — id → human readable section title
# ============================================================================

const CATEGORIES: Dictionary = {
	"performance": "Performance",
	"memory":      "Memory",
	"objects":     "Objects",
	"rendering":   "Rendering",
	"physics":     "Physics",
	"audio":       "Audio",
	"display":     "Display",
	"system":      "System",
	"time":        "Time",
	"input":       "Input",
	"scene":       "Scene",
	"network":     "Network",
}

# Stable ordering of categories when several are enabled at once (e.g. by preset).
const CATEGORY_ORDER: Array = [
	"performance", "memory", "objects", "rendering",
	"physics", "audio", "display", "system",
	"time", "input", "scene", "network",
]


# ============================================================================
# Built-in presets — group of monitors enabled together
# ============================================================================

const PRESETS: Dictionary = {
	"minimal":     ["fps"],
	"essential":   ["fps", "frame_time", "memory_static", "node_count", "window_size"],
	"performance": ["fps", "fps_avg", "fps_min", "fps_max", "frame_time",
					"process_time", "physics_process_time"],
	"memory":      ["memory_static", "memory_static_max", "video_memory",
					"texture_memory", "buffer_memory", "orphan_nodes"],
	"rendering":   ["total_objects", "total_primitives", "total_draw_calls",
					"gpu_name", "rendering_method"],
	"system":      ["os_name", "cpu_model", "cpu_cores", "gpu_name", "engine_version"],
	"display":     ["window_size", "screen_size", "screen_dpi", "fullscreen",
					"vsync_mode", "screen_refresh_rate"],
	"full":        ["*"],
}


# ============================================================================
# Sliding FPS history — fed by tick() and consumed by avg/min/max FPS monitors
# ============================================================================

const FPS_HISTORY_SIZE: int = 60

static var _fps_history: PackedFloat32Array = PackedFloat32Array()


# Lazy-built registry: id -> monitor metadata
static var _registry: Dictionary = {}


# ============================================================================
# Public API
# ============================================================================

static func get_registry() -> Dictionary:
	if _registry.is_empty():
		_build_registry()
	return _registry


static func get_monitor(id: String) -> Dictionary:
	return get_registry().get(id, {})


static func has_monitor(id: String) -> bool:
	return get_registry().has(id)


static func get_categories() -> Array:
	return CATEGORY_ORDER.duplicate()


static func get_monitors_by_category(category: String) -> Array:
	var ids: Array = []
	var reg: Dictionary = get_registry()
	for id in reg.keys():
		if reg[id].get("category", "") == category:
			ids.append(id)
	return ids


static func get_preset_names() -> Array:
	return PRESETS.keys()


static func resolve_preset(preset_name: String) -> Array:
	if not PRESETS.has(preset_name):
		return []
	var preset: Array = PRESETS[preset_name]
	if preset.size() == 1 and preset[0] == "*":
		return get_registry().keys()
	return preset.duplicate()


static func get_all_ids() -> Array:
	return get_registry().keys()


# Order monitor ids so that ids of the same category stay together,
# preserving CATEGORY_ORDER. Used by the auto-panel to keep sections stable.
static func sort_ids_by_category(ids: Array) -> Array:
	var by_cat: Dictionary = {}
	for id in ids:
		var monitor: Dictionary = get_monitor(id)
		if monitor.is_empty():
			continue
		var cat: String = monitor.get("category", "")
		if not by_cat.has(cat):
			by_cat[cat] = []
		by_cat[cat].append(id)

	var result: Array = []
	for cat in CATEGORY_ORDER:
		if by_cat.has(cat):
			result.append_array(by_cat[cat])
			by_cat.erase(cat)
	# Append any unknown categories at the end (custom additions).
	for cat in by_cat.keys():
		result.append_array(by_cat[cat])
	return result


# Called once per frame by DebugAPI to keep the FPS sliding window up to date.
static func tick() -> void:
	_fps_history.append(float(Engine.get_frames_per_second()))
	if _fps_history.size() > FPS_HISTORY_SIZE:
		_fps_history.remove_at(0)


# Allow external scripts to extend the registry at runtime.
static func register_custom_monitor(monitor: Dictionary) -> bool:
	if not monitor.has("id") or not monitor.has("getter"):
		push_warning("DebugMonitors: custom monitor must have 'id' and 'getter'.")
		return false
	if _registry.is_empty():
		_build_registry()
	var id: String = monitor.id
	if _registry.has(id):
		push_warning("DebugMonitors: monitor '%s' already exists, overwriting." % id)
	_registry[id] = monitor
	return true


# ============================================================================
# Static getters — Performance
# ============================================================================

static func _get_fps() -> int:
	return Engine.get_frames_per_second()


static func _get_fps_avg() -> float:
	if _fps_history.is_empty():
		return float(Engine.get_frames_per_second())
	var sum: float = 0.0
	for v in _fps_history:
		sum += v
	return sum / _fps_history.size()


static func _get_fps_min() -> float:
	if _fps_history.is_empty():
		return float(Engine.get_frames_per_second())
	var m: float = _fps_history[0]
	for v in _fps_history:
		if v < m:
			m = v
	return m


static func _get_fps_max() -> float:
	if _fps_history.is_empty():
		return float(Engine.get_frames_per_second())
	var m: float = _fps_history[0]
	for v in _fps_history:
		if v > m:
			m = v
	return m


static func _get_frame_time() -> float:
	var fps: int = Engine.get_frames_per_second()
	return 1000.0 / fps if fps > 0 else 0.0


static func _get_process_time() -> float:
	return Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0


static func _get_physics_process_time() -> float:
	return Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0


static func _get_navigation_process_time() -> float:
	return Performance.get_monitor(Performance.TIME_NAVIGATION_PROCESS) * 1000.0


# ============================================================================
# Static getters — Memory
# ============================================================================

static func _get_memory_static() -> String:
	return String.humanize_size(int(Performance.get_monitor(Performance.MEMORY_STATIC)))


static func _get_memory_static_max() -> String:
	return String.humanize_size(int(Performance.get_monitor(Performance.MEMORY_STATIC_MAX)))


static func _get_message_queue_max() -> String:
	return String.humanize_size(int(Performance.get_monitor(Performance.MEMORY_MESSAGE_BUFFER_MAX)))


static func _get_video_memory() -> String:
	return String.humanize_size(int(Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED)))


static func _get_texture_memory() -> String:
	return String.humanize_size(int(Performance.get_monitor(Performance.RENDER_TEXTURE_MEM_USED)))


static func _get_buffer_memory() -> String:
	return String.humanize_size(int(Performance.get_monitor(Performance.RENDER_BUFFER_MEM_USED)))


# ============================================================================
# Static getters — Objects
# ============================================================================

static func _get_object_count() -> int:
	return int(Performance.get_monitor(Performance.OBJECT_COUNT))


static func _get_node_count() -> int:
	return int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))


static func _get_resource_count() -> int:
	return int(Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT))


static func _get_orphan_nodes() -> int:
	return int(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT))


# ============================================================================
# Static getters — Rendering
# ============================================================================

static func _get_total_objects() -> int:
	return int(Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME))


static func _get_total_primitives() -> int:
	return int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME))


static func _get_total_draw_calls() -> int:
	return int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))


static func _get_rendering_method() -> String:
	return str(ProjectSettings.get_setting("rendering/renderer/rendering_method", "Unknown"))


static func _get_gpu_name() -> String:
	return RenderingServer.get_video_adapter_name()


static func _get_gpu_vendor() -> String:
	return RenderingServer.get_video_adapter_vendor()


static func _get_gpu_type() -> String:
	match RenderingServer.get_video_adapter_type():
		RenderingDevice.DEVICE_TYPE_INTEGRATED_GPU: return "Integrated"
		RenderingDevice.DEVICE_TYPE_DISCRETE_GPU:   return "Discrete"
		RenderingDevice.DEVICE_TYPE_VIRTUAL_GPU:    return "Virtual"
		RenderingDevice.DEVICE_TYPE_CPU:            return "CPU"
		_:                                          return "Other"


# ============================================================================
# Static getters — Physics
# ============================================================================

static func _get_active_bodies_2d() -> int:
	return int(Performance.get_monitor(Performance.PHYSICS_2D_ACTIVE_OBJECTS))


static func _get_collision_pairs_2d() -> int:
	return int(Performance.get_monitor(Performance.PHYSICS_2D_COLLISION_PAIRS))


static func _get_physics_islands_2d() -> int:
	return int(Performance.get_monitor(Performance.PHYSICS_2D_ISLAND_COUNT))


static func _get_active_bodies_3d() -> int:
	return int(Performance.get_monitor(Performance.PHYSICS_3D_ACTIVE_OBJECTS))


static func _get_collision_pairs_3d() -> int:
	return int(Performance.get_monitor(Performance.PHYSICS_3D_COLLISION_PAIRS))


static func _get_physics_islands_3d() -> int:
	return int(Performance.get_monitor(Performance.PHYSICS_3D_ISLAND_COUNT))


# ============================================================================
# Static getters — Audio
# ============================================================================

static func _get_audio_latency() -> float:
	return Performance.get_monitor(Performance.AUDIO_OUTPUT_LATENCY) * 1000.0


# ============================================================================
# Static getters — Display
# ============================================================================

static func _get_window_size() -> Array:
	var s: Vector2i = DisplayServer.window_get_size()
	return [s.x, s.y]


static func _get_window_position() -> Array:
	var p: Vector2i = DisplayServer.window_get_position()
	return [p.x, p.y]


static func _get_screen_size() -> Array:
	var s: Vector2i = DisplayServer.screen_get_size()
	return [s.x, s.y]


static func _get_screen_dpi() -> int:
	return DisplayServer.screen_get_dpi()


static func _get_screen_refresh_rate() -> float:
	return DisplayServer.screen_get_refresh_rate()


static func _get_aspect_ratio() -> float:
	var s: Vector2i = DisplayServer.window_get_size()
	return float(s.x) / float(s.y) if s.y > 0 else 0.0


static func _get_fullscreen() -> bool:
	var m: int = DisplayServer.window_get_mode()
	return m == DisplayServer.WINDOW_MODE_FULLSCREEN \
		or m == DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN


static func _get_window_mode() -> String:
	match DisplayServer.window_get_mode():
		DisplayServer.WINDOW_MODE_WINDOWED:             return "Windowed"
		DisplayServer.WINDOW_MODE_MINIMIZED:            return "Minimized"
		DisplayServer.WINDOW_MODE_MAXIMIZED:            return "Maximized"
		DisplayServer.WINDOW_MODE_FULLSCREEN:           return "Fullscreen"
		DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN: return "Exclusive Fullscreen"
		_:                                              return "Unknown"


static func _get_vsync_mode() -> String:
	match DisplayServer.window_get_vsync_mode():
		DisplayServer.VSYNC_DISABLED: return "Disabled"
		DisplayServer.VSYNC_ENABLED:  return "Enabled"
		DisplayServer.VSYNC_ADAPTIVE: return "Adaptive"
		DisplayServer.VSYNC_MAILBOX:  return "Mailbox"
		_:                            return "Unknown"


# ============================================================================
# Static getters — System
# ============================================================================

static func _get_os_name() -> String:
	return OS.get_name()


static func _get_os_version() -> String:
	var v: String = OS.get_version()
	return v if v != "" else "n/a"


static func _get_cpu_model() -> String:
	var n: String = OS.get_processor_name()
	return n if n != "" else "Unknown"


static func _get_cpu_cores() -> int:
	return OS.get_processor_count()


static func _get_architecture() -> String:
	if OS.has_feature("arm64"): return "arm64"
	if OS.has_feature("arm32"): return "arm32"
	if OS.has_feature("x86_64") or OS.has_feature("64"): return "x64"
	return "x86"


static func _get_engine_version() -> String:
	var v: Dictionary = Engine.get_version_info()
	return "Godot %s.%s.%s" % [v.major, v.minor, v.patch]


static func _get_locale() -> String:
	return OS.get_locale()


static func _get_debug_build() -> bool:
	return OS.is_debug_build()


# ============================================================================
# Static getters — Time
# ============================================================================

static func _get_time_scale() -> float:
	return Engine.time_scale


static func _get_physics_ticks_per_second() -> int:
	return Engine.physics_ticks_per_second


static func _get_uptime() -> String:
	return _format_time_short(Time.get_ticks_msec() / 1000.0)


static func _get_system_time() -> String:
	return Time.get_time_string_from_system()


# ============================================================================
# Static getters — Input
# ============================================================================

static func _get_mouse_position() -> Vector2:
	var st := Engine.get_main_loop() as SceneTree
	if st and st.root:
		return st.root.get_mouse_position()
	return Vector2.ZERO


static func _get_joypad_count() -> int:
	return Input.get_connected_joypads().size()


# ============================================================================
# Static getters — Scene
# ============================================================================

static func _get_current_scene() -> String:
	var st := Engine.get_main_loop() as SceneTree
	if st and st.current_scene:
		return st.current_scene.name
	return "(none)"


static func _get_scene_tree_node_count() -> int:
	var st := Engine.get_main_loop() as SceneTree
	if st:
		return st.get_node_count()
	return 0


# ============================================================================
# Static getters — Network
# ============================================================================

static func _get_multiplayer_id() -> int:
	var st := Engine.get_main_loop() as SceneTree
	if st:
		var mp: MultiplayerAPI = st.get_multiplayer()
		if mp:
			return mp.get_unique_id()
	return 0


static func _get_multiplayer_peers() -> int:
	var st := Engine.get_main_loop() as SceneTree
	if st:
		var mp: MultiplayerAPI = st.get_multiplayer()
		if mp:
			return mp.get_peers().size()
	return 0


# ============================================================================
# Threshold / helper builders
# ============================================================================

static func _fps_thresholds() -> Array:
	return [
		{"condition": func(v): return v >= 55,    "color": Color(0.4, 1.0, 0.4)},
		{"condition": func(v): return v >= 30,    "color": Color(1.0, 0.85, 0.2)},
		{"condition": func(_v): return true,      "color": Color(1.0, 0.3, 0.3)},
	]


static func _frame_time_thresholds() -> Array:
	return [
		{"condition": func(v): return v <= 18.0,  "color": Color(0.4, 1.0, 0.4)},
		{"condition": func(v): return v <= 33.4,  "color": Color(1.0, 0.85, 0.2)},
		{"condition": func(_v): return true,      "color": Color(1.0, 0.3, 0.3)},
	]


static func _orphan_thresholds() -> Array:
	return [
		{"condition": func(v): return v == 0,     "color": Color(0.4, 1.0, 0.4)},
		{"condition": func(v): return v < 10,     "color": Color(1.0, 0.85, 0.2)},
		{"condition": func(_v): return true,      "color": Color(1.0, 0.3, 0.3)},
	]


static func _is_true(v) -> bool:
	return bool(v)


static func _format_time_short(seconds: float) -> String:
	var s: int = int(seconds)
	var h: int = s / 3600
	var m: int = (s % 3600) / 60
	var sec: int = s % 60
	if h > 0:
		return "%d:%02d:%02d" % [h, m, sec]
	return "%d:%02d" % [m, sec]


# ============================================================================
# Registry builder
# ============================================================================

static func _build_registry() -> void:
	_registry.clear()

	# ---- Performance --------------------------------------------------------
	_add("fps",                     "FPS",                 "performance", "colored",     "%d FPS",       _get_fps,                     {"color_ranges": _fps_thresholds()})
	_add("fps_avg",                 "Avg FPS",             "performance", "colored",     "%.1f FPS",     _get_fps_avg,                 {"color_ranges": _fps_thresholds()})
	_add("fps_min",                 "Min FPS",             "performance", "colored",     "%.0f FPS",     _get_fps_min,                 {"color_ranges": _fps_thresholds()})
	_add("fps_max",                 "Max FPS",             "performance", "text",        "%.0f FPS",     _get_fps_max)
	_add("frame_time",              "Frame Time",          "performance", "colored",     "%.2f ms",      _get_frame_time,              {"color_ranges": _frame_time_thresholds()})
	_add("process_time",            "Process Time",        "performance", "text",        "%.2f ms",      _get_process_time)
	_add("physics_process_time",    "Physics Process",     "performance", "text",        "%.2f ms",      _get_physics_process_time)
	_add("navigation_process_time", "Navigation Process",  "performance", "text",        "%.2f ms",      _get_navigation_process_time)
	_add("fps_graph",               "FPS Graph",           "performance", "graph",       "",             _get_fps,                     {"history_size": 60})

	# ---- Memory -------------------------------------------------------------
	_add("memory_static",           "Static Memory",       "memory",      "text",        "%s",           _get_memory_static)
	_add("memory_static_max",       "Peak Memory",         "memory",      "text",        "%s",           _get_memory_static_max)
	_add("message_queue_max",       "Message Queue Peak",  "memory",      "text",        "%s",           _get_message_queue_max)
	_add("video_memory",            "Video Memory",        "memory",      "text",        "%s",           _get_video_memory)
	_add("texture_memory",          "Texture Memory",      "memory",      "text",        "%s",           _get_texture_memory)
	_add("buffer_memory",           "Buffer Memory",       "memory",      "text",        "%s",           _get_buffer_memory)

	# ---- Objects ------------------------------------------------------------
	_add("object_count",            "Total Objects",       "objects",     "text",        "%d",           _get_object_count)
	_add("node_count",              "Nodes",               "objects",     "text",        "%d",           _get_node_count)
	_add("resource_count",          "Resources",           "objects",     "text",        "%d",           _get_resource_count)
	_add("orphan_nodes",            "Orphan Nodes",        "objects",     "colored",     "%d",           _get_orphan_nodes,            {"color_ranges": _orphan_thresholds()})

	# ---- Rendering ----------------------------------------------------------
	# Per-frame counters refresh every tick; static GPU info refreshes once.
	_add("total_objects",           "Objects in Frame",    "rendering",   "text",        "%d",           _get_total_objects)
	_add("total_primitives",        "Primitives",          "rendering",   "text",        "%d",           _get_total_primitives)
	_add("total_draw_calls",        "Draw Calls",          "rendering",   "text",        "%d",           _get_total_draw_calls)
	_add("rendering_method",        "Rendering Method",    "rendering",   "text",        "%s",           _get_rendering_method,         {"update_interval": 60.0})
	_add("gpu_name",                "GPU",                 "rendering",   "text",        "%s",           _get_gpu_name,                 {"update_interval": 60.0})
	_add("gpu_vendor",              "GPU Vendor",          "rendering",   "text",        "%s",           _get_gpu_vendor,               {"update_interval": 60.0})
	_add("gpu_type",                "GPU Type",            "rendering",   "text",        "%s",           _get_gpu_type,                 {"update_interval": 60.0})

	# ---- Physics ------------------------------------------------------------
	_add("active_bodies_2d",        "Active Bodies 2D",    "physics",     "text",        "%d",           _get_active_bodies_2d)
	_add("collision_pairs_2d",      "Collision Pairs 2D",  "physics",     "text",        "%d",           _get_collision_pairs_2d)
	_add("physics_islands_2d",      "Islands 2D",          "physics",     "text",        "%d",           _get_physics_islands_2d)
	_add("active_bodies_3d",        "Active Bodies 3D",    "physics",     "text",        "%d",           _get_active_bodies_3d)
	_add("collision_pairs_3d",      "Collision Pairs 3D",  "physics",     "text",        "%d",           _get_collision_pairs_3d)
	_add("physics_islands_3d",      "Islands 3D",          "physics",     "text",        "%d",           _get_physics_islands_3d)

	# ---- Audio --------------------------------------------------------------
	_add("audio_latency",           "Audio Latency",       "audio",       "text",        "%.2f ms",      _get_audio_latency,             {"update_interval": 1.0})

	# ---- Display ------------------------------------------------------------
	# Display values change rarely (resize, fullscreen toggle); throttle aggressively.
	_add("window_size",             "Window Size",         "display",     "text",        "%d x %d",      _get_window_size,               {"update_interval": 0.5})
	_add("window_position",         "Window Pos",          "display",     "text",        "%d, %d",       _get_window_position,           {"update_interval": 0.5})
	_add("screen_size",             "Screen Size",         "display",     "text",        "%d x %d",      _get_screen_size,               {"update_interval": 1.0})
	_add("screen_dpi",              "Screen DPI",          "display",     "text",        "%d",           _get_screen_dpi,                {"update_interval": 5.0})
	_add("screen_refresh_rate",     "Refresh Rate",        "display",     "text",        "%.0f Hz",      _get_screen_refresh_rate,       {"update_interval": 5.0})
	_add("aspect_ratio",            "Aspect Ratio",        "display",     "text",        "%.3f",         _get_aspect_ratio,              {"update_interval": 0.5})
	_add("fullscreen",              "Fullscreen",          "display",     "conditional", "",             _get_fullscreen,                {"condition": _is_true, "true_text": "✓ ON", "false_text": "✗ OFF", "update_interval": 0.5})
	_add("window_mode",             "Window Mode",         "display",     "text",        "%s",           _get_window_mode,               {"update_interval": 0.5})
	_add("vsync_mode",              "VSync Mode",          "display",     "text",        "%s",           _get_vsync_mode,                {"update_interval": 1.0})

	# ---- System -------------------------------------------------------------
	# System info is effectively immutable — refresh once a minute is plenty.
	_add("os_name",                 "OS",                  "system",      "text",        "%s",           _get_os_name,                   {"update_interval": 60.0})
	_add("os_version",              "OS Version",          "system",      "text",        "%s",           _get_os_version,                {"update_interval": 60.0})
	_add("cpu_model",               "CPU",                 "system",      "text",        "%s",           _get_cpu_model,                 {"update_interval": 60.0})
	_add("cpu_cores",               "CPU Cores",           "system",      "text",        "%d",           _get_cpu_cores,                 {"update_interval": 60.0})
	_add("architecture",            "Arch",                "system",      "text",        "%s",           _get_architecture,              {"update_interval": 60.0})
	_add("engine_version",          "Engine",              "system",      "text",        "%s",           _get_engine_version,            {"update_interval": 60.0})
	_add("locale",                  "Locale",              "system",      "text",        "%s",           _get_locale,                    {"update_interval": 5.0})
	_add("debug_build",             "Debug Build",         "system",      "conditional", "",             _get_debug_build,               {"condition": _is_true, "true_text": "✓ DEBUG", "false_text": "RELEASE", "update_interval": 60.0})

	# ---- Time ---------------------------------------------------------------
	_add("time_scale",              "Time Scale",          "time",        "text",        "%.2fx",        _get_time_scale)
	_add("physics_ticks_per_second","Physics Ticks/s",     "time",        "text",        "%d",           _get_physics_ticks_per_second,  {"update_interval": 5.0})
	_add("uptime",                  "Uptime",              "time",        "text",        "%s",           _get_uptime,                    {"update_interval": 1.0})
	_add("system_time",             "System Time",         "time",        "text",        "%s",           _get_system_time,               {"update_interval": 0.5})

	# ---- Input --------------------------------------------------------------
	_add("mouse_position",          "Mouse Pos",           "input",       "vector",      "(%.0f, %.0f)", _get_mouse_position)
	_add("joypad_count",            "Joypads",             "input",       "text",        "%d",           _get_joypad_count,              {"update_interval": 0.5})

	# ---- Scene --------------------------------------------------------------
	_add("current_scene",           "Current Scene",       "scene",       "text",        "%s",           _get_current_scene,             {"update_interval": 1.0})
	_add("scene_tree_node_count",   "Scene Tree Nodes",    "scene",       "text",        "%d",           _get_scene_tree_node_count,     {"update_interval": 0.2})

	# ---- Network ------------------------------------------------------------
	_add("multiplayer_id",          "Multiplayer ID",      "network",     "text",        "%d",           _get_multiplayer_id,            {"update_interval": 1.0})
	_add("multiplayer_peers",       "Connected Peers",     "network",     "text",        "%d",           _get_multiplayer_peers,         {"update_interval": 0.5})


static func _add(id: String, label: String, category: String, widget_type: String,
		format: String, getter: Callable, extra: Dictionary = {}) -> void:
	var monitor: Dictionary = {
		"id":          id,
		"label":       label,
		"category":    category,
		"widget_type": widget_type,
		"format":      format,
		"getter":      getter,
	}
	monitor.merge(extra, true)
	_registry[id] = monitor
