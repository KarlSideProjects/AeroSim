# DebugThemes.gd
# Built-in color/style presets for the Debug API.
# Apply via DebugAPI.apply_theme("dark") or via DebugSettings.theme_preset enum.
#
# A theme is just a Dictionary of style keys understood by DebugPanel.setup().
# Themes only define visual properties — layout/behavior properties (anchor,
# toggle_key, padding, etc.) are kept untouched so they layer cleanly on top.

class_name DebugThemes
extends RefCounted

# Names exposed in the inspector; index 0 is "Custom" (no theme — use individual settings).
const NAMES: Array[String] = [
	"Custom", "Default", "Dark", "Light", "Neon", "Retro", "Minimal", "Solarized",
]


static func has_theme(name: String) -> bool:
	return _index_of(name) > 0


static func get_theme(name: String) -> Dictionary:
	match name.to_lower():
		"default":   return _default()
		"dark":      return _dark()
		"light":     return _light()
		"neon":      return _neon()
		"retro":     return _retro()
		"minimal":   return _minimal()
		"solarized": return _solarized()
		_:           return {}


# Returns a theme dict given its inspector enum index. Index 0 ("Custom") returns {}.
static func get_theme_by_index(idx: int) -> Dictionary:
	if idx <= 0 or idx >= NAMES.size():
		return {}
	return get_theme(NAMES[idx])


static func get_names() -> Array:
	return NAMES.duplicate()


static func _index_of(name: String) -> int:
	for i in NAMES.size():
		if NAMES[i].to_lower() == name.to_lower():
			return i
	return -1


# ============================================================================
# Theme definitions
# ============================================================================

static func _default() -> Dictionary:
	return {
		"background_color": Color(0, 0, 0, 0.7),
		"border_color":     Color(0.5, 0.5, 0.5, 0.8),
		"font_color":       Color(0.764, 0.867, 1.0, 1.0),
		"section_color":    Color(1, 1, 0.5, 1),
		"title_color":      Color(1, 1, 1, 1),
		"value_color":      Color(1, 1, 1, 1),
		"shadow_color":     Color(0, 0, 0, 0.85),
	}


static func _dark() -> Dictionary:
	return {
		"background_color": Color(0.04, 0.04, 0.06, 0.96),
		"border_color":     Color(0.25, 0.25, 0.30, 1.0),
		"font_color":       Color(0.85, 0.85, 0.90, 1.0),
		"section_color":    Color(0.55, 0.75, 1.00, 1.0),
		"title_color":      Color(1.00, 1.00, 1.00, 1.0),
		"value_color":      Color(1.00, 1.00, 1.00, 1.0),
		"shadow_color":     Color(0, 0, 0, 1.0),
	}


static func _light() -> Dictionary:
	return {
		"background_color": Color(0.98, 0.98, 0.98, 0.95),
		"border_color":     Color(0.55, 0.55, 0.55, 1.0),
		"font_color":       Color(0.10, 0.10, 0.30, 1.0),
		"section_color":    Color(0.40, 0.20, 0.60, 1.0),
		"title_color":      Color(0.10, 0.10, 0.10, 1.0),
		"value_color":      Color(0.10, 0.10, 0.10, 1.0),
		"shadow_color":     Color(0.70, 0.70, 0.70, 0.40),
	}


static func _neon() -> Dictionary:
	return {
		"background_color": Color(0.02, 0.02, 0.06, 0.85),
		"border_color":     Color(0.0, 1.0, 0.65, 1.0),
		"font_color":       Color(0.0, 1.0, 0.65, 1.0),
		"section_color":    Color(1.0, 0.20, 0.85, 1.0),
		"title_color":      Color(1.0, 1.0, 0.20, 1.0),
		"value_color":      Color(1.0, 1.0, 1.0, 1.0),
		"shadow_color":     Color(0.0, 1.0, 0.65, 0.45),
	}


static func _retro() -> Dictionary:
	return {
		"background_color": Color(0.05, 0.10, 0.05, 0.92),
		"border_color":     Color(0.40, 1.0, 0.0, 0.80),
		"font_color":       Color(1.0, 0.70, 0.0, 1.0),
		"section_color":    Color(0.40, 1.0, 0.40, 1.0),
		"title_color":      Color(0.80, 1.0, 0.40, 1.0),
		"value_color":      Color(1.0, 0.80, 0.20, 1.0),
		"shadow_color":     Color(0.0, 0.50, 0.0, 0.50),
	}


static func _minimal() -> Dictionary:
	return {
		"background_color": Color(0, 0, 0, 0),
		"border_color":     Color(0, 0, 0, 0),
		"font_color":       Color(1.0, 1.0, 1.0, 0.85),
		"section_color":    Color(1.0, 1.0, 1.0, 0.65),
		"title_color":      Color(1.0, 1.0, 1.0, 1.0),
		"value_color":      Color(1.0, 1.0, 1.0, 0.95),
		"shadow_color":     Color(0, 0, 0, 0.85),
	}


static func _solarized() -> Dictionary:
	# Solarized-dark inspired palette
	return {
		"background_color": Color(0.000, 0.169, 0.212, 0.95),  # base03
		"border_color":     Color(0.027, 0.212, 0.259, 1.0),   # base02
		"font_color":       Color(0.514, 0.580, 0.588, 1.0),   # base0
		"section_color":    Color(0.710, 0.537, 0.000, 1.0),   # yellow
		"title_color":      Color(0.827, 0.212, 0.510, 1.0),   # magenta
		"value_color":      Color(0.345, 0.431, 0.459, 1.0),   # base01
		"shadow_color":     Color(0, 0, 0, 0.7),
	}
