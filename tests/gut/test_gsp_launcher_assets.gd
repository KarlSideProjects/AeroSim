extends GutTest

const GspLauncher = preload("res://common/gsp/gsp_launcher.gd")


func test_install_panel_copies_every_declared_asset() -> void:
    var launcher := GspLauncher.new()
    var root := "user://aerosim-gsp-assets-%d" % Time.get_ticks_usec()
    var installed: Dictionary = launcher.install_panel(root)

    assert_true(bool(installed.get("ok", false)), String(installed.get("error", "panel install failed")))
    var bundle := String(installed.get("path", "")).get_base_dir()
    for source_path in GspLauncher.PANEL_ASSET_PATHS:
        var installed_asset := bundle.path_join("assets").path_join(String(source_path).get_file())
        assert_true(FileAccess.file_exists(installed_asset), "missing installed panel asset: %s" % installed_asset)
    assert_true(FileAccess.file_exists(bundle.path_join("assets/three-0.180.0.global.min.js")))
    assert_true(FileAccess.file_exists(bundle.path_join("assets/gsp_drone_geometry.js")))

    launcher.free()


func test_installed_geometry_asset_matches_the_recorded_provenance_hash() -> void:
    var HardwareConfig := load("res://common/flight/hardware_config.gd")
    var loader = HardwareConfig.new()
    var preset: Dictionary = loader.load_preset("res://config/drones/5_inch_6s.json")
    assert_true(loader.last_ok, loader.last_error)

    var launcher := GspLauncher.new()
    var installed: Dictionary = launcher.install_panel("user://aerosim-gsp-geometry-%d" % Time.get_ticks_usec())
    assert_true(bool(installed.get("ok", false)), String(installed.get("error", "panel install failed")))
    var bundle := String(installed.get("path", "")).get_base_dir()

    for asset in preset.geometry.provenance.assets:
        var installed_path := bundle.path_join("assets").path_join(String(asset.path).get_file())
        assert_true(FileAccess.file_exists(installed_path), "geometry asset is not in the bundle: %s" % asset.path)
        var file := FileAccess.open(installed_path, FileAccess.READ)
        var context := HashingContext.new()
        context.start(HashingContext.HASH_SHA256)
        context.update(file.get_buffer(file.get_length()))
        file.close()
        assert_eq(context.finish().hex_encode(), String(asset.sha256),
            "installed geometry asset does not match the recorded provenance hash")

    launcher.free()
