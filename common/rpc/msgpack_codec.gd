class_name MsgpackCodec
extends RefCounted


static func encode(value: Variant) -> PackedByteArray:
    var output := PackedByteArray()
    _encode_value(value, output)
    return output


static func decode(data: PackedByteArray) -> Dictionary:
    var reader := _Reader.new(data)
    var value = reader.read_value()
    if reader.incomplete:
        return {"ok": false, "incomplete": true, "error": "incomplete MessagePack value"}
    if not reader.error.is_empty():
        return {"ok": false, "incomplete": false, "error": reader.error}
    return {"ok": true, "incomplete": false, "value": value, "consumed": reader.offset}


static func _encode_value(value: Variant, output: PackedByteArray) -> void:
    match typeof(value):
        TYPE_NIL:
            output.append(0xc0)
        TYPE_BOOL:
            output.append(0xc3 if value else 0xc2)
        TYPE_INT:
            _encode_integer(int(value), output)
        TYPE_FLOAT:
            output.append(0xcb)
            _append_float64(float(value), output)
        TYPE_PACKED_FLOAT32_ARRAY:
            _encode_float32_array(value, output)
        TYPE_STRING:
            _encode_string(String(value), output)
        TYPE_ARRAY:
            _encode_array(value, output)
        TYPE_DICTIONARY:
            _encode_dictionary(value, output)
        _:
            output.append(0xc0)


static func _encode_integer(value: int, output: PackedByteArray) -> void:
    if value >= 0 and value <= 0x7f:
        output.append(value)
    elif value < 0 and value >= -32:
        output.append(256 + value)
    elif value >= 0 and value <= 0xff:
        output.append(0xcc)
        output.append(value)
    elif value >= 0 and value <= 0xffff:
        output.append(0xcd)
        _append_u16(value, output)
    elif value >= 0 and value <= 0xffffffff:
        output.append(0xce)
        _append_u32(value, output)
    elif value >= 0:
        output.append(0xcf)
        _append_u64(value, output)
    elif value >= -128:
        output.append(0xd0)
        output.append(value & 0xff)
    elif value >= -32768:
        output.append(0xd1)
        _append_u16(value & 0xffff, output)
    elif value >= -2147483648:
        output.append(0xd2)
        _append_u32(value & 0xffffffff, output)
    else:
        output.append(0xd3)
        _append_u64(value, output)


static func _encode_string(value: String, output: PackedByteArray) -> void:
    var bytes := value.to_utf8_buffer()
    var length := bytes.size()
    if length < 32:
        output.append(0xa0 | length)
    elif length <= 0xff:
        output.append(0xd9)
        output.append(length)
    elif length <= 0xffff:
        output.append(0xda)
        _append_u16(length, output)
    else:
        output.append(0xdb)
        _append_u32(length, output)
    output.append_array(bytes)


static func _encode_array(value: Array, output: PackedByteArray) -> void:
    var length := value.size()
    if length < 16:
        output.append(0x90 | length)
    elif length <= 0xffff:
        output.append(0xdc)
        _append_u16(length, output)
    else:
        output.append(0xdd)
        _append_u32(length, output)
    for item in value:
        _encode_value(item, output)


static func _encode_float32_array(value: PackedFloat32Array, output: PackedByteArray) -> void:
    var length := value.size()
    if length < 16:
        output.append(0x90 | length)
    elif length <= 0xffff:
        output.append(0xdc)
        _append_u16(length, output)
    else:
        output.append(0xdd)
        _append_u32(length, output)
    for item in value:
        output.append(0xca)
        _append_float32(float(item), output)


static func _encode_dictionary(value: Dictionary, output: PackedByteArray) -> void:
    var keys := value.keys()
    var length := keys.size()
    if length < 16:
        output.append(0x80 | length)
    elif length <= 0xffff:
        output.append(0xde)
        _append_u16(length, output)
    else:
        output.append(0xdf)
        _append_u32(length, output)
    for key in keys:
        _encode_value(key, output)
        _encode_value(value[key], output)


static func _append_u16(value: int, output: PackedByteArray) -> void:
    output.append((value >> 8) & 0xff)
    output.append(value & 0xff)


