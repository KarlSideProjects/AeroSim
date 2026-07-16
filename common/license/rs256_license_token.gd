extends RefCounted

const ISSUER := "urn:aerosim:license-server"
const AUDIENCE := "urn:aerosim:ubuntu-client"
const TOKEN_TTL_SECONDS := 259200
const MAX_FUTURE_IAT_SECONDS := 300


static func verify(token: String, public_key_path: String, allowed_kids: Array, now: int) -> Dictionary:
    var parts := token.split(".")
    if parts.size() != 3:
        return _invalid("parts")

    var header_bytes: Variant = _decode_base64url(parts[0])
    var payload_bytes: Variant = _decode_base64url(parts[1])
    var signature: Variant = _decode_base64url(parts[2])
    if header_bytes == null or payload_bytes == null or signature == null:
        return _invalid("base64")

    var header: Variant = JSON.parse_string(header_bytes.get_string_from_utf8())
    if typeof(header) != TYPE_DICTIONARY or header.size() != 3:
        return _invalid("header shape")
    if typeof(header["alg"]) != TYPE_STRING or header["alg"] != "RS256":
        return _invalid("alg")
    if typeof(header["typ"]) != TYPE_STRING or header["typ"] != "aerosim-license+jwt":
        return _invalid("typ")
    if typeof(header["kid"]) != TYPE_STRING or not allowed_kids.has(header["kid"]):
        return _invalid("kid")

    var payload_json: String = payload_bytes.get_string_from_utf8()
    var claims: Variant = JSON.parse_string(payload_json)
    if typeof(claims) != TYPE_DICTIONARY or claims.size() != 6:
        return _invalid("claims shape")
    if claims["iss"] != ISSUER or claims["aud"] != AUDIENCE:
        return _invalid("issuer audience")
    if typeof(claims["sub"]) != TYPE_STRING or not _is_uuid(claims["sub"]):
        return _invalid("sub")
    if typeof(claims["jti"]) != TYPE_STRING or not _is_uuid(claims["jti"]):
        return _invalid("jti")
    if not _is_integer_claim(payload_json, "iat") or not _is_integer_claim(payload_json, "exp"):
        return _invalid()
    var iat := int(claims["iat"])
    var exp := int(claims["exp"])
    if exp - iat != TOKEN_TTL_SECONDS:
        return _invalid()
    if now >= exp or iat > now + MAX_FUTURE_IAT_SECONDS:
        return _invalid()

    var key := CryptoKey.new()
    if key.load(public_key_path, true) != OK:
        return _invalid()
    var crypto := Crypto.new()
    var signing_input := "%s.%s" % [parts[0], parts[1]]
    if not crypto.verify(HashingContext.HASH_SHA256, signing_input.sha256_buffer(), signature, key):
        return _invalid()
    var verified_claims: Dictionary = claims.duplicate()
    verified_claims["iat"] = iat
    verified_claims["exp"] = exp
    return {"ok": true, "claims": verified_claims}


static func _decode_base64url(segment: String) -> Variant:
    if segment.is_empty() or segment.contains("=") or segment.length() % 4 == 1:
        return null
    var regex := RegEx.new()
    regex.compile("^[A-Za-z0-9_-]+$")
    if regex.search(segment) == null:
        return null
    var normalized := segment.replace("-", "+").replace("_", "/")
    normalized += "=".repeat((4 - normalized.length() % 4) % 4)
    var decoded := Marshalls.base64_to_raw(normalized)
    var canonical := Marshalls.raw_to_base64(decoded).replace("+", "-").replace("/", "_").trim_suffix("=").trim_suffix("=")
    if canonical != segment:
        return null
    return decoded


static func _is_uuid(value: String) -> bool:
    var regex := RegEx.new()
    regex.compile("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
    return regex.search(value) != null


static func _is_integer_claim(json: String, claim_name: String) -> bool:
    var depth := 0
    var index := 0
    while index < json.length():
        var character := json[index]
        if character == "\"":
            var start := index + 1
            index += 1
            while index < json.length():
                if json[index] == "\\":
                    index += 2
                elif json[index] == "\"":
                    var value := json.substr(start, index - start)
                    index += 1
                    if depth == 1 and value == claim_name:
                        while index < json.length() and _is_json_space(json[index]):
                            index += 1
                        if index >= json.length() or json[index] != ":":
                            return false
                        index += 1
                        while index < json.length() and _is_json_space(json[index]):
                            index += 1
                        if index < json.length() and json[index] == "-":
                            index += 1
                        var digits := index
                        while index < json.length() and json[index] >= "0" and json[index] <= "9":
                            index += 1
                        if digits == index:
                            return false
                        while index < json.length() and _is_json_space(json[index]):
                            index += 1
                        return index < json.length() and ",}".contains(json[index])
                    break
                index += 1
            continue
        if character == "{":
            depth += 1
        elif character == "}":
            depth -= 1
        index += 1
    return false


static func _is_json_space(character: String) -> bool:
    return " \t\r\n".contains(character)


static func _invalid(_reason: String = "") -> Dictionary:
    return {"ok": false, "error": "invalid token"}
