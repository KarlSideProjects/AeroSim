class_name AirSimSettings
extends RefCounted

const DEFAULT_API_SERVER_PORT: int = 41451
const SUPPORTED_SIM_MODE := "Multirotor"
const SUPPORTED_CLOCK_TYPES := ["", "SteppableClock", "ScalableClock"]
const SUPPORTED_VEHICLE_TYPES := ["SimpleFlight", "PX4Multirotor"]

const ROOT_KEYS := {
    "SettingsVersion": true,
    "SimMode": true,
    "ClockType": true,
    "ClockSpeed": true,
    "ApiServerPort": true,
    "RpcEnabled": true,
    "OriginGeopoint": true,
    "Vehicles": true,
    "SubWindows": true,
    "Recording": true,
}

const ORIGIN_KEYS := {
    "Latitude": true,
    "Longitude": true,
    "Altitude": true,
}

const VEHICLE_KEYS := {
    "VehicleType": true,
    "Cameras": true,
    "Sensors": true,
}

const RECORDING_KEYS := {
    "RecordOnMove": true,
    "RecordInterval": true,
    "Folder": true,
    "Enabled": true,
}

const CAMERA_KEYS := {
    "X": true,
    "Y": true,
    "Z": true,
    "Roll": true,
    "Pitch": true,
    "Yaw": true,
    "Gimbal": true,
    "CaptureSettings": true,
    "NoiseSettings": true,
}

const SENSOR_KEYS := {
    "SensorType": true,
    "Enabled": true,
    "X": true,
    "Y": true,
    "Z": true,
    "Roll": true,
    "Pitch": true,
    "Yaw": true,
    "DrawDebugPoints": true,
    "DataFrame": true,
    "Parameters": true,
}

const SUBWINDOW_KEYS := {
    "WindowID": true,
    "ImageType": true,
    "Visible": true,
    "CameraName": true,
    "CameraID": true,
    "VehicleName": true,
    "External": true,
}


static func validate(raw: Dictionary) -> Dictionary:
    var errors: Array[String] = []
    var settings := raw.duplicate(true)

    settings["SimMode"] = raw.get("SimMode", SUPPORTED_SIM_MODE)
    settings["ClockType"] = raw.get("ClockType", "")
    settings["ClockSpeed"] = raw.get("ClockSpeed", 1.0)
    settings["ApiServerPort"] = raw.get("ApiServerPort", DEFAULT_API_SERVER_PORT)
    settings["RpcEnabled"] = raw.get("RpcEnabled", true)

    _reject_unknown_keys(raw, ROOT_KEYS, "root", errors)
    _validate_settings_version(raw, errors)
    _validate_sim_mode(raw, errors)
    _validate_clock(raw, errors)
    _validate_rpc(raw, errors)
    _validate_origin(raw, errors)
    _validate_vehicles(raw, errors)
    _validate_subwindows(raw, errors)
    _validate_recording(raw, errors)

    var result := {
        "ok": errors.is_empty(),
        "settings": settings,
        "error": "; ".join(errors),
        "errors": errors,
    }
    return result


static func _reject_unknown_keys(value: Dictionary, allowed: Dictionary, scope: String, errors: Array[String]) -> void:
    for key in value.keys():
        var key_name := String(key)
        if not allowed.has(key_name):
            errors.append("unsupported %s setting '%s'" % [scope, key_name])


static func _validate_settings_version(raw: Dictionary, errors: Array[String]) -> void:
    if not raw.has("SettingsVersion"):
        errors.append("SettingsVersion is required")
    elif typeof(raw["SettingsVersion"]) not in [TYPE_INT, TYPE_FLOAT] or is_equal_approx(float(raw["SettingsVersion"]), 1.2) == false:
        errors.append("SettingsVersion must be numeric 1.2")


static func _validate_sim_mode(raw: Dictionary, errors: Array[String]) -> void:
    if raw.has("SimMode") and (typeof(raw["SimMode"]) != TYPE_STRING or raw["SimMode"] != SUPPORTED_SIM_MODE):
        errors.append("SimMode must be 'Multirotor'")


static func _validate_clock(raw: Dictionary, errors: Array[String]) -> void:
    if raw.has("ClockType") and (typeof(raw["ClockType"]) != TYPE_STRING or not SUPPORTED_CLOCK_TYPES.has(raw["ClockType"])):
        errors.append("ClockType must be SteppableClock, ScalableClock, or empty")
    if raw.has("ClockSpeed") and (typeof(raw["ClockSpeed"]) not in [TYPE_INT, TYPE_FLOAT] or float(raw["ClockSpeed"]) <= 0.0):
        errors.append("ClockSpeed must be a positive number")


static func _validate_rpc(raw: Dictionary, errors: Array[String]) -> void:
    if raw.has("RpcEnabled") and typeof(raw["RpcEnabled"]) != TYPE_BOOL:
        errors.append("RpcEnabled must be boolean")
    if raw.has("ApiServerPort"):
        var port = raw["ApiServerPort"]
        if typeof(port) != TYPE_INT or int(port) < 1 or int(port) > 65535:
            errors.append("ApiServerPort must be an integer from 1 to 65535")


