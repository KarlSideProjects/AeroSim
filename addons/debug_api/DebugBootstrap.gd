# DebugBootstrap.gd
# Drop-in node that brings up the Debug API without requiring an autoload.
#
# Usage:
#   1. Add a "DebugBootstrap" node anywhere in your main scene.
#   2. (Optional) Assign a DebugSettings resource to the "settings" property,
#      OR pick a quick preset.
#   3. Run the game — the API is initialized automatically.
#
# Use bootstrap.api to access the underlying DebugAPI from your code.
@tool
class_name DebugBootstrap
extends Node

# Preload the script so we can instantiate it without depending on a class_name.
const _DebugAPIScript = preload("res://addons/debug_api/DebugAPI.gd")

## Quick way to enable a preset of monitors without creating a settings resource.
## Ignored when 'settings' is assigned.
@export_enum("none", "minimal", "essential", "performance", "memory", "rendering", "system", "display", "full") var quick_preset: int = 0

## Full configuration resource. When assigned, takes precedence over 'quick_preset'.
@export var settings: DebugSettings

## When false, call bootstrap.apply() yourself to initialize.
@export var auto_apply: bool = true

## Print enabled monitors after bootstrap. Useful when debugging the bootstrap itself.
@export var verbose: bool = false


# Set after apply() runs. Typed as Node because DebugAPI deliberately has no
# class_name (it shares its name with the autoload). Functionally it's a DebugAPI.
var api: Node


func _ready() -> void:
	if Engine.is_editor_hint():
		return
	if auto_apply:
		apply()


# Idempotent — safe to call multiple times.
func apply() -> void:
	api = _resolve_or_create_api()
	if api == null:
		push_error("DebugBootstrap: failed to obtain or create a DebugAPI instance.")
		return

	if settings != null:
		api.apply_settings(settings)
	elif quick_preset > 0:
		const PRESET_NAMES: Array[String] = [
			"", "minimal", "essential", "performance", "memory",
			"rendering", "system", "display", "full",
		]
		api.enable_monitor_preset(PRESET_NAMES[quick_preset])

	if verbose:
		print("DebugBootstrap: enabled monitors → %s" % str(api.list_enabled_monitors()))


# Reset the auto-panel and reapply the current configuration.
func reapply() -> void:
	if api == null:
		api = _resolve_or_create_api()
		if api == null:
			return
	api.disable_all_monitors()
	apply()


# Find an existing DebugAPI under the scene tree root, or create one and
# parent it there. Works whether or not the plugin/autoload is installed.
func _resolve_or_create_api() -> Node:
	# 1. Existing autoload or sibling under root.
	var existing: Node = _DebugAPIScript.instance()
	if existing != null:
		return existing

	# 2. Create one ourselves and adopt it under SceneTree.root.
	var st: SceneTree = Engine.get_main_loop() as SceneTree
	if st == null or st.root == null:
		return null

	var fresh: Node = _DebugAPIScript.new()
	fresh.name = "DebugAPI"
	if st.root.is_inside_tree():
		st.root.add_child(fresh)
	else:
		st.root.add_child.call_deferred(fresh)
	return fresh
