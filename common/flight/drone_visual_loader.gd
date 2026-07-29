extends Node3D

const Localization = preload("res://common/flight/localization.gd")
const MODEL_PATH := "res://assets/third_party/free3d_drone/drone_costum_godot.scn"
const MODEL_SCALE := Vector3(0.03, 0.03, 0.03)
const LOAD_FAILURE_KEY := "ui.error.drone_model_load_failed"

@export_file("*.scn") var model_path := MODEL_PATH
@export var show_load_failure := true

var model_loaded := false
var load_error := ""

func _ready() -> void:
    _load_model()

func _load_model() -> void:
    var model_scene := load(model_path) as PackedScene
    if model_scene == null:
        load_error = "Drone model unavailable: %s" % model_path
        _show_load_failure()
        return

    var model := model_scene.instantiate()
    model.name = "ImportedDroneModel"
    model.scale = MODEL_SCALE
    # No rotation belongs here. At this scale the airframe measures 0.372 along body X,
    # 0.263 along body Z, so its long axis already lies on the body's +X forward axis; a
    # 90 degree turn swaps those to 0.263 x 0.372 and lays it across the flight path.
    # An earlier +90 degrees was applied on the false premise that the nose ran along
    # local +Z. Because pitch rotates about body Z, that made a forward stick spin the
    # visible model about its own long axis, reading as the aircraft turning rather than
    # moving forward. Guarded by test_imported_drone_nose_aligns_with_the_frd_forward_axis.
    add_child(model)
    model_loaded = true
    var fallback_mesh := get_parent().get_node_or_null("DroneMesh") as MeshInstance3D
    if fallback_mesh != null:
        fallback_mesh.visible = false
    var status := get_node_or_null("../../VisualLoadStatus") as Label3D
    if status != null:
        status.visible = false

func _show_load_failure() -> void:
    var status := get_node_or_null("../../VisualLoadStatus") as Label3D
    if status != null:
        status.visible = show_load_failure
        status.text = Localization.translate(LOAD_FAILURE_KEY)
