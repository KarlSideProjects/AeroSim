extends Node3D

const InputProfiles = preload("res://common/flight/input_profiles.gd")
const HardwareConfig = preload("res://common/flight/hardware_config.gd")
const DEFAULT_HARDWARE_PRESET := "res://config/drones/5_inch_6s.json"
const SPAWN_POSITION := Vector3(-1.0, 0.0, 0.0)
const TAKEOFF_VELOCITY := Vector3(30.0, 0.0, 0.0)
const FLIGHT_THROTTLE := 0.75
const DEFAULT_RATES := {"rc_rate": 1.0, "super_rate": 0.722222222222, "expo": 0.0}
const RATE_FIELDS := ["rc_rate", "super_rate", "expo"]
const RATES_DISCLAIMER := "PID/filter values are AeroSim sim profile only; not Betaflight-equivalent and not safe for real aircraft."

class RateCurvePreview:
    extends Control

    var curve_points: Array = []

    func set_curve_points(points: Array) -> void:
        curve_points = points
        queue_redraw()

    func _draw() -> void:
        var rect := Rect2(Vector2.ZERO, size)
        draw_rect(rect, Color(0.08, 0.09, 0.10, 0.95), true)
        draw_line(Vector2(0.0, rect.size.y * 0.5), Vector2(rect.size.x, rect.size.y * 0.5), Color(0.35, 0.38, 0.42), 1.0)
        draw_line(Vector2(rect.size.x * 0.5, 0.0), Vector2(rect.size.x * 0.5, rect.size.y), Color(0.35, 0.38, 0.42), 1.0)
        if curve_points.size() < 2:
            return
        var max_rate := 1.0
        for point in curve_points:
            max_rate = maxf(max_rate, absf(float(point.rate_dps)))
        var previous := Vector2.ZERO
        for index in range(curve_points.size()):
            var point: Dictionary = curve_points[index]
            var current := Vector2(
                (float(point.stick) + 1.0) * 0.5 * rect.size.x,
                rect.size.y * 0.5 - (float(point.rate_dps) / max_rate) * rect.size.y * 0.45
            )
            if index > 0:
                draw_line(previous, current, Color(0.1, 0.8, 0.65), 2.0)
            previous = current

@onready var fallback_status_label: Label3D = %FallbackStatus
@onready var drone_body = get_node_or_null("DroneBody")

var native: Object
var paused := false
var exit_requested := false
var takeoff_requested := false
var reset_count := 0
var last_profile_status := ""
var main_menu_entries := ["Quick Fly", "Controller", "Drone", "Map", "Settings"]
var screen := "main_menu"
var last_error_message := ""
var last_collision_authority := -1
var collision_handoff_count := 0
var reset_hold_frames := 0
var flight_mode := "ANGLE"
var rates_profile: Dictionary = DEFAULT_RATES.duplicate()
var rate_curve_points: Array = []
var rates_persistence_status := "not verified: #49 settings persistence is not present in this worktree"
var rates_last_error := ""
var rates_update_serial := 0
var acro_roll_stick := 0.0
var acro_pitch_stick := 0.0
var acro_yaw_stick := 0.0
var pause_overlay_layer: CanvasLayer
var pause_entries: VBoxContainer
var rates_panel: PanelContainer
var rates_curve_preview: RateCurvePreview
var rates_json_text: TextEdit
var rates_diff_label: Label
var rates_error_label: Label
var rates_controls := {}

func _ready() -> void:
    _build_main_menu()
    native = ClassDB.instantiate("AeroSimNative")
    if native == null:
        push_error("AeroSimNative is not registered")
        return
    var hardware_config := HardwareConfig.new()
    if not hardware_config.apply_to_runtime(self, DEFAULT_HARDWARE_PRESET):
        last_error_message = hardware_config.last_error
        push_error("Default hardware preset failed: %s" % hardware_config.last_error)
    _build_pause_overlay()
    _update_rates_ui()
    update_fallback_status()

func _unhandled_input(event: InputEvent) -> void:
    if event.is_action_pressed("flight_takeoff"):
        request_takeoff()
    elif event.is_action_pressed("flight_pause"):
        set_paused(not paused)
    elif event.is_action_pressed("flight_respawn"):
        respawn()
    elif event.is_action_pressed("flight_altitude_hold"):
        toggle_altitude_hold()
    elif event.is_action_pressed("flight_exit"):
        exit_requested = true

