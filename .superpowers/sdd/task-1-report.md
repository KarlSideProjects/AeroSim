# Task 1 Report: FRD Cascade Controller

Date: 2026-07-23

## Delivered

- Replaced the legacy Y-up rate target with FRD angle/rate targets, rate I/D/error state, mode-family initialization, and same-substep mixer-clamp anti-windup.
- Angle and Altitude Hold share the Angle family; either Acro/Angle transition and controller reset resynchronize from the measured state and clear PID/shaper state.
- Added scale-safe quaternion attitude error, target shaping with snap-on-crossing, FRD rate control, and retained the fixed Quad-X mixer as the only allocation point.
- Routed motor torque through the existing `frd_to_y_up` boundary before rigid-body integration.
- Preserved the public 30 Hz PID telemetry order as `[pitch,yaw,roll]` while controller state remains `[roll,pitch,yaw]` FRD.

## TDD evidence

- RED: the legacy controller failed the new positive-roll FRD plant assertion: `positive roll command must produce the positive FRD roll plant response`.
- GREEN: the focused cascade, mixer, flight-control, and telemetry native executables pass after the FRD cascade and fixed mixer-boundary changes.
- Added coverage for the exact one-way transform and inverse, frozen Quad-X roll/pitch/yaw motor pairs, coupled `(30,20,10)` quaternion zero-error fixture, Acro↔Angle resets, roll step timing, 720 degrees/s reach/50 ms hold/upper bound, telemetry order, saturation latch, and anti-windup release.

## Validation

| Command | Result |
| --- | --- |
| `git diff --check` | PASS |
| `scripts/check_hardcoded_airframe_constants.sh` | PASS |
| `scripts/test_native.sh` | PASS |

## Concern

The controller gains are fixed controller tuning, not airframe constants; the hardware and motor values remain sourced from the existing configuration path.
