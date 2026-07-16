extends GutTest

const LicenseProviderScript = preload("res://common/license/license_provider.gd")

var state_path := "user://aerosim-license-provider-test.json"
var providers: Array[Node] = []


func after_each() -> void:
    for provider in providers:
        provider.free()
    providers.clear()
    DirAccess.remove_absolute(state_path)
    DirAccess.remove_absolute("%s.tmp" % state_path)


func _provider() -> Node:
    var provider: Node = LicenseProviderScript.new()
    add_child(provider)
    providers.append(provider)
    return provider


func _config() -> Dictionary:
    return {
        "schema_version": 1,
        "issue_endpoint": "https://license.example.test/issue",
        "verify_endpoint": "https://license.example.test/verify",
        "public_key_path": "res://config/license_public_key.pem",
        "allowed_kids": ["ubuntu-2026"],
        "state_path": state_path,
    }


func _write_state(text: String) -> void:
    var file := FileAccess.open(state_path, FileAccess.WRITE)
    file.store_string(text)
    file.close()
    if OS.has_feature("linux"):
        assert_eq(FileAccess.set_unix_permissions(state_path, 384), OK)


func test_endpoint_policy_is_numeric_loopback_or_https_only() -> void:
    var provider := _provider()
    for endpoint in [
        "http://localhost:8080/issue",
        "http://0.0.0.0:8080/issue",
        "http://127.0.0.2:8080/issue",
        "http://user:pass@127.0.0.1:8080/issue",
        "http://127.0.0.1:8080/issue#fragment",
        "http://[::2]:8080/issue",
    ]:
        assert_false(provider._validate_endpoint(endpoint).ok, endpoint)
    assert_true(provider._validate_endpoint("https://license.example.test/issue").ok)
    assert_true(provider._validate_endpoint("http://127.0.0.1:8080/issue").ok)
    assert_true(provider._validate_endpoint("http://[::1]:8080/issue").ok)


func test_missing_state_is_not_activated_and_snapshot_is_redacted() -> void:
    var provider := _provider()
    assert_true(provider.configure(_config()).ok)
    var snapshot: Dictionary = provider.get_snapshot()
    assert_eq(snapshot.status, "not_activated")
    for secret_field in ["jwt", "token", "claims", "sub", "jti", "license_key", "secret"]:
        assert_false(snapshot.has(secret_field), secret_field)


func test_corrupt_state_is_fatal() -> void:
    _write_state("{not-json")
    var provider := _provider()
    var configured: Dictionary = provider.configure(_config())
    assert_false(configured.ok)
    assert_eq(configured.error_type, "fatal")
    assert_eq(provider.get_snapshot().status, "invalid_token")


func test_state_with_wrong_permissions_is_fatal() -> void:
    if not OS.has_feature("linux"):
        pass_test("0600 is Linux-specific")
        return
    _write_state(JSON.stringify({
        "schema_version": 1,
        "jwt": "",
        "max_observed_utc": 0,
        "session_anchor_utc": 0,
        "revoked": false,
    }))
    assert_eq(FileAccess.set_unix_permissions(state_path, 420), OK)
    var provider := _provider()
    var configured: Dictionary = provider.configure(_config())
    assert_false(configured.ok)
    assert_eq(configured.error_code, "state_permissions_invalid")


func test_token_without_session_anchor_is_fatal() -> void:
    _write_state(JSON.stringify({
        "schema_version": 1,
        "jwt": "redacted-test-token",
        "max_observed_utc": 1700000000,
        "session_anchor_utc": 0,
        "revoked": false,
    }))
    var provider := _provider()
    var configured: Dictionary = provider.configure(_config())
    assert_false(configured.ok)
    assert_eq(configured.error_code, "missing_session_anchor")


func test_local_revocation_is_persisted_and_dominates_snapshot() -> void:
    var provider := _provider()
    assert_true(provider.configure(_config()).ok)
    assert_true(provider.revoke_local().ok)
    assert_eq(provider.get_snapshot().status, "revoked")
