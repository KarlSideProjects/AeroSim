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
timer or second polling loop is introduced. Settings opens the panel now.
Issue #41 changes no return routing or Pause Overlay control: #42 will call
this existing panel path when it adds its own entry.

The active `session_gamepad_device_id` and `session_gamepad_profile` are the
only source of a valid monitor sample. A non-null session profile with its
active session device ID is valid because the existing connection flow creates
that pair only for the supported canonical Xbox profile and clears it on
disconnect. A missing, disconnected, or unsupported device is `UNAVAILABLE`;
the monitor never calls a first-device scan, invents a profile, or tries to
compare a profile with device identity it does not contain.

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
flight-control state; a press is not itself evidence that its action succeeded.
The panel observes but does not consume flight inputs: existing A handling may
be rejected (for example, throttle not LOW), and existing Y handling changes
the mode immediately. The displayed action result must always be the actual
post-event state, while pause remains active.

The monitor has these availability states:

| Active input state | Channel rows | Device / prompt state |
| --- | --- | --- |
| Canonical `GamepadProfile` session | raw, normalized, bar, deadzone, and button/result rows | throttle LOW/HIGH, Arm, and Mode shown live |
| Keyboard fallback | `UNAVAILABLE` | `KeyboardProfile: discrete inputs only` |
| Unknown or unsupported device | `UNAVAILABLE` | `Unknown controller; KeyboardProfile fallback active` |
| Disconnected controller | `UNAVAILABLE` | `Controller disconnected; reconnect required` |

No unavailable state is represented as a zero-valued channel. The explicit
unknown-device state is the fourth G5.6 prompt; it does not introduce a mapping
or calibration flow.

## Constraints

- Ubuntu Linux x86_64 only.
- Exactly the canonical Xbox axis roles and fixed 0.08 deadzone from
  `InputProfiles`.
- At least 30 Hz while the Monitor is visible, including while paused; no
  monitor refresh work while it is hidden.
- Settings is the only user-facing entry in #41. #42 may reuse the existing
  panel when it adds its own Pause Overlay button; #41 adds no future-facing
  entry or return API.
- No persistence, calibration wizard, arbitrary mapping editor, reconnect
  logic, second controller truth, or flight-HUD overlay.
- Keyboard and gamepad remain usable for navigating the existing Settings UI.

## Verification

- GUT tests first prove canonical axis selection, 0.08 deadzone boundaries,
  raw-to-diagnostic-normalized rows, live-bar direction, throttle `LOW/HIGH`,
  button press/release, Arm/Mode result rows, and `UNAVAILABLE` state.
- A headed acceptance extension pauses the simulation and directly invokes the
  existing Settings Monitor path; it does not claim the #42 Pause Overlay entry
  exists. It injects canonical axis plus Xbox A/Y press/release input for at
  least one monotonic wall-clock second and writes a report proving refreshes
  per elapsed wall second are at least 30. It proves monitor values change while
  the body transform and simulation timestamp remain frozen, saves a
  screenshot, and rejects `ERROR` or `SCRIPT ERROR` output.
- The paused input check uses an A press while the Monitor is open to prove
  `PRESSED` can remain `DISARMED`, then verifies a Y press/release reports the
  actual changed flight mode while `paused` remains true. GUT separately covers
  the four availability states, the exact unknown-device prompt, and the
  throttle-low threshold.
- Run the required headless smoke after the GDScript change, plus existing
  native, GUT, and headed checks.
- The headed screenshot and report are provisional automated evidence. No human
  visual or usability review is requested for #41 before CAP-006 passes; any
  later DEV-M gate is scheduled with that milestone, not used to close #41.

## Out of Scope

- Endpoint, centre, RMS, repeatability, or controller calibration.
- Any new settings domain or change to `SettingsStore`.
- The Pause Overlay's `Controller Monitor` button and its return behavior; #42
  will connect that button to this panel.
