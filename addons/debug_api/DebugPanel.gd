# DebugPanel.gd — A self-contained debug panel that hosts sections and widgets.
# Visibility is driven by the Control.visible property; toggle_key flips it.
# update_interval throttles widget refresh rate (0 = every frame, n>0 = every n seconds).

class_name DebugPanel
extends Control

const DebugWidgets = preload("res://addons/debug_api/DebugWidgets.gd")
const DebugMonitors = preload("res://addons/debug_api/DebugMonitors.gd")

# ============================================================================
# Anchor presets — used by the "anchor" config key for responsive positioning
# ============================================================================

const ANCHOR_TOP_LEFT: int      = 0
const ANCHOR_TOP_RIGHT: int     = 1
const ANCHOR_BOTTOM_LEFT: int   = 2
const ANCHOR_BOTTOM_RIGHT: int  = 3
const ANCHOR_TOP_CENTER: int    = 4
const ANCHOR_BOTTOM_CENTER: int = 5
const ANCHOR_CENTER: int        = 6
const ANCHOR_FREE: int          = 7   # use the raw "position" value instead


# ============================================================================
# Public state
# ============================================================================

var panel_name: String = ""
var auto_update: bool = true
var update_interval: float = 0.0
var toggle_key: int = KEY_F1
var toggle_action: String = ""

# Internal nodes
var container: VBoxContainer        # The visible body of the panel
var title_label: Label              # Optional title at the top of the container
var sections: Dictionary = {}       # section_name -> VBoxContainer
var widgets: Array = []             # Array of DebugWidgets.BaseWidget

# Configuration (merged on setup; never mutated afterwards externally)
var _config: Dictionary = {}
var _accum_time: float = 0.0
var _scroll: ScrollContainer = null # Wraps container when max_height is set
var _section_buttons: Dictionary = {}  # section_name -> Button (collapsible mode)


# ============================================================================
# Lifecycle / setup
# ============================================================================

func setup(p_name: String, default_config: Dictionary, custom_config: Dictionary) -> void:
	panel_name = p_name
	_config = default_config.duplicate()
	_config.merge(custom_config, true)

	toggle_key = int(_config.get("toggle_key", KEY_F1))
	toggle_action = String(_config.get("toggle_action", ""))
	update_interval = float(_config.get("update_interval", 0.0))
	visible = bool(_config.get("start_visible", true))

	custom_minimum_size = Vector2(_config.get("min_width", 250), 0)

	# Cover the whole CanvasLayer so anchored positioning has a viewport-sized parent.
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	# Click-through by default; PASS lets nested Buttons (collapsible titles) still get clicks.
	mouse_filter = Control.MOUSE_FILTER_IGNORE if bool(_config.get("click_through", true)) else Control.MOUSE_FILTER_PASS

	# Build the visible container
	container = VBoxContainer.new()
	container.add_theme_constant_override("separation", _config.get("spacing", 4))
	container.mouse_filter = Control.MOUSE_FILTER_PASS

	# Background style box
	var bg: StyleBoxFlat = StyleBoxFlat.new()
	bg.bg_color = _config.get("background_color", Color(0, 0, 0, 0.7))
	var border_w: int = int(_config.get("border_width", 1))
	if border_w > 0:
		bg.set_border_width_all(border_w)
		bg.border_color = _config.get("border_color", Color(0.5, 0.5, 0.5, 0.8))
	var radius: int = int(_config.get("corner_radius", 0))
	if radius > 0:
		bg.set_corner_radius_all(radius)
	var pad: int = int(_config.get("panel_padding", 6))
	bg.content_margin_left = pad
	bg.content_margin_top = pad
	bg.content_margin_right = pad
	bg.content_margin_bottom = pad
	container.add_theme_stylebox_override("panel", bg)

	# Optional title bar
	if bool(_config.get("show_title", false)):
		_add_title()

	# Wrap in ScrollContainer when max_height is set
	var max_h: float = float(_config.get("max_height", 0.0))
	if max_h > 0.0:
		_scroll = ScrollContainer.new()
		_scroll.custom_minimum_size = Vector2(_config.get("min_width", 250), max_h)
		_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
		_scroll.add_child(container)
		add_child(_scroll)
	else:
		add_child(container)

	# Anchored positioning — applied as soon as we and the viewport know our sizes.
	_apply_anchor_position.call_deferred()


func _ready() -> void:
	if get_viewport():
		if not get_viewport().size_changed.is_connected(_apply_anchor_position):
			get_viewport().size_changed.connect(_apply_anchor_position)
	if container and not container.resized.is_connected(_apply_anchor_position):
		container.resized.connect(_apply_anchor_position)
	_apply_anchor_position()


