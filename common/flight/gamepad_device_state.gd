class DeviceState:
    extends RefCounted

    func connected_joypads() -> Array[int]:
        var device_ids: Array[int] = []
        for device_id in Input.get_connected_joypads():
            device_ids.append(device_id)
        return device_ids

    func is_joy_known(device_id: int) -> bool:
        return Input.is_joy_known(device_id)

    func joy_name(device_id: int) -> String:
        return Input.get_joy_name(device_id)
