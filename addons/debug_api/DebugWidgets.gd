# DebugWidgets.gd
# Widget classes used by DebugPanel. Each widget binds a getter (Callable)
# to a UI node and refreshes itself on demand.
#
# Performance contracts:
#   • Smart-diff: widgets compare the new value to the previous one and skip the
#     Label/UI assignment when unchanged. This is the dominant cost in tight loops.
#   • Per-widget update_interval (seconds): set on individual widgets to throttle
#     refresh rate. 0 means "follow the panel" (every panel tick).
#   • Stale getter handling: if the bound source dies, update() becomes a no-op
#     and the value is dimmed via modulate.a so it's visually obvious.

class_name DebugWidgets
extends RefCounted


# ============================================================================
# Base widget
# ============================================================================
class BaseWidget:
	var label: String = ""
	var getter: Callable
	var config: Dictionary = {}
	var label_node: Label
	var value_node: Control
	var section_name: String = ""

	# Per-widget refresh throttling. 0 = update every panel tick.
	var update_interval: float = 0.0

	# Smart-diff state: _has_value=false means "we've never updated", so the
	# first comparison always misses. This avoids needing a sentinel value
	# that could collide with a real getter result.
	var _last_value = null
	var _has_value: bool = false
	var _last_update_ms: int = 0
	var _stale: bool = false

	# Override in subclasses; refreshes the widget's visible state.
	func update() -> void:
		pass

	# Returns true when this widget is allowed to update on the current tick.
	func should_update_now() -> bool:
		if update_interval <= 0.0:
			return true
		var now: int = Time.get_ticks_msec()
		if now - _last_update_ms < int(update_interval * 1000.0):
			return false
		_last_update_ms = now
		return true

	# Wrap the getter call in a stale check; returns null if invalid and toggles
	# the visual stale indicator on first detection.
	func _safe_get():
		if not getter.is_valid():
			_mark_stale(true)
			return null
		_mark_stale(false)
		return getter.call()

	func _mark_stale(stale: bool) -> void:
		if stale == _stale:
			return
		_stale = stale
		# Dim the row on stale; restore on recovery.
		var row: Node = label_node.get_parent() if label_node else null
		if row is CanvasItem:
			(row as CanvasItem).modulate.a = 0.45 if stale else 1.0

	func get_text_value() -> String:
		return ""

	func get_display_node() -> Control:
		return null


# ============================================================================
# Text — plain "label: value" with smart diff.
# ============================================================================
class TextWidget extends BaseWidget:
	var format: String = "%s"

	func update() -> void:
		var value = _safe_get()
		if _stale:
			return
		if _has_value and value == _last_value:
			return
		_has_value = true
		_last_value = value
		if value_node is Label:
			(value_node as Label).text = format % value

	func get_text_value() -> String:
		if not getter.is_valid():
			return "ERROR"
		return format % getter.call()


# ============================================================================
# Progress bar — diff via float threshold to avoid tiny noise.
# ============================================================================
class ProgressWidget extends BaseWidget:
	var min_value: float = 0.0
	var max_value: float = 1.0
	var progress_node: ProgressBar

	func update() -> void:
		var value = _safe_get()
		if _stale:
			return
		var fv: float = float(value)
		if _has_value and absf(fv - float(_last_value)) < 0.001:
			return
		_has_value = true
		_last_value = fv
		if progress_node:
			progress_node.value = fv

	func get_text_value() -> String:
		if not getter.is_valid():
			return "ERROR"
		var value: float = float(getter.call())
		var range_v: float = max_value - min_value
		if range_v == 0.0:
			return "%.1f" % value
		return "%.1f%%" % ((value - min_value) / range_v * 100.0)

	func get_display_node() -> Control:
		return progress_node


# ============================================================================
# Graph — appends to history every update; redraws when shape changes.
# ============================================================================
class GraphWidget extends BaseWidget:
	var history_size: int = 30
	var history: PackedFloat32Array = PackedFloat32Array()
	var graph_node: ColorRect
	var line_color: Color = Color(0, 1, 0, 0.8)
	var baseline_color: Color = Color(0.5, 0.5, 0.5, 0.5)
	var _draw_node: Node2D

	func _init() -> void:
		_draw_node = Node2D.new()
		_draw_node.draw.connect(_draw_graph)

	func update() -> void:
		var value = _safe_get()
		if _stale:
			return
		var fv: float = float(value)
		history.append(fv)
		if history.size() > history_size:
			history.remove_at(0)

		if graph_node and _draw_node:
			if not _draw_node.is_inside_tree():
				graph_node.add_child(_draw_node)
			_draw_node.queue_redraw()

	func _draw_graph() -> void:
		if _draw_node == null or history.is_empty() or graph_node == null:
			return
		var width: float = graph_node.size.x
		var height: float = graph_node.size.y
		if width <= 0.0 or height <= 0.0:
			return

		var max_val: float = history[0]
		var min_val: float = history[0]
		for v in history:
			if v > max_val: max_val = v
			if v < min_val: min_val = v
		var range_val: float = max_val - min_val
		if range_val == 0.0:
			range_val = 1.0

		var points: PackedVector2Array = PackedVector2Array()
		points.resize(history.size())
		var divisor: float = float(maxi(history_size - 1, 1))
		for i in history.size():
			var x: float = float(i) / divisor * width
			var norm: float = (history[i] - min_val) / range_val
			points[i] = Vector2(x, height - norm * height)

		_draw_node.draw_polyline(points, line_color, 2.0)
		_draw_node.draw_line(Vector2(0, height), Vector2(width, height), baseline_color, 1.0)

	func get_text_value() -> String:
		if not getter.is_valid():
			return "ERROR"
		return "%.2f" % float(getter.call())


