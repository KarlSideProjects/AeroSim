extends GutTest

const SceneObjectCatalog = preload("res://common/rpc/scene_object_catalog.gd")


func test_catalog_rejects_unknown_fields_and_missing_provenance() -> void:
    var result := SceneObjectCatalog.validate_catalog({
        "version": 1,
        "objects": [{
            "id": "crate_blue",
            "resource": "primitive_box",
            "license": "project-created",
            "segmentation_id": 8,
            "size": [1.0, 1.0, 1.0],
            "future": true,
        }],
    })

    assert_false(result.ok)
    assert_string_contains(result.error, "provenance")
    assert_string_contains(result.error, "future")


func test_catalog_creates_moves_queries_and_destroys_known_object_deterministically() -> void:
    var catalog := SceneObjectCatalog.new()
    autofree(catalog)
    assert_true(catalog.load_from_dictionary({
        "version": 1,
        "objects": [{
            "id": "crate_blue",
            "resource": "primitive_box",
            "provenance": "AeroSim project-created primitive",
            "license": "AeroSim proprietary",
            "segmentation_id": 8,
            "size": [1.0, 1.0, 1.0],
            "collision": true,
            "mobility": "movable",
            "destroyable": true,
            "bounds": {"min": [-2.0, 0.0, -2.0], "max": [2.0, 2.0, 2.0]},
        }],
    }).ok)

    var created := catalog.create_named("crate_a", "crate_blue", Vector3(0.0, 0.5, 0.0))
    assert_true(created.ok)
    assert_eq(catalog.list_named(), ["crate_a"])
    assert_eq(catalog.query_named("crate_a").object.segmentation_id, 8)
    var body := catalog.get_node("crate_a") as StaticBody3D
    assert_not_null(body)
    assert_true(body.get_node("CollisionShape3D") is CollisionShape3D)
    assert_true(body.get_node("MeshInstance3D") is MeshInstance3D)
    assert_eq(body.get_meta("airsim_segmentation_id"), 8)

    var orientation := Quaternion(0.0, sin(PI / 4.0), 0.0, cos(PI / 4.0))
    var moved := catalog.move_named("crate_a", Vector3(1.0, 0.5, -1.0), orientation)
    assert_true(moved.ok)
    assert_eq(catalog.query_named("crate_a").object.position, Vector3(1.0, 0.5, -1.0))
    assert_true(absf(catalog.query_named("crate_a").object.orientation.y - orientation.y) < 0.0001)
    assert_true(catalog.destroy_named("crate_a").ok)
    assert_eq(catalog.list_named(), [])


func test_catalog_rejects_duplicate_names_unknown_assets_and_out_of_bounds_transforms() -> void:
    var catalog := SceneObjectCatalog.new()
    autofree(catalog)
    assert_true(catalog.load_from_dictionary({
        "version": 1,
        "objects": [{
            "id": "crate_blue",
            "resource": "primitive_box",
            "provenance": "AeroSim project-created primitive",
            "license": "AeroSim proprietary",
            "segmentation_id": 8,
            "size": [1.0, 1.0, 1.0],
            "collision": true,
            "mobility": "movable",
            "destroyable": true,
            "bounds": {"min": [-1.0, 0.0, -1.0], "max": [1.0, 1.0, 1.0]},
        }],
    }).ok)

    assert_true(catalog.create_named("crate_a", "crate_blue", Vector3.ZERO).ok)
    assert_false(catalog.create_named("crate_a", "crate_blue", Vector3.ZERO).ok)
    assert_false(catalog.create_named("crate_b", "missing", Vector3.ZERO).ok)
    assert_false(catalog.move_named("crate_a", Vector3(2.0, 0.5, 0.0)).ok)