func _physics_process(_delta: float) -> void:
    if reset_hold_frames > 0:
        reset_hold_frames -= 1
        if reset_hold_frames == 0 and drone_body != null and not paused:
            drone_body.freeze = false
        return
    if native == null or paused or not takeoff_requested:
        return
    if not native.call("flight_control_armed"):
        native.call("arm_flight_control", 0.0)
    var row: PackedFloat64Array
    if drone_body != null:
        _sync_native_from_drone()
        var energy_limit := _kinetic(drone_body.linear_velocity, drone_body.angular_velocity)
        if flight_mode == "ACRO":
            row = native.call(
                "step_acro_mode",
                Engine.physics_ticks_per_second,
                1000,
                FLIGHT_THROTTLE,
                acro_roll_stick,
                acro_pitch_stick,
                acro_yaw_stick,
                float(rates_profile.rc_rate),
                float(rates_profile.super_rate),
                float(rates_profile.expo)
            )
        else:
            var step_method := "step_collision_altitude_hold_mode" if flight_mode == "ALTITUDE_HOLD" else "step_collision_angle_mode"
            row = native.call(
                step_method,
                Engine.physics_ticks_per_second,
                1000,
                FLIGHT_THROTTLE,
                0.0,
                0.0,
                0.0,
                drone_body.contact_seen,
                drone_body.contact_normal.x,
                drone_body.contact_normal.y,
                drone_body.contact_normal.z,
                drone_body.contact_impulse.x,
                drone_body.contact_impulse.y,
                drone_body.contact_impulse.z,
                0.0,
                drone_body.linear_velocity.x,
                drone_body.linear_velocity.y,
                drone_body.linear_velocity.z,
                drone_body.angular_velocity.x,
                drone_body.angular_velocity.y,
                drone_body.angular_velocity.z,
                energy_limit
            )
        if drone_body.contact_seen:
            collision_handoff_count += 1
        drone_body.reset_contact()
    else:
        if flight_mode == "ACRO":
            row = native.call(
                "step_acro_mode",
                Engine.physics_ticks_per_second,
                1000,
                FLIGHT_THROTTLE,
                acro_roll_stick,
                acro_pitch_stick,
                acro_yaw_stick,
                float(rates_profile.rc_rate),
                float(rates_profile.super_rate),
                float(rates_profile.expo)
            )
        else:
            var free_flight_method := "step_altitude_hold_mode" if flight_mode == "ALTITUDE_HOLD" else "step_angle_mode"
            row = native.call(free_flight_method, Engine.physics_ticks_per_second, 1000, FLIGHT_THROTTLE, 0.0, 0.0, 0.0)
    if row.size() >= 13:
        last_collision_authority = int(row[12])
    if drone_body != null and row.size() >= 12:
        var angular_velocity := Vector3.ZERO
        if row.size() >= 17:
            angular_velocity = Vector3(row[14], row[15], row[16])
        else:
            var diagnostics: Dictionary = native.call("flight_control_diagnostics")
            angular_velocity = Vector3(
                float(diagnostics.get("angular_velocity_x_rad_s", 0.0)),
                float(diagnostics.get("angular_velocity_y_rad_s", 0.0)),
                float(diagnostics.get("angular_velocity_z_rad_s", 0.0))
            )
        drone_body.apply_native_state(
            Vector3(row[1], row[2], row[3]),
            Quaternion(row[4], row[5], row[6], row[7]),
            Vector3(row[8], row[9], row[10]),
            angular_velocity
        )

func request_takeoff() -> void:
    screen = "flight"
    flight_mode = "ANGLE"
    set_paused(false)
    takeoff_requested = true
    update_fallback_status()
    if drone_body != null:
        drone_body.reset_contact()
        drone_body.global_position = SPAWN_POSITION
        drone_body.linear_velocity = TAKEOFF_VELOCITY
        drone_body.angular_velocity = Vector3.ZERO

func quick_fly(entry_state: String = "calibrated") -> void:
    if entry_state == "no_controller":
        last_error_message = InputProfiles.fallback_status([])
        screen = "fallback_prompt"
        return
    if entry_state == "uncalibrated":
        last_error_message = ""
        screen = "controller_setup"
        return
    if entry_state != "calibrated":
        last_error_message = "Quick Fly cannot continue: %s" % entry_state
        screen = "error"
        return
    request_takeoff()

