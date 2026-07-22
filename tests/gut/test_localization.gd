extends GutTest

const LanguageProfile = preload("res://common/flight/language_profile.gd")
const Localization = preload("res://common/flight/localization.gd")


func after_each() -> void:
    Localization.set_locale(LanguageProfile.DEFAULT_LOCALE)


func test_language_profile_accepts_only_supported_locales() -> void:
    var accepted := LanguageProfile.validate_profile({
        "schema_version": LanguageProfile.SCHEMA_VERSION,
        "locale": "zh_TW",
    })
    var rejected := LanguageProfile.validate_profile({
        "schema_version": LanguageProfile.SCHEMA_VERSION,
        "locale": "fr",
    })

    assert_true(accepted.ok, accepted.error)
    assert_eq(accepted.profile.locale, "zh_TW")
    assert_false(rejected.ok)
    assert_string_contains(rejected.error, "locale")

    var unknown_field := LanguageProfile.validate_profile({"locale": "en", "debug": true})
    assert_false(unknown_field.ok)
    assert_string_contains(unknown_field.error, "fields")


func test_translation_catalog_has_english_and_traditional_chinese() -> void:
    assert_true(Localization.catalog_ready())
    assert_true(Localization.set_locale("en"))
    var english := Localization.translate("ui.settings")
    assert_true(Localization.set_locale("zh_TW"))
    var traditional_chinese := Localization.translate("ui.settings")

    assert_eq(english, "SETTINGS")
    assert_eq(traditional_chinese, "設定")
    assert_ne(english, traditional_chinese)


func test_formatted_translation_preserves_dynamic_values() -> void:
    Localization.set_locale("zh_TW")

    var rendered := Localization.format("ui.render_scale", [75])

    assert_eq(rendered, "渲染比例：75%")
