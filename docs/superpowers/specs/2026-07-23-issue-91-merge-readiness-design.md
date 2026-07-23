# Issue 91 Merge-Readiness Design

**Goal:** Complete #91's FRD flight-control-to-four-motor physical loop and its frozen verification gates so its follow-up PR can be merged without relaxing a product threshold.

## Scope and ownership

#91 owns the migration from the historical direct-rate controller to the shipped 5-inch-6S, 30 ms per-motor plant.  #24 stays closed as the historical direct-rate tuning slice.  The Betaflight SITL bridge remains deferred and is not an acceptance prerequisite.  Ubuntu Linux x86_64 is the only blocking runtime.

## Control architecture

The controller stores and computes command, target, error, rate, torque, integral, derivative, and saturation state in FRD order: roll, pitch, yaw.  A named, single boundary maps FRD vectors to Godot Y-up vectors as `{F, -D, R}` and the inverse as `{X, Z, -Y}`.  No controller path performs an additional axis or sign conversion.  The public telemetry schema remains frozen as `pid=[pitch,yaw,roll]`; roll saturation is therefore public index 2 even though internal controller state is FRD.

Each 1 kHz substep follows this fixed order:

1. Validate the command, configuration, measured rigid-body state, attitude, timing, and per-motor model before mutation.
2. Initialize or reset the relevant mode family from the measured state.
3. Shape Angle targets with `error_angle=wrap_pi(desired_angle-target_angle)`, `rate_cmd=clamp(error_angle/input_tc,-rate_max,+rate_max)`, `target_rate=move_toward(target_rate,rate_cmd,accel_max*dt)`, and `target_angle+=target_rate*dt`; crossing desired snaps `target_angle=desired_angle` and `target_rate=0`.  Shape Acro axes and Angle yaw into desired rates with the same rate/acceleration limits.  On the first armed substep, reset/collision reset, or Acro-to-Angle-family transition, synchronize target angle/rate to the measured state and clear I/D/previous-error/latches; Angle-to-Altitude preserves the shared family state.
4. Form the FRD rate setpoint from the shaped target rate plus the FRD attitude error term in Angle/Altitude modes.  The attitude path normalizes quaternions scale-safely, reconstructs canonical FRD Euler angles, uses the shortest-hemisphere body quaternion error, and converts the resulting Godot-body rotation vector to FRD before applying the angle gain.
5. Compute a provisional FRD rate PID output with filtered rate-error derivative and shaped-target proportional feed-forward only; D feed-forward is exactly zero.
6. Mix collective thrust and FRD torque with the fixed balanced planar Quad-X mixer.  Feed that same-substep mixer/motor clamp result back to the integrator: it may grow only while unsaturated and may shrink while saturated.
7. Apply motor lag and battery effects, integrate the four motors and rigid body, and OR-latch saturation for 30 Hz telemetry.
8. Commit state, publish telemetry when due, and advance the simulation clock only when the full public call succeeds.
The mixer stays a balanced planar Quad-X only.  Invalid geometry, spin order, non-finite values, or non-orthogonal coefficient columns fail loud; they are never corrected with a generic allocator.

## Atomic public-step contract

Every public native physics step is a transaction.  A failure returns a structured non-OK status and restores every observable mutable state to its pre-call value: rigid body, clock, controller/shaper/PID/motor state, telemetry/latches, collision authority/contact/clear-frame state, full IMU RNG/history/bias/walk state, armed/reject/reset/tuning observables, and mode initialization.  Validation covers Angle, Acro, Altitude Hold, timing, tuning, per-motor fields, measured altitude, estimated attitude, `sync_flight_state`, and collision command/contact/vector/parameter inputs on both Jolt and FlightCore paths before any mutation.  Native is the sole error owner: it sets and retains `last_step_error` until a successful public call or reset, emits exactly `AeroSimNative.<method>: <status_code>: <field/reason>` once, and returns the non-OK result.  GDScript reads that exact message, calls `set_paused(true)` synchronously, verifies the body is frozen, displays the error screen, and does not apply a normal row, reset contact, or emit a duplicate error.  The isolated negative process asserts exactly one matching `ERROR:` line for each invalid call.

