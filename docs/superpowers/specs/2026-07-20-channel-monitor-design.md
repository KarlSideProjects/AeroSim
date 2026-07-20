# Ubuntu Channel Monitor Design

**Issue:** #41 — Ubuntu Channel Monitor 一等 UI (G5.6)

## Goal

Extend the existing `Settings → Controller` panel with a read-only monitor for
the canonical Xbox profile's four flight channels. It exposes raw and
runtime-normalized values at at least 30 Hz without creating another input
state, reconnect path, mapping store, or calibration flow.

## Chosen Approach

Add one `Label` to the current `ControllerSettingsPanel` in
`common/flight/flight_runtime.gd`. While that panel is visible, its existing
refresh path samples `Input.get_joy_axis()` for the connected controller at a
maximum interval of 33 ms. The panel uses the already active canonical profile
to map the four roles (`roll`, `pitch`, `yaw`, `throttle`) to axes and to show
the same normalized value the flight runtime consumes.

The monitor is deliberately part of Settings, not the flight HUD and not a
separate scene. This keeps the flight view uncluttered and reuses the only
controller connection truth introduced by #49.

## UI and Data Flow

The panel retains its current device, fixed-mapping, deadzone, button-status,
reset, and back controls. A new label appears after the fixed mapping:

```
CHANNEL MONITOR (30 Hz)
roll: raw +0.000 | normalized +0.000
pitch: raw +0.000 | normalized +0.000
yaw: raw +0.000 | normalized +0.000
throttle: raw +0.000 | normalized +0.000
```

`raw` is the direct Godot axis value for the profile's axis. `normalized`
applies the same fixed deadzone and direction inversion as the runtime's
profile input path. The Arm and Mode status line remains the source for the
two button states.

With no connected controller, the monitor shows `CHANNEL MONITOR: no
controller` and does not invent input values. An unsupported controller may be
identified by the existing device label, but it never gains a custom mapping.

## Constraints

- Ubuntu Linux x86_64 only.
- Exactly the canonical Xbox axis roles and fixed deadzone from `InputProfiles`.
- At least 30 Hz while the Controller settings panel is visible; no polling
  work while it is hidden.
- No persistence, calibration wizard, arbitrary mapping editor, reconnect
  logic, or flight-HUD overlay.
- Keyboard and gamepad remain usable for navigating the existing Settings UI.

## Verification

- GUT tests first prove the four role rows use the canonical axes, display raw
  and normalized values, apply the existing deadzone/reversal behavior, and
  represent no-controller state explicitly.
- A headed acceptance extension verifies the panel is present and free of
  `ERROR` or `SCRIPT ERROR` output.
- The existing native and headed checks remain green.

## Out of Scope

- Endpoint, centre, RMS, repeatability, or controller calibration.
- Any new settings domain or change to `SettingsStore`.
- Live channel overlay during a flight.
