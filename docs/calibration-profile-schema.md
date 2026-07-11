# CalibrationProfile Schema

`schema_version` is `1`. `axis_for_role` maps `roll`, `pitch`, `yaw`, and `throttle` to distinct non-negative Godot joy-axis indices. `reversed_for_role` has exactly the same keys and boolean values. `axis_ranges` has one entry per role with finite `minimum`, `maximum`, and `center` numeric values. `arm_button` and `mode_button` are distinct non-negative Godot joy-button indices. `sticky_throttle` is a boolean.

#40 keeps this value in memory only. #49 serializes it, validates this schema on import, and owns migration for a later version.
