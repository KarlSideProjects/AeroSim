extends Node3D

const MODEL_PATH := "res://assets/third_party/free3d_drone/drone_costum_godot.scn"
const MODEL_SCALE := Vector3(0.03, 0.03, 0.03)

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
        status.text = "DRONE MODEL LOAD FAILED\nFALLBACK MESH ACTIVE"
