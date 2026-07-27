# Task 5 — Issue #245 implementation report

## Luna session

`CODEX_THREAD_ID=019fa1b9-029a-7950-a0bb-54370b0bb2a1`. No separate Luna
session identifier was exposed; this is the controlling Codex thread ID.

## Independent Sol-high findings and fixes

Commit `3da9299` was rejected with SPEC FAIL / QUALITY FAIL. The confirmed
blockers and the minimum fixes in this follow-up are:

1. Replay dispatch accepted only `simpleflight.rate_p`. The native replay
   switch now applies `angle_p`, `rate_i`, and `rate_d` through their existing
   `FlightController` setters. `tests/native/test_replay.cpp` records and
   executes all four parameters.
2. Runtime coalescing copied the first batch result into every ACK. ACKs now
   rebuild `changes`, `values`, requested values, committed values, and scalar
   fields from each origin request's own keys. The native reconnect snapshot
   no longer exposes ambiguous scalar `requested_value`, `committed_value`,
   or `clamped` fields; it exposes the complete `committed_values` map.
3. The server broadcast before the pending origin ACK and broadcast once per
   coalesced result. It now flushes each origin ACK before broadcasting,
   deduplicates by monotonic native `commit_id`, and preflights every reliable
   queue before adding a broadcast so a full queue is left intact rather than
   overflowing or closing the peer.
4. The old stress test called the runtime directly and covered only 240
   physics frames. It is replaced by a real `GspServer` with two authenticated
   `WebSocketPeer` clients, deterministic 7,200 physics frames, exactly 1,500
   requests at 50 messages/second, ACK/broadcast correlation, queue/result
   bounds, finite native state, final value, and replay-event bounds. The
   integration test also sends 50 requests through the real server before one
   physics boundary and asserts 50 per-request ACKs plus one commit broadcast.
5. Runtime apply timing previously inspected only the first batch member and
   treated every unpaused request as next-step. The runtime now validates every
   member, rejects mixed timings atomically, commits immediate timing at the
   request seam, commits paused next-step timing immediately, stages active
   next-step timing until `_physics_process`, and returns non-mutating truthful
   reset/restart results. Integration coverage mutates only test descriptor
   timing for existing native-backed keys and calls the production runtime
   seam.
6. The panel previously clamped before sending and left a transient timer
   alive on final sends. Final sends now cancel timers, send raw finite input,
   and leave range/step handling to native ACKs. Timeout and clamp display paths
   never write an invented committed value; group final sends cancel every row
   timer.

The codebase-memory index was attempted first and failed with the exact error:

```text
tool call error: tool call failed for codebase-memory-mcp/index_repository

Caused by: Transport closed
```

Targeted `rg`/`sed` discovery was used afterward. No high-value ambiguity
remained; Sol-high was not invoked because the rejection supplied the confirmed
decisions and the existing runtime/native seams were sufficient.

## Parameter set and active consumers

The canonical Hardware registry remains exactly these four descriptors:

- `simpleflight.rate_p`, default `0.600`, range `[0.0, 2.0]`, step `0.01`.
- `simpleflight.angle_p`, default `15.0`, range `[0.0, 40.0]`, step `0.1`.
- `simpleflight.rate_i`, default `0.020`, range `[0.0, 1.0]`, step `0.001`.
- `simpleflight.rate_d`, default `0.005`, range `[0.0, 1.0]`, step `0.001`.

The native consumers are unchanged: `FlightController::control_substep`
uses `angle_p_` for Angle-mode attitude error, `rate_p_` for body-rate error,
`rate_i_` for body-rate integration, and `rate_d_` for the filtered derivative.
The registry remains the descriptor authority and native controller fields the
active-value authority. Tuning hash serialization remains sorted-key,
descriptor-only canonical JSON and distinct from the broader configuration
hash.

## TDD and verification

RED regressions:

```text
scripts/test_native.sh
```

Failed at the expanded replay test with:

```text
complete-session replay must round-trip ordered tuning inputs
```

The panel contract RED was:

```text
GSP tuning contract: FAIL
panel final sends cancel an outstanding transient timer
panel sends finite raw input for native clamp and quantization
```

The integration RED reported the expected confirmed blockers: unsupported
replay tuning, per-request/server coalescing failure, immediate timing failure,
next-step seam failure, and mixed-timing failure.

Focused GREEN commands and results:

```text
GODOT_CPP_DIR=third_party/godot-cpp \
  /tmp/aerosim-gsp-245-red-green/aerosim-tools-local-3420405-1-verify-issue-11/scons-venv/bin/scons \
  target=template_debug platform=linux
# passed

scripts/test_native.sh
# passed

/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 \
  --headless --path . --script res://tests/headless/gsp_tuning_contract.gd
# GSP tuning contract: PASS

/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 \
  --headless --path . --script res://tests/headless/gsp_tuning_integration.gd
# GSP tuning integration: PASS

/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 \
  --headless --path . --script res://tests/headless/gsp_tuning_stress.gd
# GSP tuning stress: PASS

git diff --check
# passed
```

The integration test retains native all-or-nothing staging, duplicate-key
finalization, authority race protection, paused/physics timing, map-shaped
reconnect reconciliation, native quantization ACKs, actual replay execution,
two-panel synchronization, and disconnected-descriptor validate-all coverage.

The exact committed-HEAD gate is run after the fix commit:

```text
RUNNER_TEMP=/tmp/aerosim-gsp-245 \
GODOT_BIN=/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 \
scripts/verify_issue_11.sh
```

Its result and final commit SHA are appended after execution.

## Scoped files and limitations

The follow-up changes are limited to the existing native replay/configuration
readback, runtime tuning seam, reliable GSP server, inline panel, focused
native/headless regressions, real stress harness, and this report. No generic
parameter framework, new dependency, second state authority, or unrelated
visual/restart setting was added. The test-only timing cases reuse existing
native-backed descriptors by changing their registry timing in memory.

## GPU neutrality

No GPU vendor, device-type, adapter, Vulkan ICD, NVIDIA, integrated, discrete,
virtual, or software-adapter restriction was added. GPU evidence remains
observational only.