func accept_fallback() -> void:
    if screen == "fallback_prompt":
        request_takeoff()
        return
    last_error_message = "No fallback prompt is active"
    screen = "error"

func respawn() -> void:
    reset_count += 1
    screen = "flight"
    flight_mode = "ANGLE"
    takeoff_requested = true
    if native != null:
        native.call("reset_flight")
    update_fallback_status()
    if drone_body != null:
        _reset_drone_body()
        # ponytail: short reset hold; replace with real throttle input state when controller profiles land.
        reset_hold_frames = 30

func update_fallback_status() -> void:
    last_profile_status = InputProfiles.fallback_status(Input.get_connected_joypads())
    fallback_status_label.text = "%s | Mode: %s" % [last_profile_status, flight_mode]

func toggle_altitude_hold() -> void:
    if native == null or not takeoff_requested:
        return
    if flight_mode == "ALTITUDE_HOLD":
        flight_mode = "ANGLE"
    else:
        native.call("capture_altitude_hold")
        flight_mode = "ALTITUDE_HOLD"
    update_fallback_status()

func use_acro_mode() -> void:
    flight_mode = "ACRO"
    update_fallback_status()

func set_paused(value: bool) -> void:
    paused = value
    if drone_body != null:
        drone_body.freeze = value
    if pause_overlay_layer != null:
        pause_overlay_layer.visible = value
    if value and pause_entries != null and pause_entries.get_child_count() > 0:
        (pause_entries.get_child(0) as Control).grab_focus()

func set_rates_profile(rc_rate: float, super_rate: float, expo: float) -> bool:
    var incoming := {"rc_rate": rc_rate, "super_rate": super_rate, "expo": expo}
    var error := _validate_rates(incoming)
    if error != "":
        rates_last_error = error
        push_error(error)
        _update_rates_ui()
        return false
    rates_profile = incoming
    rates_last_error = ""
    rates_update_serial += 1
    _update_rates_ui()
    return true

func restore_default_rates() -> void:
    set_rates_profile(float(DEFAULT_RATES.rc_rate), float(DEFAULT_RATES.super_rate), float(DEFAULT_RATES.expo))

func export_rates_json() -> String:
    return JSON.stringify({
        "schema_version": 1,
        "rate_model": "Betaflight",
        "rates": rates_profile.duplicate()
    }, "  ")

func import_rates_json(text: String) -> bool:
    var parsed := _parse_rates_json(text)
    if not parsed.ok:
        rates_last_error = parsed.error
        push_error(parsed.error)
        _update_rates_ui()
        return false
    return set_rates_profile(float(parsed.rates.rc_rate), float(parsed.rates.super_rate), float(parsed.rates.expo))

func rates_diff_from_json(text: String) -> Array:
    var parsed := _parse_rates_json(text)
    if not parsed.ok:
        return [{"field": "error", "error": parsed.error, "matches": false}]
    var rows := []
    for field in RATE_FIELDS:
        var current := float(rates_profile[field])
        var incoming := float(parsed.rates[field])
        rows.append({
            "field": field,
            "current": current,
            "incoming": incoming,
            "delta": current - incoming,
            "matches": is_equal_approx(current, incoming)
        })
    return rows

func betaflight_diff_text() -> String:
    var lines := ["rateprofile 0", "set rates_type = BETAFLIGHT"]
    var fields := {
        "rc_rate": "rc_rate",
        "super_rate": "srate",
        "expo": "expo"
    }
    for axis in ["roll", "pitch", "yaw"]:
        for field in RATE_FIELDS:
            lines.append("set %s_%s = %.6f" % [axis, fields[field], float(rates_profile[field])])
    return "\n".join(lines)

func _build_main_menu() -> void:
    var layer := CanvasLayer.new()
    layer.name = "MainMenu"
    add_child(layer)

    var entries := VBoxContainer.new()
    entries.name = "Entries"
    layer.add_child(entries)

    for entry in main_menu_entries:
        var button := Button.new()
        button.name = entry.replace(" ", "")
        button.text = entry
        entries.add_child(button)
        if entry == "Quick Fly":
            button.pressed.connect(quick_fly.bind("calibrated"))