static func _validate_origin(raw: Dictionary, errors: Array[String]) -> void:
    if not raw.has("OriginGeopoint"):
        return
    if typeof(raw["OriginGeopoint"]) != TYPE_DICTIONARY:
        errors.append("OriginGeopoint must be an object")
        return
    var origin: Dictionary = raw["OriginGeopoint"]
    _reject_unknown_keys(origin, ORIGIN_KEYS, "OriginGeopoint", errors)
    for key in ORIGIN_KEYS:
        if not origin.has(key) or typeof(origin[key]) not in [TYPE_INT, TYPE_FLOAT]:
            errors.append("OriginGeopoint.%s must be numeric" % key)


static func _validate_vehicles(raw: Dictionary, errors: Array[String]) -> void:
    if not raw.has("Vehicles"):
        return
    if typeof(raw["Vehicles"]) != TYPE_DICTIONARY:
        errors.append("Vehicles must be an object")
        return
    var vehicles: Dictionary = raw["Vehicles"]
    if vehicles.is_empty() or vehicles.size() > 2:
        errors.append("Vehicles must contain one or two named vehicles")
    for vehicle_name in vehicles:
        var vehicle = vehicles[vehicle_name]
        if typeof(vehicle) != TYPE_DICTIONARY:
            errors.append("Vehicles.%s must be an object" % vehicle_name)
            continue
        if typeof(vehicle_name) != TYPE_STRING or String(vehicle_name).is_empty():
            errors.append("vehicle names must be non-empty strings")
            continue
        var vehicle_dict: Dictionary = vehicle
        _reject_unknown_keys(vehicle_dict, VEHICLE_KEYS, "vehicle %s" % vehicle_name, errors)
        if not vehicle_dict.has("VehicleType") or typeof(vehicle_dict["VehicleType"]) != TYPE_STRING or not SUPPORTED_VEHICLE_TYPES.has(vehicle_dict["VehicleType"]):
            errors.append("Vehicles.%s.VehicleType must be SimpleFlight or PX4Multirotor" % vehicle_name)
        for collection_name in ["Cameras", "Sensors"]:
            if not vehicle_dict.has(collection_name):
                continue
            if typeof(vehicle_dict[collection_name]) != TYPE_DICTIONARY:
                errors.append("Vehicles.%s.%s must be an object" % [vehicle_name, collection_name])
                continue
            var allowed := CAMERA_KEYS if collection_name == "Cameras" else SENSOR_KEYS
            _validate_named_entries(vehicle_dict[collection_name], allowed, "vehicle %s %s" % [vehicle_name, collection_name], errors)


static func _validate_named_entries(value: Dictionary, allowed: Dictionary, scope: String, errors: Array[String]) -> void:
    for entry_name in value:
        var entry = value[entry_name]
        if typeof(entry) != TYPE_DICTIONARY:
            errors.append("%s.%s must be an object" % [scope, entry_name])
            continue
        _reject_unknown_keys(entry, allowed, "%s.%s" % [scope, entry_name], errors)


static func _validate_subwindows(raw: Dictionary, errors: Array[String]) -> void:
    if not raw.has("SubWindows"):
        return
    if typeof(raw["SubWindows"]) != TYPE_ARRAY:
        errors.append("SubWindows must be an array")
        return
    for index in raw["SubWindows"].size():
        var subwindow = raw["SubWindows"][index]
        if typeof(subwindow) != TYPE_DICTIONARY:
            errors.append("SubWindows[%d] must be an object" % index)
            continue
        var value: Dictionary = subwindow
        _reject_unknown_keys(value, SUBWINDOW_KEYS, "SubWindows[%d]" % index, errors)
        if value.has("WindowID") and typeof(value["WindowID"]) != TYPE_INT:
            errors.append("SubWindows[%d].WindowID must be an integer" % index)
        if value.has("ImageType") and typeof(value["ImageType"]) != TYPE_INT:
            errors.append("SubWindows[%d].ImageType must be an integer" % index)
        for key in ["Visible", "External"]:
            if value.has(key) and typeof(value[key]) != TYPE_BOOL:
                errors.append("SubWindows[%d].%s must be boolean" % [index, key])
        for key in ["CameraName", "VehicleName"]:
            if value.has(key) and typeof(value[key]) != TYPE_STRING:
                errors.append("SubWindows[%d].%s must be a string" % [index, key])
        if value.has("CameraID") and typeof(value["CameraID"]) != TYPE_INT:
            errors.append("SubWindows[%d].CameraID must be an integer" % index)


static func _validate_recording(raw: Dictionary, errors: Array[String]) -> void:
    if not raw.has("Recording"):
        return
    if typeof(raw["Recording"]) != TYPE_DICTIONARY:
        errors.append("Recording must be an object")
        return
    var recording: Dictionary = raw["Recording"]
    _reject_unknown_keys(recording, RECORDING_KEYS, "Recording", errors)
    for key in ["RecordOnMove", "Enabled"]:
        if recording.has(key) and typeof(recording[key]) != TYPE_BOOL:
            errors.append("Recording.%s must be boolean" % key)
    if recording.has("RecordInterval") and (typeof(recording["RecordInterval"]) not in [TYPE_INT, TYPE_FLOAT] or float(recording["RecordInterval"]) < 0.0):
        errors.append("Recording.RecordInterval must be a non-negative number")
    if recording.has("Folder") and typeof(recording["Folder"]) != TYPE_STRING:
        errors.append("Recording.Folder must be a string")
