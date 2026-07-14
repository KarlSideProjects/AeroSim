extends GutTest

const MsgpackCodec = preload("res://common/rpc/msgpack_codec.gd")


func test_round_trips_msgpack_rpc_request_values() -> void:
    var request := [0, 7, "ping", []]
    var decoded: Dictionary = MsgpackCodec.decode(MsgpackCodec.encode(request))

    assert_true(decoded.ok)
    assert_eq(decoded.value, request)


func test_round_trips_nested_maps_arrays_and_scalars() -> void:
    var value := {
        "ok": true,
        "count": 3,
        "temperature": 21.5,
        "payload": [null, "AeroSim", {"frame": 12}]
    }
    var decoded: Dictionary = MsgpackCodec.decode(MsgpackCodec.encode(value))

    assert_true(decoded.ok)
    assert_eq(decoded.value, value)


func test_incomplete_frame_is_reported_without_consuming_partial_data() -> void:
    var encoded: PackedByteArray = MsgpackCodec.encode([1, 3, null, true])
    encoded.resize(encoded.size() - 1)
    var decoded: Dictionary = MsgpackCodec.decode(encoded)

    assert_false(decoded.ok)
    assert_true(decoded.incomplete)


func test_packed_float32_arrays_use_msgpack_float32_values() -> void:
    var encoded: PackedByteArray = MsgpackCodec.encode(PackedFloat32Array([1.0, 2.0]))

    assert_true(encoded.has(0xca))
    assert_false(encoded.has(0xcb))
    var decoded: Dictionary = MsgpackCodec.decode(encoded)
    assert_true(decoded.ok)
    assert_eq(decoded.value, [1.0, 2.0])
