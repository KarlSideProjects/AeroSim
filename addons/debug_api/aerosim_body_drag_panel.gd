extends Node

const DEBUG_API_SCRIPT = preload("res://addons/debug_api/DebugAPI.gd")
const DebugPanel = preload("res://addons/debug_api/DebugPanel.gd")
const WAITING_TEXT := "WAITING / UNAVAILABLE"

var _api: Node
var _panel
var _snapshot: Dictionary = {}
var _last_publish_count := -1
var _schema_error := ""
var _blind_mode := false
var _paused := false
var _screen_visible := true

func _ready() -> void:
    _api = DEBUG_API_SCRIPT.new()
    add_child(_api)
    _panel = _api.create_panel("AeroSimBodyDrag", self, {
        "layer": 30,
        "toggle_key": KEY_NONE,
        "toggle_action": "",
        "anchor": DebugPanel.ANCHOR_BOTTOM_LEFT,
        "edge_margin": Vector2(8, 8),
        "min_width": 380,
        "max_height": 420,
        "show_title": true,
        "title_text": "AeroSim aerodynamic snapshot",
        "click_through": true,
    })
    _panel.add_text_widget("Aerodynamics", "state", _text_value.bind("body_drag_operating_state"))
    _panel.add_text_widget("Aerodynamics", "evidence", _text_value.bind("body_drag_evidence_state"))
    _panel.add_text_widget("Aerodynamics", "reason", _text_value.bind("body_drag_reason_code"))
    _panel.add_vector_widget("Aerodynamics", "wind world NED (m/s)", _vector.bind("wind_world_mps"), "(%.2f, %.2f, %.2f)")
    _panel.add_vector_widget("Aerodynamics", "airspeed body FRD (m/s)", _vector.bind("airspeed_body_frd_mps_mean"), "(%.2f, %.2f, %.2f)")
    _panel.add_text_widget("Aerodynamics", "density (kg/m3)", _text_value.bind("air_density_kg_m3"), "%s")
    _panel.add_vector_widget("Aerodynamics", "body drag force FRD (N)", _vector.bind("body_drag_force_body_frd_n_mean"), "(%.3f, %.3f, %.3f)")
    _panel.add_vector_widget("Aerodynamics", "body torque FRD (Nm)", _vector.bind("body_drag_torque_body_frd_nm_mean"), "(%.3f, %.3f, %.3f)")
    _panel.add_vector_widget("Aerodynamics", "A3 force FRD (N)", _vector.bind("a3_drag_force_body_frd_n_mean"), "(%.3f, %.3f, %.3f)")
    _panel.add_vector_widget("Aerodynamics", "A6 angular accel FRD (rad/s2)", _vector.bind("a6_angular_accel_body_frd_rad_s2"), "(%.3f, %.3f, %.3f)")
    _panel.add_text_widget("Contract", "schema / frames", _schema_status)
    _panel.add_text_widget("Contract", "timestamp / publish", _timestamp_status)
    _panel.add_text_widget("Contract", "config hash", _text_value.bind("config_hash"))
    _apply_mode()

func update_from_snapshot(snapshot: Dictionary) -> void:
    if _blind_mode or snapshot.is_empty():
        if snapshot.is_empty():
            _snapshot = {}
            _schema_error = ""
            _last_publish_count = -1
            _api.update_all()
        return
    if snapshot.has("publish_count") and typeof(snapshot.publish_count) == TYPE_INT and int(snapshot.publish_count) <= 0:
        _snapshot = {}
        _schema_error = ""
        _last_publish_count = -1
        _api.update_all()
        return
    var required := [
        "schema_version", "world_frame", "body_frame", "units", "publish_count", "timestamp_us",
        "wind_world_mps", "airspeed_body_frd_mps_mean", "air_density_kg_m3",
        "body_drag_force_body_frd_n_mean", "body_drag_torque_body_frd_nm_mean",
        "a3_drag_force_body_frd_n_mean", "a6_angular_accel_body_frd_rad_s2",
        "body_drag_operating_state", "body_drag_evidence_state", "body_drag_reason_code", "config_hash"
    ]
    for key in required:
        if not snapshot.has(key):
            _mark_invalid("SCHEMA/INVALID missing %s" % key, snapshot)
            return
    if typeof(snapshot.publish_count) != TYPE_INT:
        _mark_invalid("SCHEMA/INVALID publish_count type", snapshot)
        return
    var publish_count: int = snapshot.publish_count
    if publish_count <= _last_publish_count:
        return
    var validation_error := _validate_snapshot(snapshot, publish_count)
    if not validation_error.is_empty():
        _mark_invalid(validation_error, snapshot)
        return
    _schema_error = ""
    _last_publish_count = publish_count
    _snapshot = snapshot.duplicate(true)
    _api.update_all()

func set_blind_mode(hidden: bool) -> void:
    _blind_mode = hidden
    _apply_mode()

func set_paused(value: bool) -> void:
    _paused = value
    _apply_mode()

func set_screen_visible(value: bool) -> void:
    _screen_visible = value
    _apply_mode()