Trajectory and replay APIs return `{status, rows, failed_frame}`.  Empty input and zero seconds return `Ok` plus empty rows; negative or non-finite duration returns `InvalidConfig`; a failed frame retains its status and failed frame while returning no normal rows.  Batch length uses checked `size_t` arithmetic before multiplication, allocation, or reservation; `kMaxBatchTrajectoryFrames=1,000,000` is only an engineering OOM bound, and allocation failure returns `ResourceLimitExceeded`.

## Acceptance and evidence

All existing thresholds remain frozen.  The implementation must provide RED then GREEN evidence for FRD signs and each newly required behavior.

- Shipped 5-inch-6S model, including 30 ms motor lag and battery sag, passes G2.4: +30 degree roll step, 10--90% rise and step-to-90% each at most 150 ms, peak at most 33 degrees, and settling within +/-0.6 degrees by 500 ms and maintained through one second.
- The same physical controller passes G2.5: reaches 720 degrees/s within +/-5% within the 250 ms test-harness bound, holds the band for 50 ms, and never exceeds its upper edge through 500 ms.  The 250 ms bound is not a PRD threshold.
- Ubuntu same-platform G0.6a replay is bitwise field-by-field across rigid body, target angle/rate, PID I/D, mode/init/latches, four motor thrust/saturation, clock, and first response substep; the replay artifact schema is upgraded from 2 to 3.  No padded-struct `memcmp` is used.
- Collision recovery uses the paired-counterfactual 500-substep response check rather than a height proxy: four scenes times 100 seeds times Angle/Acro, exactly one reset, collision energy at most 1.01 times pre-collision, and FlightCore authority every step.  The neutral clone uses throttle 0.5 and zero axes.  The response clone uses Angle `{throttle=0.8, roll=3 degrees, pitch=-2 degrees, yaw_rate=45 degrees/s}` or Acro `{throttle=0.8, sticks=(0.1,0.1,0.1), rates=(1.0,0.7,0.0)}`.  Within 500 substeps an actual motor thrust differs by more than `64 * DBL_EPSILON * max(1,max_thrust_per_motor_n)`; controller and motor state remain finite and bounded, mode initialization is correct, and replay is bitwise including first response substep.
- Invalid Angle/Acro/Altitude/timing/tuning/config/state/attitude/altitude/collision inputs leave state unchanged and emit exactly one native error.  A 240/1000 Hz fourth-substep failure must restore the exact pre-call state and make the next legal call bitwise equal to an untouched clone; IMU continuation is covered.  Normal GUT/headless/headed flows emit no unexpected error.
- FRD evidence includes a one-way `{2,-3,4}->{2,-4,-3}` transform, inverse round-trip, frozen motor-pair roll/pitch/yaw signs, the coupled `(30,20,10)` degree quaternion fixture, and known-device headed signs `omegaX<0`, `omegaZ<0`, `omegaY<0` while preserving the PR #114 GamepadProfile, 0.08 deadzone, session-device, and pitch-reversal behavior.
- Evidence is produced from the exact tested commit and native binary: build the debug GDExtension, run GUT, run the isolated native-negative process against that exact `.so`, then run headed acceptance.  A missing prerequisite fails loud; no job may skip or reuse an older artifact.  Native unit tests, full headless smoke, the frozen G0.1 effects-off/on performance checks, Ubuntu headed acceptance, and an independent adversarial review all pass with the tested HEAD and native hash recorded.

## Out of scope

No arbitrary mixer geometry, wrench governor, dynamic slew governor, notch filter, D feed-forward, legacy device-0 input behavior, deferred-platform CI, threshold relaxation, or GPL-derived ArduPilot code is introduced.