func _build_pause_overlay() -> void:
    pause_overlay_layer = CanvasLayer.new()
    pause_overlay_layer.name = "PauseOverlay"
    pause_overlay_layer.layer = 100
    pause_overlay_layer.visible = false
    add_child(pause_overlay_layer)

    var root := MarginContainer.new()
    root.name = "Root"
    root.set_anchors_preset(Control.PRESET_FULL_RECT)
    root.add_theme_constant_override("margin_left", 24)
    root.add_theme_constant_override("margin_top", 24)
    root.add_theme_constant_override("margin_right", 24)
    root.add_theme_constant_override("margin_bottom", 24)
    pause_overlay_layer.add_child(root)

    var columns := HBoxContainer.new()
    columns.name = "Columns"
    root.add_child(columns)

    pause_entries = VBoxContainer.new()
    pause_entries.name = "Entries"
    pause_entries.custom_minimum_size = Vector2(180, 0)
    columns.add_child(pause_entries)

    var items := {
        "Resume": func(): set_paused(false),
        "Reset": respawn,
        "Change Spawn": respawn,
        "Rates": _show_rates_panel,
        "Camera": func(): pass,
        "OSD": func(): pass,
        "Controller Monitor": func(): pass,
        "Status Diagram": func(): pass,
        "Exit": func(): exit_requested = true
    }
    for label in items:
        var button := Button.new()
        button.name = label.replace(" ", "")
        button.text = label
        button.focus_mode = Control.FOCUS_ALL
        button.pressed.connect(items[label])
        pause_entries.add_child(button)

    rates_panel = PanelContainer.new()
    rates_panel.name = "RatesPanel"
    rates_panel.visible = false
    rates_panel.custom_minimum_size = Vector2(520, 420)
    columns.add_child(rates_panel)

    var margin := MarginContainer.new()
    margin.add_theme_constant_override("margin_left", 12)
    margin.add_theme_constant_override("margin_top", 12)
    margin.add_theme_constant_override("margin_right", 12)
    margin.add_theme_constant_override("margin_bottom", 12)
    rates_panel.add_child(margin)

    var form := VBoxContainer.new()
    form.name = "Form"
    margin.add_child(form)

    var title := Label.new()
    title.name = "Title"
    title.text = "Betaflight Rates"
    form.add_child(title)

    for field in RATE_FIELDS:
        var row := HBoxContainer.new()
        row.name = field
        form.add_child(row)

        var label := Label.new()
        label.custom_minimum_size = Vector2(110, 0)
        label.text = _rate_label(field)
        row.add_child(label)

        var spin := SpinBox.new()
        spin.name = "Value"
        spin.min_value = 0.0
        spin.max_value = 3.0 if field == "rc_rate" else 0.99
        spin.step = 0.01
        spin.focus_mode = Control.FOCUS_ALL
        spin.value_changed.connect(_on_rate_value_changed.bind(field))
        row.add_child(spin)
        rates_controls[field] = spin

    rates_curve_preview = RateCurvePreview.new()
    rates_curve_preview.name = "CurvePreview"
    rates_curve_preview.custom_minimum_size = Vector2(480, 150)
    form.add_child(rates_curve_preview)

    rates_json_text = TextEdit.new()
    rates_json_text.name = "RatesJsonText"
    rates_json_text.custom_minimum_size = Vector2(480, 96)
    form.add_child(rates_json_text)

    var actions := HBoxContainer.new()
    actions.name = "Actions"
    form.add_child(actions)

    var export_button := Button.new()
    export_button.name = "ExportJson"
    export_button.text = "Export JSON"
    export_button.pressed.connect(_export_rates_to_text)
    actions.add_child(export_button)

    var import_button := Button.new()
    import_button.name = "ImportJson"
    import_button.text = "Import JSON"
    import_button.pressed.connect(func(): import_rates_json(rates_json_text.text))
    actions.add_child(import_button)

    var reset_button := Button.new()
    reset_button.name = "RestoreDefaults"
    reset_button.text = "Restore Defaults"
    reset_button.pressed.connect(restore_default_rates)
    actions.add_child(reset_button)

    rates_diff_label = Label.new()
    rates_diff_label.name = "BetaflightDiff"
    form.add_child(rates_diff_label)

    var disclaimer := Label.new()
    disclaimer.name = "SimProfileDisclaimer"
    disclaimer.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    disclaimer.text = RATES_DISCLAIMER
    form.add_child(disclaimer)

    rates_error_label = Label.new()
    rates_error_label.name = "RatesError"
    form.add_child(rates_error_label)

