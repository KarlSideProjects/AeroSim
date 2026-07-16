extends SceneTree

const TokenVerifier = preload("res://common/license/rs256_license_token.gd")


func _init() -> void:
    var input_path := ""
    var output_path := ""
    var args := OS.get_cmdline_user_args()
    for index in range(args.size() - 1):
        if args[index] == "--input":
            input_path = args[index + 1]
        elif args[index] == "--output":
            output_path = args[index + 1]

    var failures: Array[String] = []
    if input_path.is_empty() or output_path.is_empty():
        failures.append("--input and --output are required")
    else:
        var input: Variant = JSON.parse_string(FileAccess.get_file_as_string(input_path))
        if not input is Dictionary:
            failures.append("input is not a JSON object")
        else:
            for test_case in input.cases:
                var result: Dictionary = TokenVerifier.verify(
                    test_case.token,
                    input.public_key_path,
                    input.allowed_kids,
                    input.now
                )
                var expected_valid := bool(test_case.valid)
                if bool(result.get("ok", false)) != expected_valid:
                    failures.append("%s: expected valid=%s, got %s (%s)" % [
                        test_case.name,
                        expected_valid,
                        result.get("ok", false),
                        result.get("error", "")
                    ])
                elif expected_valid:
                    var expected_claims: Dictionary = test_case.claims.duplicate()
                    expected_claims["iat"] = int(expected_claims["iat"])
                    expected_claims["exp"] = int(expected_claims["exp"])
                    if result.get("claims") != expected_claims:
                        failures.append("%s: claims changed during verification" % test_case.name)

    var output := {"ok": failures.is_empty(), "failures": failures}
    var file := FileAccess.open(output_path, FileAccess.WRITE)
    if file == null:
        push_error("could not write harness output")
        quit(1)
        return
    file.store_string(JSON.stringify(output))
    file.close()
    if not failures.is_empty():
        push_error(JSON.stringify(output))
    quit(0 if failures.is_empty() else 1)
