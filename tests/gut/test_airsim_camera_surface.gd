extends GutTest

const AirSimCameraSurface = preload("res://common/rpc/airsim_camera_surface.gd")


func test_camera_surface_freezes_supported_types_and_rejects_other_ground_truth() -> void:
    var surface := AirSimCameraSurface.new()
    autofree(surface)

    for image_type in [0, 5]:
        var valid := surface._validate_request({
            "camera_name": "0",
            "image_type": image_type,
            "pixels_as_float": false,
            "compress": true,
        })
        assert_true(valid.ok)
    var depth := surface._validate_request({
        "camera_name": "0",
        "image_type": 1,
        "pixels_as_float": true,
        "compress": false,
    })
    assert_true(depth.ok)

    var depth_bytes := surface._validate_request({
        "camera_name": "0",
        "image_type": 1,
        "pixels_as_float": false,
        "compress": true,
    })
    assert_false(depth_bytes.ok)
    assert_string_contains(depth_bytes.error, "pixels_as_float=true")

    var unsupported := surface._validate_request({
        "camera_name": "0",
        "image_type": 3,
        "pixels_as_float": false,
        "compress": true,
    })
    assert_false(unsupported.ok)
    assert_string_contains(unsupported.error, "unsupported image type")


func test_segmentation_catalog_ids_are_stable_and_unique() -> void:
    var surface := AirSimCameraSurface.new()
    autofree(surface)
    var catalog: Array = surface.catalog_metadata()
    var ids := {}
    for item in catalog:
        assert_false(ids.has(item.segmentation_id))
        ids[item.segmentation_id] = item.path
    assert_eq(catalog.size(), 7)
    var blue_found := false
    for item in catalog:
        if int(item["segmentation_id"]) == 3:
            blue_found = true
            assert_eq(String(item["path"]), "CargoContainers/ContainerBlue")
    assert_true(blue_found)
