# Task 224B report — physics-acknowledged reset transaction

## Scope completed

- Replaced direct `RigidBody3D` transform and velocity writes in
  `CollisionProbeBody` with a queue consumed exclusively from
  `_integrate_forces`. Reset work carries a monotonic token and is acknowledged
  only after `PhysicsDirectBodyState3D` has received pose and zero velocities.
- Added a reset transaction in `FlightRuntime`: `reset_pending` pauses the
  session, disarms primary/secondary/PX4 control, resets native state and
  environment/replay state, waits for each required body ACK, then transitions
  to preflight or its deferred Quick Fly/takeoff route. A bounded missing-ACK
  path enters the existing error state.
- While pending, the physics loop does not advance native/replay/IMU work;
  takeoff, arm, view switching, API-control enablement, and AirSim command RPCs
  reject the request. Chase-camera presentation remains disabled until commit.
- Reset gravity is suspended only until the DirectBodyState commit and restored
  while frozen, preventing a one-frame gravity drift from breaking the exact
  spawn/zero-velocity boundary.
- Respawn preserves intent to return to flight, but control is explicitly
  disarmed during the transaction and rearmed only after commit. PX4 transport
  stays connected; its authority remains inactive until its normal post-reset
  heartbeat confirms rearming.

## Regression coverage

- Added a real-physics `CollisionProbeBody` test proving reset pose does not
  appear before a physics commit and that the token ACK follows it.
- Added runtime coverage for the pending gate: paused/disarmed state, blocked
  API/arm/RPC/takeoff inputs, unchanged body before ACK, and restored preflight
  state with exact pose and zero velocities afterward.
- Added primary-and-secondary reset coverage, including their separate spawn
  positions and disarm assertions.
- Updated existing respawn, spawn-cycle, controller chord, PX4, and Quick Fly
  tests for the asynchronous commit contract.

## Verification evidence

- The new body test was first run before the queue/ACK API existed and failed
  as expected; it passes after the implementation.
- `GODOT_BIN=/home/karl/.local/share/Trash/files/Godot_v4.7-stable_linux.x86_64 scripts/run_gut_tests.sh --recovery-mode`
  completed: 258 tests, 0 failures, 0 errors; 13 native-dependent recovery
  pending tests.
- `scripts/test_native.sh` completed successfully.
- `git diff --check` completed successfully.

## Known non-blocking test noise

- Recovery GUT retains the existing three malformed Terrain Range fixture
  orphans and emits the existing Android daemon connection warning; neither
  produces a test failure or error.

## Atomicity review follow-up — round 1

- Reset side effects that become externally meaningful—replay reset records,
  environment changes, time-trial reset, scene-catalog reset, acceleration
  baseline, and secondary collision publication—now wait for all body ACKs.
  A timeout keeps the pre-reset environment and time-trial state and records no
  replay reset event.
- Pending AirSim state, sensor, scene/environment, and image requests now
  receive `reset_pending` (or an unavailable camera source for image capture),
  rather than a mix of the pre-reset body and reset native data. AirSim FPV is
  restored through the normal chase-camera source after commit.
- Native/PX4 arm is now attempted before entering flight, unpausing, unfreezing
  a body, starting a time trial, or setting `takeoff_requested`. An arm failure
  performs terminal safe cleanup; unlike an ACK timeout it deliberately resets
  the time trial as part of the failed takeoff transaction.
- New GUT coverage proves pending state/image rejection and deferred
  replay/environment/time-trial publication, timeout rollback, and post-commit
  native-arm failure cleanup.

## Round 1 verification evidence

- Before the round-1 implementation, the new pending-publication test failed:
  it observed a replay reset record, reset environment/time-trial state, and
  readable AirSim state before an ACK. The post-change recovery suite passed
  261 tests with 0 failures/errors and 13 expected native-dependent pendings.
- After rebuilding the Linux debug GDExtension for this commit, the normal GUT
  suite completed: 261 tests, 0 failures, 0 errors.
- `scripts/test_native.sh`, `scripts/test_native_atomic_boundary.sh`,
  `scripts/test_replay_integration.sh`, and
  `scripts/run_headless_smoke.sh --output build/headless_smoke.json --frames 5`
  all completed successfully.
