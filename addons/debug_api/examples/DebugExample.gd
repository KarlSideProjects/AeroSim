# DebugExample.gd
# Demonstrates BOTH custom debug panels (per-script widgets) AND
# the new built-in auto-monitors (FPS, memory, resolution, ...) coexisting.
#
# Setup: DebugAPI.gd must be registered as an Autoload named "DebugAPI"
# (Project Settings > Autoload).

extends CharacterBody2D

# ---- Player state (drives the custom debug panel) ----
var health: float = 100.0
var mana: float = 100.0
var is_invincible: bool = false
var current_state: String = "IDLE"
var coyote_timer: Timer
var jump_buffer_timer: Timer

var debug_panel: DebugPanel


func _ready() -> void:
	_setup_timers()
	_setup_auto_monitors()
	_setup_custom_panel()


func _setup_timers() -> void:
	coyote_timer = Timer.new()
	coyote_timer.wait_time = 0.12
	coyote_timer.one_shot = true
	add_child(coyote_timer)

	jump_buffer_timer = Timer.new()
	jump_buffer_timer.wait_time = 0.12
	jump_buffer_timer.one_shot = true
	add_child(jump_buffer_timer)


# ----------------------------------------------------------------------------
# Auto-monitors — built-in metrics, no widgets to wire up.
# ----------------------------------------------------------------------------
func _setup_auto_monitors() -> void:
	# Optional: configure the auto-panel BEFORE enabling monitors.
	DebugAPI.configure_auto_panel({
		"position":         Vector2(8, 8),
		"toggle_key":       KEY_F2,                # F2 to show/hide
		"background_color": Color(0, 0, 0, 0.85),
		"min_width":        220,
		"update_interval":  0.1,                   # 10 refreshes/second is plenty
	})

	# Pick ONE of the styles below — examples are commented for reference.
	#
	#   DebugAPI.enable_monitor("fps")                        # just FPS
	#   DebugAPI.enable_monitors(["fps", "memory_static"])    # cherry-pick
	#   DebugAPI.enable_monitor_category("performance")       # full category
	#   DebugAPI.enable_all_monitors()                        # everything!
	#
	DebugAPI.enable_monitor_preset("essential")

	# Add a couple of extras on top of the preset.
	DebugAPI.enable_monitor("orphan_nodes")
	DebugAPI.enable_monitor("vsync_mode")
	DebugAPI.enable_monitor("gpu_name")


# ----------------------------------------------------------------------------
# Custom panel — bind your own values to widgets.
# ----------------------------------------------------------------------------
func _setup_custom_panel() -> void:
	var panel_config: Dictionary = {
		"position":         Vector2(get_viewport().get_visible_rect().size.x - 280, 8),
		"toggle_key":       KEY_F1,
		"start_visible":    true,
		"background_color": Color(0, 0, 0, 0.85),
		"font_color":       Color(0.8, 0.9, 1.0, 1.0),
	}
	debug_panel = DebugAPI.create_panel("PlayerDebug", self, panel_config)
	debug_panel.auto_update = true

	debug_panel.add_text_widget("STATE", "Current State", func(): return current_state)
	debug_panel.add_conditional_widget("STATE", "Invincible",
		func(): return is_invincible,
		func(v): return v,
		"🛡 YES", "❌ NO")

	debug_panel.add_progress_widget("STATS", "Health", func(): return health, 0.0, 100.0)
	debug_panel.add_progress_widget("STATS", "Mana",   func(): return mana,   0.0, 100.0)

	debug_panel.add_timer_widget("TIMERS", "Coyote",      coyote_timer)
	debug_panel.add_timer_widget("TIMERS", "Jump Buffer", jump_buffer_timer)

	debug_panel.add_vector_widget("POSITION", "Position", func(): return global_position)


# ----------------------------------------------------------------------------
# Demo input
# ----------------------------------------------------------------------------
func _process(delta: float) -> void:
	if Input.is_key_pressed(KEY_H):
		health = max(0.0, health - 50.0 * delta)
	else:
		health = min(100.0, health + 20.0 * delta)

	if Input.is_key_pressed(KEY_M):
		mana = max(0.0, mana - 40.0 * delta)
	else:
		mana = min(100.0, mana + 15.0 * delta)

	if Input.is_key_pressed(KEY_SPACE):
		coyote_timer.start()
		jump_buffer_timer.start()


func _input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_accept"):
		current_state = "JUMPING"
		await get_tree().create_timer(0.5).timeout
		current_state = "IDLE"
	if event.is_action_pressed("ui_text_backspace"):
		is_invincible = not is_invincible