func get_config(key: String, default_value = null):
	return _config.get(key, default_value)


# Apply a custom font (FontFile / SystemFont) to every label/widget/title in the panel.
func apply_font(font: Font) -> void:
	if font == null:
		return
	_config["font"] = font
	if title_label:
		title_label.add_theme_font_override("font", font)
	for section_name in sections:
		_apply_font_recursive(sections[section_name], font)


func _apply_font_recursive(node: Node, font: Font) -> void:
	if node is Label or node is Button:
		node.add_theme_font_override("font", font)
	for child in node.get_children():
		_apply_font_recursive(child, font)


# ============================================================================
# Section management
# ============================================================================

func add_section(title: String) -> VBoxContainer:
	if sections.has(title):
		return sections[title]

	var section_container: VBoxContainer = VBoxContainer.new()
	section_container.name = title

	var header: Control = _make_section_header(title)
	section_container.add_child(header)

	if not section_container.resized.is_connected(_apply_anchor_position):
		section_container.resized.connect(_apply_anchor_position)

	container.add_child(section_container)
	sections[title] = section_container
	return section_container


func _make_section_header(title: String) -> Control:
	var collapsible: bool = bool(_config.get("collapsible_sections", false))
	var color: Color = _config.get("section_color", Color(1, 1, 0.5, 1))
	var size: int = int(_config.get("font_size", 13)) + 2
	var custom_font: Font = _config.get("font")

	if collapsible:
		var btn: Button = Button.new()
		btn.text = "▾ %s" % title.to_upper()
		btn.flat = true
		btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
		btn.focus_mode = Control.FOCUS_NONE
		btn.add_theme_font_size_override("font_size", size)
		btn.add_theme_color_override("font_color", color)
		btn.add_theme_color_override("font_hover_color", color.lightened(0.2))
		btn.pressed.connect(toggle_section_collapse.bind(title))
		_section_buttons[title] = btn
		if custom_font:
			btn.add_theme_font_override("font", custom_font)
		return btn

	var label: Label = Label.new()
	label.text = "▸ %s" % title.to_upper()
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", color)
	if custom_font:
		label.add_theme_font_override("font", custom_font)
	_apply_shadow(label)
	return label


func _get_or_create_section(section_name: String) -> VBoxContainer:
	if sections.has(section_name):
		return sections[section_name]
	return add_section(section_name)


# Collapse / expand a single section.
func toggle_section_collapse(section_name: String) -> void:
	var section: VBoxContainer = sections.get(section_name)
	if section == null:
		return
	var collapsed: bool = bool(section.get_meta("_collapsed", false))
	collapsed = not collapsed
	section.set_meta("_collapsed", collapsed)
	# Hide all children except the first one (the header).
	for i in range(1, section.get_child_count()):
		var child: Node = section.get_child(i)
		if child is CanvasItem:
			child.visible = not collapsed
	var btn: Button = _section_buttons.get(section_name)
	if btn:
		btn.text = ("▸ " if collapsed else "▾ ") + section_name.to_upper()


func collapse_all_sections() -> void:
	for s_name in sections.keys():
		var section: VBoxContainer = sections[s_name]
		if not bool(section.get_meta("_collapsed", false)):
			toggle_section_collapse(s_name)


func expand_all_sections() -> void:
	for s_name in sections.keys():
		var section: VBoxContainer = sections[s_name]
		if bool(section.get_meta("_collapsed", false)):
			toggle_section_collapse(s_name)


# ============================================================================
# Optional title bar
# ============================================================================

func _add_title() -> void:
	title_label = Label.new()
	var t: String = String(_config.get("title_text", ""))
	if t == "":
		t = panel_name
	title_label.text = t.to_upper()
	title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title_label.add_theme_font_size_override("font_size", int(_config.get("font_size", 13)) + 4)
	title_label.add_theme_color_override("font_color", _config.get("title_color", Color(1, 1, 1, 1)))
	_apply_shadow(title_label)
	var f: Font = _config.get("font")
	if f:
		title_label.add_theme_font_override("font", f)
	container.add_child(title_label)
	container.add_child(HSeparator.new())


# ============================================================================
# Widget creation helpers (private)
# ============================================================================

