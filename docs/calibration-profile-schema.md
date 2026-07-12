# GamepadProfile v1 Handoff for #49

The legacy filename is retained for the #49 handoff. #40 confirms one fixed Xbox default profile; it does not define a calibration profile, calibration data, or manual mapping flow.

`GamepadProfile.profile_schema_version` is `1`. A supported SDL controller obtains this profile only through `GamepadProfile.xbox_default(device_id)`.

| Role | Godot axis | Reversed |
| --- | --- | --- |
| Roll | `JOY_AXIS_LEFT_X` (0) | `false` |
| Pitch | `JOY_AXIS_LEFT_Y` (1) | `true` |
| Yaw | `JOY_AXIS_RIGHT_X` (2) | `false` |
| Throttle | `JOY_AXIS_RIGHT_Y` (3) | `false` |

The same v1 profile fixes `arm_button` to `JOY_BUTTON_A`, `mode_button` to `JOY_BUTTON_Y`, `deadzone` to `0.08`, and `sticky_throttle` to `true`.

#40 keeps the confirmed mapping in memory for the active session only. #49 owns persistence, serialized-schema validation, import/export, reconnect behavior, and any later schema migration. No calibration wizard, endpoint data, or manual mapping is implied by this handoff.
