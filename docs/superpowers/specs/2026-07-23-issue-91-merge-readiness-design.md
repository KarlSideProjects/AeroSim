# Issue 91 Merge-Readiness Design

**Goal:** Complete #91's FRD flight-control-to-four-motor physical loop and its frozen verification gates so its follow-up PR can be merged without relaxing a product threshold.

## Scope and ownership

#91 owns the migration from the historical direct-rate controller to the shipped 5-inch-6S, 30 ms per-motor plant.  #24 stays closed as the historical direct-rate tuning slice.  The Betaflight SITL bridge remains deferred and is not an acceptance prerequisite.  Ubuntu Linux x86_64 is the only blocking runtime.

## Control architecture

The controller stores and computes all command, target, error, rate, torque, integral, derivative, saturation, and telemetry state in FRD order: roll, pitch, yaw.  A named, single boundary maps FRD vectors to Godot Y-up vectors as `{F, -D, R}` and the inverse as `{X, Z, -Y}`.  No controller path performs an additional axis or sign conversion.

Each 1 kHz substep follows this fixed order:

1. Validate the command, configuration, measured rigid-body state, attitude, timing, and per-motor model before mutation.
2. Initialize or reset the relevant mode family from the measured state.
3. Shape Angle targets with first-order target angle/rate state, rate and acceleration limits; shape Acro axes and Angle yaw into desired rates with the same rate/acceleration limits.
4. Form the FRD rate setpoint from the shaped target rate plus the FRD attitude error term in Angle/Altitude modes.
5. Run FRD rate PID with filtered rate-error derivative, shaped-target proportional feed-forward only, and saturation-aware integral anti-windup.
6. Mix collective thrust and FRD torque with the fixed balanced planar Quad-X mixer, apply motor lag and battery effects, integrate the four motors and rigid body, and latch saturation for 30 Hz telemetry.
7. Commit state, publish telemetry when due, and advance the simulation clock only when the full public call succeeds.

The mixer stays a balanced planar Quad-X only.  Invalid geometry, spin order, non-finite values, or non-orthogonal coefficient columns fail loud; they are never corrected with a generic allocator.

## Atomic public-step contract

Every public native physics step is a transaction.  A failure returns a structured non-OK status and restores every observable mutable state to its pre-call value: rigid body, clock, controller/shaper/PID/motor state, telemetry/latches, collision authority, and IMU state.  Native is the sole error owner: it records and emits one named error; GDScript consumes that error, pauses and freezes the body, and does not apply a normal row, reset contact, or emit a duplicate error.

Trajectory and replay APIs return status, rows, and failed-frame information so an empty successful batch is distinguishable from a rejected batch.  Non-finite or oversized batches fail loud before allocation or mutation.

## Acceptance and evidence

All existing thresholds remain frozen.  The implementation must provide RED then GREEN evidence for FRD signs and each newly required behavior.

- Shipped 5-inch-6S model, including 30 ms motor lag and battery sag, passes G2.4: +30 degree roll step, 10--90% rise and step-to-90% each at most 150 ms, peak at most 33 degrees, and settling within +/-0.6 degrees by 500 ms and maintained through one second.
- The same physical controller passes G2.5: reaches 720 degrees/s within +/-5%, holds that band for 50 ms, and remains within the 500 ms test-harness bound.  The harness bound is not a PRD threshold.
- Ubuntu same-platform G0.6a replay is bitwise across rigid body, controller state, four motor thrust/saturation, and clock.  No padded-struct `memcmp` is used.
- Collision recovery uses the paired-counterfactual 500-substep response check rather than a height proxy, and preserves finite state, authority, and replay evidence.
- Invalid Angle/Acro/config/state/attitude inputs leave state unchanged and emit exactly one native error; normal GUT/headless/headed flows emit no unexpected error.
- Native unit tests, GUT, full headless smoke, the frozen G0.1 effects-off/on performance checks, Ubuntu headed acceptance, and an independent adversarial review all pass.

## Out of scope

No arbitrary mixer geometry, wrench governor, dynamic slew governor, notch filter, D feed-forward, legacy device-0 input behavior, deferred-platform CI, threshold relaxation, or GPL-derived ArduPilot code is introduced.
