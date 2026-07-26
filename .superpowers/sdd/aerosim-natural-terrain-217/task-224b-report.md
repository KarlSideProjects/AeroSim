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

## Atomicity review follow-up — round 2

- `reset_to_spawn()` now queues only the private body pose transaction while
  paused. It leaves primary/secondary native flight state, IMU/collision
  contexts, contact state, AirSim control state, replay/environment state, and
  Time Trial untouched until every required body has acknowledged its physics
  commit.
- After all ACKs, the commit performs exactly one primary/secondary native
  `reset_flight`, one AirSim context/disarm reset, and contact reset before
  publishing environment, replay, scene, and trial reset state. A timeout does
  not run any of those operations. Pending reads receive `reset_pending`; after
  a failed transaction, state, sensor, camera, scene, and environment access is
  held behind `reset_failed` rather than exposing mixed old-body/new-native data.
- Deferred takeoff stays paused and frozen through the native/PX4 arm attempt.
  A rejected arm is terminal, paused, frozen, and disarmed; it never resumes,
  enters flight, requests takeoff, starts a trial, or performs a second trial
  reset.
- The new GUT counters assert zero native reset/disarm/context activity while
  pending and after timeout, exactly one reset/disarm/context operation after a
  successful two-body ACK, and one Time Trial reset with no `set_paused(false)`
  call on arm failure.

## Round 2 verification evidence

- The added regression tests first failed against the eager-reset code: pending
  and timeout observed native reset/disarm/context activity, and an arm failure
  resumed once and reset Time Trial twice. After the change, recovery GUT
  completed 261 tests with 0 failures/errors and 13 expected native-dependent
  pendings; normal GUT completed 261 tests with 0 failures/errors.
- Rebuilt the Linux debug GDExtension for commit `988d739dcefe4f508098733d9cce55e069b21da9` and refreshed the local ignored provenance receipt. `scripts/test_native.sh`,
  `scripts/test_native_atomic_boundary.sh`, and
  `scripts/test_replay_integration.sh` completed successfully.
- Headless smoke was run twice with
  `GODOT_BIN=/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 scripts/run_headless_smoke.sh --output build/headless_smoke.json --frames 5`.
  Both runs failed before the required report and trajectory were written at the
  existing Jolt zero-energy production-contact assertion:
  `body_impact_state body=35.701164 limit=0.000000 finite=true`.
  `build/headless/godot.log` exists (6,436 bytes); `build/headless_smoke.json`
  and `build/headless_trajectory.csv` are absent, so this gate is explicitly
  not reported as passed. The smoke source, native/config inputs, and Godot
  binary SHA were unchanged from the prior successful record.
- Provenance-backed headed acceptance was launched with
  `scripts/run_headed_acceptance.sh --xvfb --out-dir build/headed-round2` after
  validating the debug artifact receipt for
  `988d739dcefe4f508098733d9cce55e069b21da9`. The full headed scenario includes
  the retained-Terrain-Range/repeated Quick Fly cycle. It produced all expected
  screenshots plus `godot.log` and `report.json`, but the report has
  `passed=false` with 18 failures, so the script stopped before augmenting the
  report with native hashes and is not reported as passed. Artifacts retained in
  `build/headed-round2/` include `00_cold_start.png`,
  `00_keyboard_fallback_preconfirm.png`, `01_controller_confirmation.png`,
  `01_terrain_range_preflight.png`, `01_third_person_preflight.png`,
  `02_keyboard_fallback.png`, `03_takeoff.png`, `04_paused.png`,
  `05_reset.png`, `06_exit.png`, and `07_channel_monitor_paused.png` (and the
  additional finish/locale screenshots).
- The exact headed failures are recorded in `build/headed-round2/report.json`:
  three Xbox FRD-axis checks, Y-mode physical/release checks, paused channel
  monitor rate, controller-monitor/pause/ACRO interactions, retained South
  spawn and NED-origin checks, finish Change Map/Exit/P-resume checks, Terrain
  Range ground-color capture, and fresh-map reset pose/velocity. This is
  outside the reset transaction changes; no headed or Jolt assertion was
  weakened.
