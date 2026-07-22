# BootstrapExample.gd
# Brings up the Debug API WITHOUT relying on an autoload.
#
# Two ways to use this:
#
#   A) Drop a DebugBootstrap node into your main scene and configure via inspector:
#         • Pick a quick_preset, or
#         • Assign a DebugSettings .tres for full control
#      Then run — nothing else to do.
#
#   B) Programmatic (this script). Attach this to any node in your scene.

extends Node

# DebugAPI.gd has no class_name (its name is reserved for the autoload), so we
# use preload to access its constructor / static helpers when we don't want the
# autoload mode.
const DebugAPIScript = preload("res://addons/debug_api/DebugAPI.gd")


func _ready() -> void:
	# OPTION 1 — find an existing instance (autoload OR earlier-created), and
	# fall back to creating one ourselves under SceneTree.root.
	var api: Node = DebugAPIScript.instance()
	if api == null:
		api = DebugAPIScript.new()
		api.name = "DebugAPI"
		add_child(api)
	api.enable_monitor_preset("essential")

	# OPTION 2 — load a settings .tres written from the inspector and apply it.
	# var settings: DebugSettings = load("res://my_debug_settings.tres")
	# api.apply_settings(settings)

	# OPTION 3 — build a settings resource in code (for tests, demos, etc.).
	var settings := DebugSettings.new()
	settings.enable_performance = true
	settings.enable_display = true
	settings.toggle_key = KEY_F3
	settings.update_interval = 0.1
	settings.monitor_ids = ["gpu_name", "vsync_mode"]
	api.apply_settings(settings)
