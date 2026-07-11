# Deterministic Rate Damping Design

## Problem

The #91 Quad-X mixer used a deadbeat rate torque: it attempted to remove the
entire rate error in one 1 kHz substep. Its motor-command clamp amplified
otherwise valid cross-compiler floating-point differences, breaking the G0.6a
cross-platform replay contract.

## Decision

Keep the 1 kHz per-motor callback and replace the deadbeat torque with a
stateless, bounded rate-damping law:

`torque = inertia * (kp * target_rate - kd * actual_rate)`

Apply an explicit torque bound before Quad-X mixing. The controller keeps no
previous-error or integral state, so it does not add a new floating-point
feedback accumulator.

## Scope

- Preserve the FRD boundary, Betaflight motor order, external motor API, and
  existing G0.6a tolerance.
- Calibrate only `kp` and `kd`: G2.5 establishes rate response; G2.4
  establishes damping/overshoot.
- Add a regression test showing a normal rate error cannot immediately force
  motor saturation in one 1 ms substep.
- Add replay checkpoints sufficient to report the first cross-platform
  divergence if the final-state comparison fails again.

## Verification

Run the focused native controller/replay tests, the full native suite, the
cross-platform replay comparison, clean full headless smoke, G0.1 with effects
off and on, and Linux real-display headed acceptance. Do not merge until every
required result is green.