func _apply_shadow(label: Label) -> void:
	var shadow_color: Color = _config.get("shadow_color", Color(0, 0, 0, 0.85))
	if shadow_color.a <= 0.0:
		return
	var so: Vector2 = _config.get("shadow_offset", Vector2(1, 1))
	label.add_theme_constant_override("shadow_offset_x", so.x)
	label.add_theme_constant_override("shadow_offset_y", so.y)
	label.add_theme_color_override("font_shadow_color", shadow_color)


func _make_label(text: String, font_color: Color) -> Label:
	var label: Label = Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", _config.get("font_size", 13))
	label.add_theme_color_override("font_color", font_color)
	var f: Font = _config.get("font")
	if f:
		label.add_theme_font_override("font", f)
	_apply_shadow(label)
	return label


func _make_label_for_field() -> Label:
	return _make_label("", _config.get("font_color", Color(0.764, 0.867, 1.0, 1.0)))


func _make_value_label() -> Label:
	return _make_label("", _config.get("value_color", Color(1, 1, 1, 1)))


func _begin_widget_row(section: String, label_text: String, vertical: bool = false) -> Dictionary:
	var section_node: VBoxContainer = _get_or_create_section(section)
	var row: Container = VBoxContainer.new() if vertical else HBoxContainer.new()

	var label_node: Label = _make_label_for_field()
	label_node.text = label_text if vertical else "%s: " % label_text

	row.add_child(label_node)
	section_node.add_child(row)
	return {"row": row, "label_node": label_node}


# ============================================================================
# Widget creation API (public — backwards compatible signatures preserved)
# ============================================================================

func add_text_widget(section: String, label: String, getter: Callable,
		format: String = "%s") -> DebugWidgets.TextWidget:
	var widget: DebugWidgets.TextWidget = DebugWidgets.TextWidget.new()
	widget.label = label
	widget.section_name = section
	widget.getter = getter
	widget.format = format
	widget.config = _config

	var ui: Dictionary = _begin_widget_row(section, label)
	widget.label_node = ui.label_node
	widget.value_node = _make_value_label()
	ui.row.add_child(widget.value_node)

	widgets.append(widget)
	return widget


func add_progress_widget(section: String, label: String, getter: Callable,
		min_val: float = 0.0, max_val: float = 1.0) -> DebugWidgets.ProgressWidget:
	var widget: DebugWidgets.ProgressWidget = DebugWidgets.ProgressWidget.new()
	widget.label = label
	widget.section_name = section
	widget.getter = getter
	widget.min_value = min_val
	widget.max_value = max_val
	widget.config = _config

	var ui: Dictionary = _begin_widget_row(section, label, true)
	widget.label_node = ui.label_node

	var progress: ProgressBar = ProgressBar.new()
	progress.min_value = min_val
	progress.max_value = max_val
	progress.show_percentage = true
	progress.add_theme_font_size_override("font_size", _config.get("font_size", 13) - 2)
	widget.progress_node = progress
	ui.row.add_child(progress)

	widgets.append(widget)
	return widget


func add_graph_widget(section: String, label: String, getter: Callable,
		history_size: int = 30) -> DebugWidgets.GraphWidget:
	var widget: DebugWidgets.GraphWidget = DebugWidgets.GraphWidget.new()
	widget.label = label
	widget.section_name = section
	widget.getter = getter
	widget.history_size = history_size
	widget.config = _config

	var ui: Dictionary = _begin_widget_row(section, label, true)
	widget.label_node = ui.label_node

	var graph: ColorRect = ColorRect.new()
	graph.custom_minimum_size = Vector2(_config.get("graph_width", 200), _config.get("graph_height", 60))
	graph.color = _config.get("graph_background", Color(0.1, 0.1, 0.1, 0.8))
	widget.graph_node = graph
	ui.row.add_child(graph)

	widgets.append(widget)
	return widget


func add_conditional_widget(section: String, label: String, getter: Callable,
		condition: Callable, true_text: String = "✓",
		false_text: String = "✗") -> DebugWidgets.ConditionalWidget:
	var widget: DebugWidgets.ConditionalWidget = DebugWidgets.ConditionalWidget.new()
	widget.label = label
	widget.section_name = section
	widget.getter = getter
	widget.condition = condition
	widget.true_text = true_text
	widget.false_text = false_text
	widget.config = _config

	var ui: Dictionary = _begin_widget_row(section, label)
	widget.label_node = ui.label_node
	widget.value_node = _make_value_label()
	ui.row.add_child(widget.value_node)

	widgets.append(widget)
	return widget