static func _append_u32(value: int, output: PackedByteArray) -> void:
    output.append((value >> 24) & 0xff)
    output.append((value >> 16) & 0xff)
    output.append((value >> 8) & 0xff)
    output.append(value & 0xff)


static func _append_u64(value: int, output: PackedByteArray) -> void:
    for shift in [56, 48, 40, 32, 24, 16, 8, 0]:
        output.append((value >> shift) & 0xff)


static func _append_float64(value: float, output: PackedByteArray) -> void:
    var buffer := StreamPeerBuffer.new()
    buffer.big_endian = true
    buffer.put_double(value)
    output.append_array(buffer.data_array)


static func _append_float32(value: float, output: PackedByteArray) -> void:
    var buffer := StreamPeerBuffer.new()
    buffer.big_endian = true
    buffer.put_float(value)
    output.append_array(buffer.data_array)


class _Reader extends RefCounted:
    var data: PackedByteArray
    var offset: int = 0
    var incomplete: bool = false
    var error: String = ""

    func _init(input: PackedByteArray) -> void:
        data = input

    func read_value():
        var prefix = _read_u8()
        if _failed():
            return null
        if prefix <= 0x7f:
            return prefix
        if prefix >= 0xe0:
            return prefix - 256
        if prefix >= 0xa0 and prefix <= 0xbf:
            return _read_string(prefix - 0xa0)
        if prefix >= 0x90 and prefix <= 0x9f:
            return _read_array(prefix - 0x90)
        if prefix >= 0x80 and prefix <= 0x8f:
            return _read_map(prefix - 0x80)
        match prefix:
            0xc0:
                return null
            0xc2:
                return false
            0xc3:
                return true
            0xcc:
                return _read_u8()
            0xcd:
                return _read_unsigned(2)
            0xce:
                return _read_unsigned(4)
            0xcf:
                return _read_unsigned(8)
            0xd0:
                return _signed(_read_unsigned(1), 8)
            0xd1:
                return _signed(_read_unsigned(2), 16)
            0xd2:
                return _signed(_read_unsigned(4), 32)
            0xd3:
                return _signed(_read_unsigned(8), 64)
            0xca:
                return _read_float(4)
            0xcb:
                return _read_float(8)
            0xd9:
                return _read_string(_read_unsigned(1))
            0xda:
                return _read_string(_read_unsigned(2))
            0xdb:
                return _read_string(_read_unsigned(4))
            0xdc:
                return _read_array(_read_unsigned(2))
            0xdd:
                return _read_array(_read_unsigned(4))
            0xde:
                return _read_map(_read_unsigned(2))
            0xdf:
                return _read_map(_read_unsigned(4))
            _:
                error = "unsupported MessagePack marker 0x%02x" % prefix
                return null

    func _read_u8():
        if offset >= data.size():
            incomplete = true
            return 0
        var value := data[offset]
        offset += 1
        return value

    func _read_unsigned(byte_count: int):
        if offset + byte_count > data.size():
            incomplete = true
            return 0
        var value: int = 0
        for index in byte_count:
            value = (value << 8) | data[offset + index]
        offset += byte_count
        return value

    func _read_float(byte_count: int):
        var bytes := _read_bytes(byte_count)
        if _failed():
            return 0.0
        var buffer := StreamPeerBuffer.new()
        buffer.big_endian = true
        buffer.data_array = bytes
        return buffer.get_float() if byte_count == 4 else buffer.get_double()

    func _read_string(length: int):
        var bytes := _read_bytes(length)
        if _failed():
            return ""
        return bytes.get_string_from_utf8()

    func _read_array(length: int):
        var result: Array = []
        for _index in length:
            result.append(read_value())
            if _failed():
                return []
        return result

    func _read_map(length: int):
        var result: Dictionary = {}
        for _index in length:
            var key = read_value()
            var value = read_value()
            if _failed():
                return {}
            result[key] = value
        return result

    func _read_bytes(length: int) -> PackedByteArray:
        if length < 0 or offset + length > data.size():
            incomplete = true
            return PackedByteArray()
        var result := data.slice(offset, offset + length)
        offset += length
        return result

    func _signed(value: int, bits: int) -> int:
        var threshold := 1 << (bits - 1)
        return value - (1 << bits) if value >= threshold else value

    func _failed() -> bool:
        return incomplete or not error.is_empty()
