# Task 224C report — completion-aware AirSim reset RPC

## Scope completed

- `AeroSimRpcServer` now recognizes MessagePack transport `reset` requests as
  deferred work. It retains the exact TCP peer, connection epoch, MessagePack
  id, runtime reset generation, and a bounded monotonic deadline; it does not
  emit a response until that generation commits or fails.
- Concurrent reset callers join one physical runtime generation. Waiters are
  bounded, disconnecting a client removes only that client's waiter, and a
  server stop clears all retained waiter state. A generation with no remaining
  waiter is still drained to a terminal status before a later request can
  begin another reset.
- `FlightRuntime` owns reset generations and exposes start/status/abort
  callbacks. RPC reset uses the disarming reset-to-spawn transaction rather
  than local Quick Fly respawn/rearm behavior. Its public AirSim session,
  replay, and RPC control latches remain unchanged while the physics ACK is
  pending.
- On commit, the server performs exactly one AirSim `Reset` replay record,
  session reset, and RPC control-latch reset immediately before replying to
  the retained requests. The private physics transaction no longer emits its
  local `Respawn` record or prematurely resets RPC latches for an RPC-owned
  generation. On timeout the server aborts the owned runtime generation before
  returning `reset timeout`; no public reset is published afterward.
- Existing publication gating rejects mutations during reset pending while
  preserving ping/version/configuration and read-only compatibility queries.

## Regression coverage

- Added real `StreamPeerTCP` loopback MessagePack tests for two simultaneous
  reset requests, response id matching, no early bytes, one physical reset,
  pending mutation rejection, committed replay/session/control publication,
  timeout abort with preserved public state, and client disconnect draining.
- Updated runtime reset coverage for the lifecycle handlers and preserved
  public session state while a body ACK is pending.

## Verification evidence

- Focused transport suite:
  `test_airsim_rpc_server.gd` completed 24 tests / 193 assertions, all passed.
- Focused runtime suite completed 84 tests passed with 13 expected
  native-extension recovery pendings; no failures or errors. It retains the
  repository's three known malformed Terrain Range fixture-orphan warnings.
- Full recovery suite:
  `GODOT_BIN=/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 scripts/run_gut_tests.sh --recovery-mode`
  completed 268 tests, 255 passed, 13 expected native-dependent pendings, 0
  failures, and 0 errors.
- `git diff --check` completed successfully.

## Gate note

- The normal GUT wrapper was not reported as green because its native artifact
  provenance receipt is stale for the current HEAD before it begins tests.
  Recovery-mode validation was used without rebuilding or modifying the native
  artifact.

## Round 1 review fixes

- Deferred status is now read before a waiter deadline. A committed generation
  wins that race and publishes success; only a generation still reported as
  pending is aborted for timeout.
- RPC-owned reset replay now records `Reset` before the committed environment
  baseline. The private runtime commit defers that environment record for RPC
  resets; the `Reset` replay callback immediately records the baseline after
  the native reset event.
- Deferred transport reset performs the shared request-frame validation before
  being recognized, and deduplicates pending `(connection epoch, message id)`
  correlations. Runtime ownership is installed before a no-ACK reset can
  synchronously commit.
- Loopback coverage now includes committed-but-expired success, invalid
  non-request reset frames, duplicate message ids, and two-client disconnect
  behavior. Runtime coverage proves the no-ACK RPC-owned success records
  Reset then environment. Native replay coverage proves that exact ordering
  survives replay application and a checkpoint.

## Round 1 verification evidence

- Focused RPC transport suite: 26 tests / 219 assertions, all passed.
- Focused runtime suite: 98 tests / 700 assertions, all passed.
- `scripts/test_native.sh` completed successfully.
- Recovery GUT completed 271 tests, 258 passed, 13 expected native-dependent
  pendings, 0 failures, and 0 errors.
- Refreshed the ignored local provenance receipt for committed source-identical
  native artifacts, then ran the normal GUT wrapper: 271 tests, 0 failures,
  0 errors. `scripts/test_replay_integration.sh` completed with
  `complete-session replay integration: PASS`.

## Round 2 replay epoch ordering

- Deferred RPC reset publication now records the native Replay `Reset`, resets
  the public AirSim session clock, then records the committed environment
  baseline. This retains Reset-before-environment replay semantics while the
  baseline consumes the reset clock epoch rather than the pre-reset clock.
- A runtime replay regression starts at a nonzero simulation time, completes a
  synchronous RPC-owned reset, records two post-reset events, and proves the
  strict timestamp sequence `Reset < Environment < post-reset 1 < post-reset
  2`.

## Round 2 verification evidence

- Focused runtime suite: 98 tests / 703 assertions, all passed.
- Focused RPC suite: 26 tests / 219 assertions, all passed.
- Normal full GUT: 271 tests / 1,619 assertions, 0 failures, 0 errors.
- `scripts/test_replay_integration.sh` completed with
  `complete-session replay integration: PASS`.

## Round 3 synchronous reset publication

- The supported synchronous/no-ACK `reset` dispatch branch now calls the same
  single publish helper as deferred completion. It emits Replay Reset, resets
  the session clock, emits the environment baseline, and resets control state
  exactly once.
- Added synchronous RPC coverage for Reset-before-environment ordering and
  retained the native replay Reset/environment/checkpoint coverage that proves
  the baseline survives replay application.

## Round 3 verification evidence

- Focused RPC suite: 27 tests / 226 assertions, all passed.
- Normal full GUT: 272 tests / 1,626 assertions, 0 failures, 0 errors.
- `scripts/test_replay_integration.sh` completed with
  `complete-session replay integration: PASS`.
