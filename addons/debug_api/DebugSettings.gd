# DebugSettings.gd
# Resource holding the full configuration for the Debug API.
# Create one as a .tres file (Right-click → New Resource → DebugSettings)
# and assign it to a DebugBootstrap node, or pass it to DebugAPI.apply_settings().
#
# Anything you can configure programmatically can also be configured here from the inspector.

@tool
class_name DebugSettings
extends Resource

const DebugMonitors = preload("res://addons/debug_api/DebugMonitors.gd")

# ============================================================================
# Quick setup
# ============================================================================

## Apply a built-in preset of monitors. Choose "none" to skip the preset
## and use the per-category / per-monitor switches below instead.
@export_enum("none", "minimal", "essential", "performance", "memory", "rendering", "system", "display", "full") var preset: int = 0

## Pick a built-in visual theme. "Custom" uses the individual color exports below.
@export_enum("Custom", "Default", "Dark", "Light", "Neon", "Retro", "Minimal", "Solarized") var theme_preset: int = 1

## Skip initialization entirely when the build is not a debug build (export builds).
@export var only_in_debug_build: bool = false


# ============================================================================
# Enable monitors by category — every monitor in the chosen category turns on
# ============================================================================

@export_group("By Category")
@export var enable_performance: bool = false
@export var enable_memory: bool = false
@export var enable_objects: bool = false
@export var enable_rendering: bool = false
@export var enable_physics: bool = false
@export var enable_audio: bool = false
@export var enable_display: bool = false
@export var enable_system: bool = false
@export var enable_time: bool = false
@export var enable_input: bool = false
@export var enable_scene: bool = false
@export var enable_network: bool = false


# ============================================================================
# Specific monitors — additive; turned on in addition to preset/categories
# ============================================================================

@export_group("Specific Monitors")
## Monitor ids to enable. e.g. ["fps", "memory_static", "vsync_mode"].
## Use DebugAPI.list_available_monitors() at runtime to inspect every id.
@export var monitor_ids: Array[String] = []


# ============================================================================
# Position & anchoring
# ============================================================================

@export_group("Position")
## Anchor preset for responsive positioning. Use FREE to use 'free_position' raw.
@export_enum("Top Left", "Top Right", "Bottom Left", "Bottom Right", "Top Center", "Bottom Center", "Center", "Free") var anchor: int = 0
## Distance from the anchored edge of the viewport (in pixels).
@export var edge_margin: Vector2 = Vector2(8, 8)
## Raw position used when anchor = "Free".
@export var free_position: Vector2 = Vector2(8, 8)


# ============================================================================
# Behavior
# ============================================================================

@export_group("Panel Behavior")
## Whether the panel is visible from the start.
@export var start_visible: bool = true
## Time between widget refreshes in seconds. 0 = every frame.
@export_range(0.0, 5.0, 0.01, "or_greater") var update_interval: float = 0.0
## When true, the panel does not capture mouse clicks (game UI underneath stays clickable).
## Buttons inside the panel (collapsible section headers) still receive clicks.
@export var click_through: bool = true
## When true, each section title becomes a clickable button that folds the section.
@export var collapsible_sections: bool = false


# ============================================================================
# Hotkeys
# ============================================================================

@export_group("Hotkeys")
## Per-panel toggle key (KEY_NONE / 0 disables).
@export var toggle_key: int = KEY_F1
## Per-panel toggle via InputMap action — takes precedence over toggle_key when set.
@export var toggle_action: String = ""
## Global visibility toggle key (hides every panel).
## Pick a different key than 'toggle_key' to avoid both firing at once.
@export var global_toggle_key: int = KEY_NONE
@export var global_toggle_action: String = ""
## Hotkey that exports the current state to disk.
@export var export_hotkey: int = KEY_NONE
@export var export_action: String = ""


# ============================================================================
# Layout
# ============================================================================

@export_group("Panel Layout")
@export_range(0, 4096, 1, "or_greater") var min_width: int = 250
## When > 0, the panel becomes scrollable beyond this height.
@export_range(0.0, 4096.0, 1.0, "or_greater") var max_height: float = 0.0
## CanvasLayer index — keep above your game UI to ensure visibility.
@export_range(0, 128, 1) var canvas_layer: int = 100
@export_range(0, 32, 1) var spacing: int = 4
## Internal padding inside the panel background.
@export_range(0, 64, 1) var panel_padding: int = 6
@export_range(0, 16, 1) var border_width: int = 1
## Rounded panel corners. 0 = sharp.
@export_range(0, 32, 1) var corner_radius: int = 0