# ============================================================================
# Conditional — boolean-driven coloured text.
# ============================================================================
class ConditionalWidget extends BaseWidget:
	var condition: Callable
	var true_text: String = "✓"
	var false_text: String = "✗"
	var true_color: Color = Color(0, 1, 0, 1)
	var false_color: Color = Color(1, 0, 0, 1)
	var _last_result: int = -1   # -1 = unset, 0 = false, 1 = true

	func update() -> void:
		var value = _safe_get()
		if _stale or not condition.is_valid():
			return
		var result_bool: bool = bool(condition.call(value))
		var result: int = 1 if result_bool else 0
		if result == _last_result:
			return
		_last_result = result
		if value_node is Label:
			(value_node as Label).text = true_text if result_bool else false_text
			(value_node as Label).add_theme_color_override("font_color", true_color if result_bool else false_color)

	func get_text_value() -> String:
		if not getter.is_valid() or not condition.is_valid():
			return "ERROR"
		return true_text if bool(condition.call(getter.call())) else false_text


# ============================================================================
# Coloured — value with threshold-based colour.
# ============================================================================
class ColoredWidget extends BaseWidget:
	var color_ranges: Array = []
	var format: String = "%s"
	var _last_color_index: int = -1

	func update() -> void:
		var value = _safe_get()
		if _stale:
			return

		var color_idx: int = -1
		for i in color_ranges.size():
			var range_data: Dictionary = color_ranges[i]
			var cond: Callable = range_data.get("condition")
			if cond.is_valid() and bool(cond.call(value)):
				color_idx = i
				break

		var changed_value: bool = (not _has_value) or value != _last_value
		var changed_color: bool = color_idx != _last_color_index
		if not changed_value and not changed_color:
			return

		_has_value = true
		_last_value = value
		_last_color_index = color_idx
		if value_node is Label:
			if changed_value:
				(value_node as Label).text = format % value
			if changed_color and color_idx >= 0:
				(value_node as Label).add_theme_color_override("font_color", color_ranges[color_idx].get("color"))

	func get_text_value() -> String:
		if not getter.is_valid():
			return "ERROR"
		return format % getter.call()


# ============================================================================
# Timer — visualizes a Timer node.
# ============================================================================
class TimerWidget extends BaseWidget:
	var timer_node: Timer
	var format: String = "%.3f / %.3f"
	var show_max: bool = true

	func update() -> void:
		if not is_instance_valid(timer_node):
			_mark_stale(true)
			return
		_mark_stale(false)
		if not (value_node is Label):
			return
		var time_left: float = timer_node.time_left if not timer_node.is_stopped() else 0.0
		var key: float = snappedf(time_left, 0.001)
		if _has_value and absf(key - float(_last_value)) < 0.0005:
			return
		_has_value = true
		_last_value = key
		if show_max and timer_node.wait_time > 0:
			(value_node as Label).text = format % [time_left, timer_node.wait_time]
		else:
			(value_node as Label).text = "%.3f" % time_left

	func get_text_value() -> String:
		if not is_instance_valid(timer_node):
			return "NO TIMER"
		var time_left: float = timer_node.time_left if not timer_node.is_stopped() else 0.0
		if show_max and timer_node.wait_time > 0:
			return format % [time_left, timer_node.wait_time]
		return "%.3f" % time_left


# ============================================================================
# Vector — formats Vector2 / Vector3.
# ============================================================================
class VectorWidget extends BaseWidget:
	var format: String = "(%.1f, %.1f)"

	func update() -> void:
		var value = _safe_get()
		if _stale:
			return
		if _has_value and typeof(value) == typeof(_last_value) and value == _last_value:
			return
		_has_value = true
		_last_value = value
		if not (value_node is Label):
			return
		if value is Vector2:
			(value_node as Label).text = format % [value.x, value.y]
		elif value is Vector3:
			(value_node as Label).text = "(%.1f, %.1f, %.1f)" % [value.x, value.y, value.z]
		else:
			(value_node as Label).text = str(value)

	func get_text_value() -> String:
		if not getter.is_valid():
			return "ERROR"
		var value = getter.call()
		if value is Vector2:
			return format % [value.x, value.y]
		elif value is Vector3:
			return "(%.1f, %.1f, %.1f)" % [value.x, value.y, value.z]
		return str(value)
