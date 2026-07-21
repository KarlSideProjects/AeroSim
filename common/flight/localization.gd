class_name Localization
extends RefCounted

const LanguageProfile = preload("res://common/flight/language_profile.gd")

static var current_locale := LanguageProfile.DEFAULT_LOCALE
static var _catalog_loaded := false


static func set_locale(locale: String) -> bool:
    if not LanguageProfile.SUPPORTED_LOCALES.has(locale):
        return false
    _ensure_catalog()
    if not _catalog_loaded:
        return false
    current_locale = locale
    TranslationServer.set_locale(locale)
    return true


static func translate(key: String) -> String:
    _ensure_catalog()
    return TranslationServer.translate(key)


static func format(key: String, values: Array = []) -> String:
    var translated := translate(key)
    return translated % values if not values.is_empty() else translated


static func catalog_ready() -> bool:
    _ensure_catalog()
    return _catalog_loaded


static func _ensure_catalog() -> void:
    if _catalog_loaded:
        return
    var imported_translations_loaded := true
    for locale in LanguageProfile.SUPPORTED_LOCALES:
        var imported := ResourceLoader.load("res://locales/ui.%s.translation" % locale)
        if imported is Translation:
            TranslationServer.add_translation(imported)
        else:
            imported_translations_loaded = false
            break
    if imported_translations_loaded:
        _catalog_loaded = true
        return
    var file := FileAccess.open("res://locales/ui.csv", FileAccess.READ)
    if file == null:
        push_error("UI localization catalog is unavailable in the exported project")
        return
    var translations: Dictionary = {}
    for locale in LanguageProfile.SUPPORTED_LOCALES:
        var translation := Translation.new()
        translation.locale = locale
        translations[locale] = translation
    while not file.eof_reached():
        var row := file.get_csv_line()
        if row.size() < 3 or row[0] == "keys" or row[0].is_empty():
            continue
        for index in LanguageProfile.SUPPORTED_LOCALES.size():
            translations[LanguageProfile.SUPPORTED_LOCALES[index]].add_message(row[0], row[index + 1])
    file.close()
    for locale in LanguageProfile.SUPPORTED_LOCALES:
        TranslationServer.add_translation(translations[locale])
    _catalog_loaded = true