func add_colored_widget(section: String, label: String, getter: Callable,
		ranges: Array = [], format: String = "%s") -> DebugWidgets.ColoredWidget:
	var widget: DebugWidgets.ColoredWidget = DebugWidgets.ColoredWidget.new()
	widget.label = label
	widget.section_name = section
	widget.getter = getter
	widget.format = format
	widget.config = _config

	if ranges.is_empty():
		widget.color_ranges = [
			{"condition": func(v): return bool(v), "color": Color(0, 1, 0, 1)},
			{"condition": func(v): return not bool(v), "color": Color(1, 0, 0, 1)},
		]
	else:
		widget.color_ranges = ranges

	var ui: Dictionary = _begin_widget_row(section, label)
	widget.label_node = ui.label_node
	widget.value_node = _make_value_label()
	ui.row.add_child(widget.value_node)

	widgets.append(widget)
	return widget


func add_timer_widget(section: String, label: String, timer: Timer,
		show_max: bool = true) -> DebugWidgets.TimerWidget:
	var widget: DebugWidgets.TimerWidget = DebugWidgets.TimerWidget.new()
	widget.label = label
	widget.section_name = section
	widget.timer_node = timer
	widget.show_max = show_max
	widget.config = _config

	var ui: Dictionary = _begin_widget_row(section, label)
	widget.label_node = ui.label_node
	widget.value_node = _make_value_label()
	ui.row.add_child(widget.value_node)

	widgets.append(widget)
	return widget


func add_vector_widget(section: String, label: String, getter: Callable,
		format: String = "(%.1f, %.1f)") -> DebugWidgets.VectorWidget:
	var widget: DebugWidgets.VectorWidget = DebugWidgets.VectorWidget.new()
	widget.label = label
	widget.section_name = section
	widget.getter = getter
	widget.format = format
	widget.config = _config

	var ui: Dictionary = _begin_widget_row(section, label)
	widget.label_node = ui.label_node
	widget.value_node = _make_value_label()
	ui.row.add_child(widget.value_node)

	widgets.append(widget)
	return widget


# ============================================================================
# Auto-monitor dispatcher: build a widget from a DebugMonitors metadata dict
# ============================================================================

func add_monitor(monitor: Dictionary) -> Object:
	if monitor.is_empty() or not monitor.has("getter"):
		push_warning("DebugPanel: invalid monitor passed to add_monitor()")
		return null

	var category_id: String = monitor.get("category", "")
	var section: String = DebugMonitors.CATEGORIES.get(category_id, category_id.capitalize())
	if section == "":
		section = "General"

	var widget_type: String = monitor.get("widget_type", "text")
	var label: String = monitor.get("label", monitor.get("id", "?"))
	var format: String = monitor.get("format", "%s")
	var getter: Callable = monitor.get("getter")

	var widget: Object
	match widget_type:
		"text":
			widget = add_text_widget(section, label, getter, format)
		"colored":
			widget = add_colored_widget(section, label, getter, monitor.get("color_ranges", []), format)
		"graph":
			widget = add_graph_widget(section, label, getter, int(monitor.get("history_size", 30)))
		"progress":
			widget = add_progress_widget(section, label, getter,
				float(monitor.get("min", 0.0)), float(monitor.get("max", 1.0)))
		"conditional":
			var cond: Callable = monitor.get("condition", Callable())
			if not cond.is_valid():
				cond = func(v): return bool(v)
			widget = add_conditional_widget(section, label, getter, cond,
				monitor.get("true_text", "✓"), monitor.get("false_text", "✗"))
		"vector":
			widget = add_vector_widget(section, label, getter,
				monitor.get("format", "(%.1f, %.1f)"))
		_:
			push_warning("DebugPanel: unknown widget_type '%s'" % widget_type)
			widget = add_text_widget(section, label, getter, format)

	# Propagate per-monitor refresh throttling so static metrics like "gpu_name"
	# don't re-format every frame.
	if widget != null and monitor.has("update_interval"):
		widget.update_interval = float(monitor.update_interval)
	return widget


# ============================================================================
# Stats & maintenance
# ============================================================================

func widget_count() -> int:
	return widgets.size()


# Iterate widgets and prune any whose getter has gone invalid AND whose UI is gone.
# Returns the number of widgets removed.
func prune_stale() -> int:
	var to_remove: Array = []
	for w in widgets:
		if w.label_node == null or not is_instance_valid(w.label_node):
			to_remove.append(w)
		elif w.getter and not w.getter.is_valid():
			# Keep stale widgets; they're dimmed but can recover if the source returns.
			pass
	for w in to_remove:
		var idx: int = widgets.find(w)
		if idx >= 0:
			widgets.remove_at(idx)
	return to_remove.size()


# ============================================================================
# Removal
# ============================================================================

