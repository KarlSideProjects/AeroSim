# AdvancedConfigExample.gd
# Showcases the full configuration surface added in v1.0:
#   • Themes (built-in or custom)
#   • Anchored positioning (top-right, bottom-center, etc.)
#   • Collapsible sections
#   • Optional title bar
#   • Click-through behavior
#   • Custom hotkeys via InputMap actions
#   • JSON / CSV export + export hotkey
#   • Auto-export to disk every N seconds
#   • Settings persistence (.tres save / load)
#
# Attach to any node in a scene with the plugin enabled (DebugAPI autoload).
# Press F1 to show/hide the auto panel, F2 to toggle ALL panels globally,
# F3 to dump the current state to user://debug_export.json.

extends Node


func _ready() -> void:
	# ---------------------------------------------------------------------
	# Pick a built-in theme — feel free to swap "neon" with "dark", "light",
	# "retro", "minimal", "solarized" or "default".
	# ---------------------------------------------------------------------
	DebugAPI.apply_theme("neon")

	# ---------------------------------------------------------------------
	# Configure the auto-panel BEFORE turning monitors on. Pretty much every
	# knob lives here.
	# ---------------------------------------------------------------------
	DebugAPI.configure_auto_panel({
		# Anchored to the top-right corner with an 8 px margin from each edge.
		"anchor":      DebugPanel.ANCHOR_TOP_RIGHT,
		"edge_margin": Vector2(12, 12),

		# Title bar
		"show_title": true,
		"title_text": "GAME DEBUG",

		# Layout
		"min_width":      260,
		"max_height":     420,   # scroll when content exceeds this
		"panel_padding":  8,
		"corner_radius":  6,
		"border_width":   1,
		"spacing":        4,

		# Behavior
		"collapsible_sections": true,    # click section titles to fold
		"click_through":        true,    # game UI underneath stays clickable
		"update_interval":      0.1,     # 10 Hz, easy on perf
		"toggle_key":           KEY_F1,
		# "toggle_action":      "toggle_debug",  # uncomment if you registered an InputMap action
	})

	# ---------------------------------------------------------------------
	# Hotkeys handled at the API level (orthogonal to per-panel toggle_key).
	# ---------------------------------------------------------------------
	DebugAPI.global_toggle_key = KEY_F2          # F2 hides every panel at once
	DebugAPI.export_hotkey     = KEY_F3          # F3 writes a snapshot to disk
	DebugAPI.export_path       = "user://debug_export.json"
	DebugAPI.export_format     = DebugAPI.EXPORT_JSON

	# Optionally, write a snapshot every 30 s automatically.
	# DebugAPI.auto_export_path     = "user://debug_autosnap.json"
	# DebugAPI.auto_export_format   = DebugAPI.EXPORT_JSON
	# DebugAPI.auto_export_interval = 30.0

	# ---------------------------------------------------------------------
	# Pick which monitors to show.
	# ---------------------------------------------------------------------
	DebugAPI.enable_monitor_preset("essential")
	DebugAPI.enable_monitor("vsync_mode")
	DebugAPI.enable_monitor("gpu_name")
	DebugAPI.enable_monitor("orphan_nodes")

	# ---------------------------------------------------------------------
	# Persist this configuration so the user can ship it as a .tres.
	# Uncomment to save once, then load_settings on next launch.
	# ---------------------------------------------------------------------
	# var snapshot := DebugAPI.snapshot_settings()
	# DebugAPI.save_settings(snapshot, "user://my_debug_config.tres")
	#
	# var loaded := DebugAPI.load_settings("user://my_debug_config.tres")
	# if loaded:
	#     DebugAPI.apply_settings(loaded)


# Optional — collapse all sections at start for a cleaner first view.
func _on_ready_collapse_all_demo() -> void:
	var panel: DebugPanel = DebugAPI.get_auto_panel()
	if panel:
		panel.collapse_all_sections()
