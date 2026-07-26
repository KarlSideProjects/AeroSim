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