func remove_widget(widget) -> void:
	if widget == null:
		return
	var idx: int = widgets.find(widget)
	if idx == -1:
		return

	var row: Node = null
	if widget.label_node and widget.label_node.get_parent():
		row = widget.label_node.get_parent()

	var section_node: Node = row.get_parent() if row else null

	if row:
		row.queue_free()
	widgets.remove_at(idx)

	if section_node and section_node.get_child_count() <= 1:
		var section_key: String = ""
		for k in sections.keys():
			if sections[k] == section_node:
				section_key = k
				break
		if section_key != "":
			sections.erase(section_key)
			_section_buttons.erase(section_key)
		section_node.queue_free()


func clear() -> void:
	for child in container.get_children():
		# Keep the optional title bar across clears.
		if child == title_label:
			continue
		if title_label and child is HSeparator:
			continue
		child.queue_free()
	widgets.clear()
	sections.clear()
	_section_buttons.clear()


# ============================================================================
# Update / display
# ============================================================================

func update_display() -> void:
	for widget in widgets:
		# Skip hidden widgets (collapsed sections, hidden via panel.visible, etc.)
		var marker: Control = widget.label_node
		if marker == null or not marker.is_visible_in_tree():
			continue
		# Honor per-widget update_interval (set via monitor metadata or by hand).
		if not widget.should_update_now():
			continue
		widget.update()


func get_text_export() -> String:
	var lines: Array = []
	lines.append("═══ %s DEBUG ═══" % panel_name.to_upper())

	var current_section: String = ""
	for widget in widgets:
		var section: String = widget.section_name if widget.section_name != "" else "General"
		if section != current_section:
			current_section = section
			lines.append("\n▸ %s" % current_section)
		lines.append("  %s: %s" % [widget.label, widget.get_text_value()])
	return "\n".join(lines)


# Returns a dict snapshot for JSON / CSV export.
func get_data_snapshot() -> Dictionary:
	var by_section: Dictionary = {}
	for widget in widgets:
		var section: String = widget.section_name if widget.section_name != "" else "General"
		if not by_section.has(section):
			by_section[section] = {}
		by_section[section][widget.label] = widget.get_text_value()
	return {"panel": panel_name, "sections": by_section}


# ============================================================================
# Anchor positioning
# ============================================================================

func _apply_anchor_position() -> void:
	if container == null:
		return
	var anchor: int = int(_config.get("anchor", ANCHOR_TOP_LEFT))
	var em: Vector2 = _config.get("edge_margin", Vector2(8, 8))
	var positioned: Control = _scroll if _scroll else container

	if anchor == ANCHOR_FREE:
		positioned.position = _config.get("position", Vector2(8, 8))
		return

	var vp: Viewport = get_viewport()
	if vp == null:
		positioned.position = em
		return

	var vsize: Vector2 = vp.get_visible_rect().size
	var psize: Vector2 = positioned.size
	if psize.x <= 0 or psize.y <= 0:
		# Wait for layout pass; we'll be re-called via container.resized.
		positioned.position = em
		return

	positioned.position = _compute_anchor_position(anchor, vsize, psize, em)


func _compute_anchor_position(anchor: int, vp: Vector2, panel: Vector2, m: Vector2) -> Vector2:
	match anchor:
		ANCHOR_TOP_LEFT:      return m
		ANCHOR_TOP_RIGHT:     return Vector2(vp.x - panel.x - m.x, m.y)
		ANCHOR_BOTTOM_LEFT:   return Vector2(m.x, vp.y - panel.y - m.y)
		ANCHOR_BOTTOM_RIGHT:  return vp - panel - m
		ANCHOR_TOP_CENTER:    return Vector2((vp.x - panel.x) * 0.5, m.y)
		ANCHOR_BOTTOM_CENTER: return Vector2((vp.x - panel.x) * 0.5, vp.y - panel.y - m.y)
		ANCHOR_CENTER:        return (vp - panel) * 0.5
		_:                    return _config.get("position", m)


# ============================================================================
# Input / process
# ============================================================================

func _input(event: InputEvent) -> void:
	# Toggle via input action takes precedence when configured.
	if toggle_action != "" and event.is_action_pressed(toggle_action):
		visible = not visible
		return
	if toggle_key == KEY_NONE:
		return
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == toggle_key:
			visible = not visible


func _process(delta: float) -> void:
	if not auto_update or not visible:
		return
	if update_interval > 0.0:
		_accum_time += delta
		if _accum_time < update_interval:
			return
		_accum_time = 0.0
	update_display()
