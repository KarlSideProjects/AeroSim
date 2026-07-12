extends PanelContainer

signal completed(profile: InputProfiles.GamepadProfile)
signal rejected(code: String)

const InputProfiles = preload("res://common/flight/input_profiles.gd")

var step_names := ["Detect supported Xbox controller"]
var step_index := 0
var last_rejection := ""
var status_label := Label.new()
var action_button := Button.new()

func _ready() -> void:
	name = "GamepadSetup"
	var rows := VBoxContainer.new()
	rows.name = "Rows"
	add_child(rows)
	status_label.name = "Status"
	rows.add_child(status_label)
	action_button.name = "Detect"
	action_button.pressed.connect(advance_detect_device)
	rows.add_child(action_button)
	_refresh_status()

func advance_detect_device(device_id: int = _first_connected_device()) -> bool:
	var profile := InputProfiles.GamepadProfile.xbox_default(device_id)
	if profile == null:
		last_rejection = "unsupported_device"
		rejected.emit(last_rejection)
		_refresh_status()
		return false
	last_rejection = ""
	completed.emit(profile)
	return true

func _first_connected_device() -> int:
	var devices := Input.get_connected_joypads()
	return devices[0] if not devices.is_empty() else -1

func _refresh_status() -> void:
	status_label.text = "1/1 %s%s" % [step_names[0], "" if last_rejection.is_empty() else ": " + last_rejection]
