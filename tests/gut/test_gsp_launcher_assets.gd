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
    assert_true(FileAccess.file_exists(bundle.path_join("assets/THREE-LICENSE")))
    assert_true(FileAccess.file_exists(bundle.path_join("assets/asset_notes.md")))

    launcher.free()