func _apply_mode() -> void:
    if _blind_mode and _panel != null and _panel.get_viewport() != null:
        var focus_owner := _panel.get_viewport().gui_get_focus_owner() as Control
        if focus_owner != null and (focus_owner == _panel or _panel.is_ancestor_of(focus_owner)):
            focus_owner.release_focus()
    if _api != null:
        _api.global_visible = _screen_visible and not _blind_mode
        _api.paused = _blind_mode or _paused
        _api.set_process_input(not _blind_mode)
        _api.process_mode = Node.PROCESS_MODE_DISABLED if _blind_mode else Node.PROCESS_MODE_INHERIT
    if _panel != null:
        _panel.visible = _screen_visible and not _blind_mode
        _panel.set_process_input(not _blind_mode)
        _panel.process_mode = Node.PROCESS_MODE_DISABLED if _blind_mode else Node.PROCESS_MODE_INHERIT
    set_process_input(not _blind_mode)
    process_mode = Node.PROCESS_MODE_DISABLED if _blind_mode else Node.PROCESS_MODE_INHERIT
    if _api != null:
        _api.update_all()

func _value(key: String):
    if _paused:
        return "PAUSED"
    if _snapshot.is_empty():
        return WAITING_TEXT
    if not _schema_error.is_empty() and key == "body_drag_operating_state":
        return _schema_error
    if not _snapshot.has(key):
        return "SCHEMA/INVALID"
    return _snapshot[key]

func _text_value(key: String) -> String:
    return str(_value(key))

func _vector(key: String):
    if _paused:
        return "PAUSED"
    if _snapshot.is_empty():
        return WAITING_TEXT
    if not _snapshot.has(key) or not (_snapshot[key] is Vector3):
        return "UNAVAILABLE"
    return _snapshot[key]

func _mark_invalid(error: String, snapshot: Dictionary) -> void:
    _schema_error = error
    _snapshot = snapshot.duplicate(true)
    _api.update_all()

func _validate_snapshot(snapshot: Dictionary, publish_count: int) -> String:
    if typeof(snapshot.schema_version) != TYPE_INT or snapshot.schema_version != 2:
        return "SCHEMA/INVALID unsupported schema_version"
    if typeof(snapshot.world_frame) != TYPE_STRING or typeof(snapshot.body_frame) != TYPE_STRING or \
            typeof(snapshot.units) != TYPE_STRING or snapshot.world_frame != "NED" or \
            snapshot.body_frame != "FRD" or snapshot.units != "SI":
        return "SCHEMA/INVALID frame or unit contract"
    if typeof(snapshot.timestamp_us) != TYPE_INT or publish_count < 1 or snapshot.timestamp_us < 0:
        return "SCHEMA/INVALID timestamp or publish count"
    if not _last_snapshot_timestamp_is_valid(snapshot):
        return "SCHEMA/INVALID timestamp regressed"
    var vectors := [
        "wind_world_mps", "airspeed_body_frd_mps_mean", "a3_drag_force_body_frd_n_mean",
        "a6_angular_accel_body_frd_rad_s2"
    ]
    for key in vectors:
        var value = snapshot[key]
        if not (value is Vector3) or not is_finite(value.x) or not is_finite(value.y) or not is_finite(value.z):
            return "SCHEMA/INVALID non-finite %s" % key
    if typeof(snapshot.body_drag_operating_state) != TYPE_STRING or \
            not ["unavailable", "disabled", "active", "out_of_domain"].has(snapshot.body_drag_operating_state):
        return "SCHEMA/INVALID body-drag state"
    var values_available: bool = snapshot.body_drag_operating_state == "disabled" or snapshot.body_drag_operating_state == "active"
    for key in ["body_drag_force_body_frd_n_mean", "body_drag_torque_body_frd_nm_mean"]:
        var value = snapshot[key]
        if values_available:
            if not (value is Vector3) or not is_finite(value.x) or not is_finite(value.y) or not is_finite(value.z):
                return "SCHEMA/INVALID non-finite %s" % key
        elif value != null:
            return "SCHEMA/INVALID unavailable %s must be null" % key
    if typeof(snapshot.air_density_kg_m3) != TYPE_FLOAT or not is_finite(snapshot.air_density_kg_m3) or \
            (snapshot.body_drag_operating_state != "out_of_domain" and snapshot.air_density_kg_m3 <= 0.0):
        return "SCHEMA/INVALID air density"
    if typeof(snapshot.config_hash) != TYPE_STRING or snapshot.config_hash.is_empty() or snapshot.config_hash == "unavailable":
        return "SCHEMA/INVALID config hash"
    if typeof(snapshot.body_drag_evidence_state) != TYPE_STRING or \
            not ["provisional", "unavailable"].has(snapshot.body_drag_evidence_state) or \
            (values_available and snapshot.body_drag_evidence_state != "provisional") or \
            (not values_available and snapshot.body_drag_evidence_state != "unavailable"):
        return "SCHEMA/INVALID body-drag evidence"
    if typeof(snapshot.body_drag_reason_code) != TYPE_STRING or snapshot.body_drag_reason_code.is_empty():
        return "SCHEMA/INVALID body-drag reason"
    return ""

func _last_snapshot_timestamp_is_valid(snapshot: Dictionary) -> bool:
    if _snapshot.is_empty() or not _snapshot.has("timestamp_us"):
        return true
    return int(snapshot.timestamp_us) >= int(_snapshot.timestamp_us)

func _schema_status():
    if _paused:
        return "PAUSED"
    if _snapshot.is_empty():
        return WAITING_TEXT
    if not _schema_error.is_empty():
        return _schema_error
    return "v%s %s/%s %s" % [int(_snapshot.get("schema_version", 0)), str(_snapshot.get("world_frame", "")), str(_snapshot.get("body_frame", "")), str(_snapshot.get("units", ""))]

func _timestamp_status():
    if _paused:
        return "PAUSED"
    if _snapshot.is_empty():
        return WAITING_TEXT
    return "%s / %s" % [int(_snapshot.get("timestamp_us", 0)), int(_snapshot.get("publish_count", 0))]
