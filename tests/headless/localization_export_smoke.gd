extends SceneTree

const Localization = preload("res://common/flight/localization.gd")


func _initialize() -> void:
    if not Localization.catalog_ready():
        push_error("exported localization catalog is unavailable")
        quit(1)
        return
    if not Localization.set_locale("zh_TW") or Localization.translate("ui.settings") != "設定":
        push_error("exported Traditional Chinese localization failed")
        quit(1)
        return
    print("exported localization smoke passed")
    quit(0)
