# Ubuntu Channel Monitor Design

**Issue:** #41 — Ubuntu Channel Monitor 一等 UI (G5.6)

## Goal

Provide one read-only Channel Monitor for the canonical Xbox profile's four
flight channels. The existing `Settings → Controller` entry opens it now; the
future #42 Pause Overlay must open the same panel while physics is paused. It
exposes raw, diagnostic-normalized, deadzone, button, and control-result state
at at least 30 Hz without creating another input state, reconnect path,
mapping store, or calibration flow.

## Chosen Approach

Keep the current `ControllerSettingsPanel` as the one Monitor panel in
`common/flight/flight_runtime.gd`. Its content is refreshed from the process
path while visible, including while the simulation is paused; no production
timer or second polling loop is introduced. Settings opens the panel now. The
panel exposes one reusable show/back path so #42 can later open and return from
the same instance without duplicating the UI.

The active `session_gamepad_device_id` and `session_gamepad_profile` are the
only source of a valid monitor sample. They must describe the same connected,
SDL-known Xbox device. A missing, disconnected, mismatched, or unsupported
device is `UNAVAILABLE`; the monitor never calls a first-device scan or
constructs a fallback profile to fabricate valid-looking values.

The panel is not a flight HUD overlay. It remains readable in Settings and is
available through its reusable entry path while paused, preserving the frozen
physics and simulation clock required by the Pause contract.

## UI and Data Flow

The panel retains its current device, fixed-mapping, reset, and back controls.
It adds these read-only rows after the fixed mapping:

```
CHANNEL MONITOR (30 Hz)
roll:     [--------|--------] raw +0.000 | normalized +0.000
pitch:    [--------|--------] raw +0.000 | normalized +0.000
yaw:      [--------|--------] raw +0.000 | normalized +0.000
throttle: [--------|--------] raw +0.000 | normalized +0.000 | LOW
DEADZONE: 0.080 (fixed)
ARM: RELEASED | flight control: DISARMED
MODE: RELEASED | flight mode: ANGLE
```

Each live bar uses the diagnostic-normalized value. `raw` is the direct Godot
axis value for the session profile's axis. `normalized` applies the fixed 0.08
deadzone and role direction inversion. It is a diagnostic value, not a claim
that every role uses the identical flight-control path: the existing sticky,
clamped throttle remains the authority for flight. The `LOW`/`HIGH` result is
derived through the existing throttle-low rule without mutating sticky throttle
state.

Arm and Mode show both their current physical button state and their resulting
flight-control state; a press must never be displayed as an already successful
arm or mode change. With no valid session controller, every monitor row reads
`UNAVAILABLE`; no zero-valued substitute is shown.

## Constraints

- Ubuntu Linux x86_64 only.
- Exactly the canonical Xbox axis roles and fixed 0.08 deadzone from
  `InputProfiles`.
- At least 30 Hz while the Monitor is visible, including while paused; no
  monitor refresh work while it is hidden.
- The single panel must be callable by Settings now and by #42 later, without
  adding the #42 Pause Overlay button in this issue.
- No persistence, calibration wizard, arbitrary mapping editor, reconnect
  logic, second controller truth, or flight-HUD overlay.
- Keyboard and gamepad remain usable for navigating the existing Settings UI.

## Verification

- GUT tests first prove canonical axis selection, 0.08 deadzone boundaries,
  raw-to-diagnostic-normalized rows, live-bar direction, throttle `LOW/HIGH`,
  button press/release, Arm/Mode result rows, and `UNAVAILABLE` state.
- A headed acceptance extension pauses the simulation, injects canonical axis
  plus Xbox A/Y press/release input for at least one monotonic wall-clock
  second, and writes a report proving refreshes per elapsed wall second are at
  least 30. It also proves the monitor values change while the body transform
  and simulation timestamp remain frozen, saves a screenshot, and rejects
  `ERROR` or `SCRIPT ERROR` output.
- Run the required headless smoke after the GDScript change, plus existing
  native, GUT, and headed checks.
- After merge, Ubuntu physical Xbox-compatible-controller DEV-M validates the
  live bars, prompts, and paused Monitor path before #41 closes.

## Out of Scope

- Endpoint, centre, RMS, repeatability, or controller calibration.
- Any new settings domain or change to `SettingsStore`.
- The Pause Overlay's `Controller Monitor` button; #42 will connect that
  button to this panel.
