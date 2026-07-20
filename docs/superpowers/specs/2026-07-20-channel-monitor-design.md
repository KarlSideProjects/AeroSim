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
The panel observes but does not consume flight inputs. While Settings Monitor
is open, existing A handling is screen-gated and leaves the actual arm state
unchanged; existing Y handling changes the mode only for an active flight. The
displayed action result must always be the actual post-event state, while pause
remains active.

On a safety-latched disconnect, the existing `controller_disconnected` safety
screen closes the Monitor and owns the disarm/freeze and reconnect explanation.
With a valid canonical `GamepadProfile` session, the Monitor displays its live
rows. In every other case—KeyboardProfile, no controller, unknown device, or
unconfirmed controller—every channel row is `UNAVAILABLE` and the existing
device/fallback diagnostic is shown unchanged. That diagnostic may describe
the unknown-device prompt, but never provides a channel sample or mapping. No
unavailable state is represented as a zero-valued channel.

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
- The headed paused-flight check starts armed, opens the Monitor, and verifies
  A press/release displays `PRESSED`/`RELEASED` with the unchanged actual
  `ARMED` result. It then verifies Y press/release displays the actual changed
  flight mode while `paused` remains true. A separate GUT preflight test uses
  high throttle to prove a rejected A press remains `PRESSED | DISARMED`; it
  does not depend on the Monitor screen gate. GUT also covers every
  no-session `UNAVAILABLE` path, the existing unknown-device diagnostic, and
  the throttle-low threshold.
- Run the required headless smoke after the GDScript change, plus existing
  native, GUT, and headed checks.
- The headed screenshot and report are provisional automated evidence for
  merge. `AGENTS.md` supersedes the older #41 comment's timing: no human visual
  or usability review is requested before CAP-006 passes. After CAP-006 passes,
  the G5.6 physical DEV-M validates the live bars and prompts before #41 closes.

## Out of Scope

- Endpoint, centre, RMS, repeatability, or controller calibration.
- Any new settings domain or change to `SettingsStore`.
- The Pause Overlay's `Controller Monitor` button and its return behavior; #42
  will connect that button to this panel.
