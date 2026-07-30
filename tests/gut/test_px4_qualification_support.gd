extends GutTest

const QualificationSupport = preload("res://tests/headless/px4_qualification_support.gd")


func test_smoke_base_has_no_static_ground_collider() -> void:
    var source := FileAccess.get_file_as_string("res://levels/smoke/smoke.tscn")
    assert_string_contains(source, "[node name=\"GroundPlane\" type=\"MeshInstance3D\" parent=\".\"]")
    assert_false(source.contains("[node name=\"GroundCollision\" type=\"StaticBody3D\" parent=\".\"]"))
    assert_false(source.contains("QualificationGroundSupport"))


func test_qualification_support_is_a_fixed_static_ground_at_drone_one_spawn_surface() -> void:
    var root := Node3D.new()
    add_child_autofree(root)
    var support: StaticBody3D = QualificationSupport.install(root)

    assert_eq(support.name, "QualificationGroundSupport")
    assert_eq(support.position, Vector3(0.0, QualificationSupport.CENTER_Y_M, 0.0))
    assert_eq(support.physics_material_override.friction, QualificationSupport.FRICTION)
    assert_eq(support.physics_material_override.bounce, QualificationSupport.BOUNCE)
    var collider := support.get_node_or_null("CollisionShape3D") as CollisionShape3D
    assert_not_null(collider)
    assert_true(collider.shape is BoxShape3D)
    assert_eq((collider.shape as BoxShape3D).size, QualificationSupport.SIZE_M)
    assert_almost_eq(
        QualificationSupport.CENTER_Y_M + QualificationSupport.SIZE_M.y * 0.5,
        QualificationSupport.DRONE_SPAWN_CENTER_Y_M - QualificationSupport.DRONE_RADIUS_M,
        0.000001
    )