# ============================================================================
# Title bar (optional)
# ============================================================================

@export_group("Title Bar")
@export var show_title: bool = false
## Falls back to the panel name when empty.
@export var title_text: String = ""


# ============================================================================
# Style — used only when theme_preset = "Custom"
# ============================================================================

@export_group("Style (Custom theme only)")
@export var background_color: Color = Color(0, 0, 0, 0.7)
@export var border_color: Color = Color(0.5, 0.5, 0.5, 0.8)
@export var font_color: Color = Color(0.764, 0.867, 1.0, 1.0)
@export var section_color: Color = Color(1, 1, 0.5, 1)
@export var title_color: Color = Color(1, 1, 1, 1)
@export var value_color: Color = Color(1, 1, 1, 1)
@export var shadow_color: Color = Color(0, 0, 0, 0.85)
@export var shadow_offset: Vector2 = Vector2(1, 1)
@export_range(8, 64, 1) var font_size: int = 13
## Optional custom font (FontFile or SystemFont resource). Applied to every label.
@export var custom_font: Font


# ============================================================================
# Export
# ============================================================================

@export_group("Export")
## File path used by the export hotkey and by DebugAPI.export_debug_data().
@export var export_path: String = "user://debug_export.txt"
@export_enum("TXT", "JSON", "CSV") var export_format: int = 0
## When > 0, write the snapshot every N seconds to 'auto_export_path'.
@export_range(0.0, 600.0, 0.1, "or_greater") var auto_export_interval: float = 0.0
@export var auto_export_path: String = ""
@export_enum("TXT", "JSON", "CSV") var auto_export_format: int = 0


# ============================================================================
# Conversion helpers (used internally by DebugAPI.apply_settings)
# ============================================================================

## Build the panel-config dictionary consumed by DebugPanel.setup().
## When 'theme_preset' is not "Custom", color keys are omitted so the theme wins.
func to_panel_config() -> Dictionary:
	var cfg: Dictionary = {
		"toggle_key":       toggle_key,
		"toggle_action":    toggle_action,
		"start_visible":    start_visible,
		"update_interval":  update_interval,
		"min_width":        min_width,
		"max_height":       max_height,
		"layer":            canvas_layer,
		"spacing":          spacing,
		"panel_padding":    panel_padding,
		"border_width":     border_width,
		"corner_radius":    corner_radius,
		"anchor":           anchor,
		"edge_margin":      edge_margin,
		"position":         free_position,
		"click_through":    click_through,
		"collapsible_sections": collapsible_sections,
		"show_title":       show_title,
		"title_text":       title_text,
		"font_size":        font_size,
	}
	if custom_font != null:
		cfg["font"] = custom_font

	# Only include color keys when using "Custom" theme; otherwise the theme overrides.
	if theme_preset == 0:
		cfg["background_color"] = background_color
		cfg["border_color"]     = border_color
		cfg["font_color"]       = font_color
		cfg["section_color"]    = section_color
		cfg["title_color"]      = title_color
		cfg["value_color"]      = value_color
		cfg["shadow_color"]     = shadow_color
		cfg["shadow_offset"]    = shadow_offset

	return cfg


## Resolve every monitor id implied by this settings resource, deduplicated.
## Order: preset → categories (in CATEGORY_ORDER) → manually listed ids.
func collect_monitor_ids() -> Array:
	var ids: Array = []

	const PRESET_NAMES: Array[String] = [
		"", "minimal", "essential", "performance", "memory",
		"rendering", "system", "display", "full",
	]
	if preset > 0 and preset < PRESET_NAMES.size():
		_merge_unique(ids, DebugMonitors.resolve_preset(PRESET_NAMES[preset]))

	var cat_flags: Dictionary = {
		"performance": enable_performance,
		"memory":      enable_memory,
		"objects":     enable_objects,
		"rendering":   enable_rendering,
		"physics":     enable_physics,
		"audio":       enable_audio,
		"display":     enable_display,
		"system":      enable_system,
		"time":        enable_time,
		"input":       enable_input,
		"scene":       enable_scene,
		"network":     enable_network,
	}
	for cat in DebugMonitors.get_categories():
		if cat_flags.get(cat, false):
			_merge_unique(ids, DebugMonitors.get_monitors_by_category(cat))

	_merge_unique(ids, monitor_ids)
	return ids


static func _merge_unique(into: Array, source: Array) -> void:
	for item in source:
		if not into.has(item):
			into.append(item)
