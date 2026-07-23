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

## Review follow-up: 2026-07-23

- RED: G2.4/G2.5 initially rejected the zero-lag/no-sag fixture; the validated `HardwareConfig` fixture now carries the shipped 30 ms motor time constant and 0.003 ohm cell resistance, and proves the sagged thrust cap is lower than nominal.
- RED/GREEN: a coupled nonzero roll/pitch plus yaw-rate fixture initially kept the Angle yaw target stale. The shaped yaw rate now advances `target_angle_frd.z` before quaternion error formation.
- RED/GREEN: a reversing Angle target initially carried rate past the new desired angle. The shaper now snaps a crossed target and clears its target rate; the test asserts both state values.
- Removed the interim torque clamp. The final physical G2.4/G2.5 tuning uses the shared 120 rad/s² shaper, Angle P=15, filtered rate D, and an explicit shaped-rate P feed-forward term (default 0); no allocator/governor was introduced.

| Command | Result |
| --- | --- |
| focused `test_cascaded_flight_control` | PASS |
| focused `test_flight_control` | PASS |
| `scripts/test_native.sh` | PASS |
| `git diff --check` | PASS |
| `scripts/check_hardcoded_airframe_constants.sh` | PASS |
