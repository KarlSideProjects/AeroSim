extends SceneTree

func _initialize() -> void:
    var native: Object = ClassDB.instantiate("AeroSimNative")
    if native == null:
        push_error("AeroSimNative is not registered")
        quit(2)
        return
    native.call("step_external_motor_outputs", 240, 1000, PackedFloat64Array([0.0, 0.0, 0.0]))
    quit(0)
