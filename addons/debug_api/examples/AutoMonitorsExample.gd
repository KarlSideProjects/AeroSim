# AutoMonitorsExample.gd
# Minimal demo for the built-in monitor system.
# Attach to any node in your scene and run — DebugAPI must be set up as an
# Autoload (Project Settings > Autoload, name = "DebugAPI").
#
# Press F1 to show/hide the panel.

extends Node


func _ready() -> void:
	# Smallest possible setup: just turn on FPS.
	# DebugAPI.enable_monitor("fps")

	# Want a sensible starter set? Use the "essential" preset:
	#   FPS, frame time, memory, node count, window size.
	DebugAPI.enable_monitor_preset("essential")

	# Need a deeper performance dive? Enable the whole performance category.
	# DebugAPI.enable_monitor_category("performance")

	# Want EVERYTHING (≈50 widgets)?
	# DebugAPI.enable_all_monitors()

	# Discover what's available at runtime:
	# print(DebugAPI.list_available_monitors())
	# print(DebugAPI.list_categories())
	# print(DebugAPI.list_presets())

	# Custom monitor — register your own metric.
	DebugAPI.register_custom_monitor({
		"id":          "frames_drawn",
		"label":       "Frames Drawn",
		"category":    "performance",
		"widget_type": "text",
		"format":      "%d",
		"getter":      func(): return Engine.get_frames_drawn(),
	})
	DebugAPI.enable_monitor("frames_drawn")