func _show_rates_panel() -> void:
    rates_panel.visible = true
    _update_rates_ui()
    if rates_controls.has("rc_rate"):
        (rates_controls.rc_rate as Control).grab_focus()

func _on_rate_value_changed(value: float, field: String) -> void:
    var next := rates_profile.duplicate()
    next[field] = value
    set_rates_profile(float(next.rc_rate), float(next.super_rate), float(next.expo))

func _export_rates_to_text() -> void:
    rates_json_text.text = export_rates_json()
    _update_rates_ui()

func _update_rates_ui() -> void:
    rate_curve_points = _compute_rate_curve_points()
    for field in rates_controls:
        var spin := rates_controls[field] as SpinBox
        spin.set_value_no_signal(float(rates_profile[field]))
    if rates_curve_preview != null:
        rates_curve_preview.set_curve_points(rate_curve_points)
    if rates_diff_label != null:
        rates_diff_label.text = betaflight_diff_text()
    if rates_error_label != null:
        rates_error_label.text = rates_last_error if rates_last_error != "" else rates_persistence_status

func _compute_rate_curve_points() -> Array:
    if native == null or not native.has_method("betaflight_rate_degrees_per_second"):
        rates_last_error = "not verified: AeroSimNative.betaflight_rate_degrees_per_second is unavailable"
        push_error(rates_last_error)
        return []
    var points := []
    for index in range(17):
        var stick := -1.0 + float(index) / 8.0
        points.append({
            "stick": stick,
            "rate_dps": float(native.call(
                "betaflight_rate_degrees_per_second",
                stick,
                float(rates_profile.rc_rate),
                float(rates_profile.super_rate),
                float(rates_profile.expo)
            ))
        })
    return points

func _parse_rates_json(text: String) -> Dictionary:
    var json := JSON.new()
    if json.parse(text) != OK:
        return {"ok": false, "error": "Rates JSON parse failed at line %d: %s" % [json.get_error_line(), json.get_error_message()]}
    if not (json.data is Dictionary):
        return {"ok": false, "error": "Rates JSON root must be an object"}
    var root: Dictionary = json.data
    var rates: Dictionary = root.get("rates", root)
    var error := _validate_rates(rates)
    if error != "":
        return {"ok": false, "error": error}
    return {"ok": true, "rates": {
        "rc_rate": float(rates.rc_rate),
        "super_rate": float(rates.super_rate),
        "expo": float(rates.expo)
    }}

func _validate_rates(rates: Dictionary) -> String:
    for field in RATE_FIELDS:
        if not rates.has(field):
            return "Rates JSON missing field: %s" % field
        if not (rates[field] is float or rates[field] is int):
            return "Rates field must be numeric: %s" % field
    if float(rates.rc_rate) <= 0.0 or float(rates.rc_rate) > 3.0:
        return "RC Rate must be > 0 and <= 3"
    if float(rates.super_rate) < 0.0 or float(rates.super_rate) >= 1.0:
        return "Super Rate must be >= 0 and < 1"
    if float(rates.expo) < 0.0 or float(rates.expo) > 1.0:
        return "Expo must be >= 0 and <= 1"
    return ""

func _rate_label(field: String) -> String:
    if field == "rc_rate":
        return "RC Rate"
    if field == "super_rate":
        return "Super Rate"
    return "Expo"

func _reset_drone_body() -> void:
    drone_body.reset_contact()
    drone_body.apply_native_state(SPAWN_POSITION, Quaternion.IDENTITY, Vector3.ZERO, Vector3.ZERO)
    drone_body.freeze = true

func _kinetic(linear_velocity: Vector3, angular_velocity: Vector3) -> float:
    return 0.5 * linear_velocity.length_squared() + 0.5 * angular_velocity.length_squared()

func _sync_native_from_drone() -> void:
    var q: Quaternion = drone_body.global_transform.basis.get_rotation_quaternion()
    native.call(
        "sync_flight_state",
        drone_body.global_position.x,
        drone_body.global_position.y,
        drone_body.global_position.z,
        q.x,
        q.y,
        q.z,
        q.w,
        drone_body.linear_velocity.x,
        drone_body.linear_velocity.y,
        drone_body.linear_velocity.z,
        drone_body.angular_velocity.x,
        drone_body.angular_velocity.y,
        drone_body.angular_velocity.z
    )
