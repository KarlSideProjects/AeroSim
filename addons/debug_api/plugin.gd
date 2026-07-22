# plugin.gd — Editor plugin for the Debug API.
# Registers the "DebugAPI" autoload when enabled and removes it on disable,
# so users only need to tick "Debug API" in Project Settings → Plugins.
@tool
extends EditorPlugin

const AUTOLOAD_NAME: String = "DebugAPI"
const AUTOLOAD_PATH: String = "res://addons/debug_api/DebugAPI.gd"


func _enter_tree() -> void:
	add_autoload_singleton(AUTOLOAD_NAME, AUTOLOAD_PATH)


func _exit_tree() -> void:
	remove_autoload_singleton(AUTOLOAD_NAME)
