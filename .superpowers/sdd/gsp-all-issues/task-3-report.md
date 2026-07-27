# Task 3 report — GitHub issue #243

## Scope

Implemented issue #243 on top of completed issue #242 commit `255bb0366343897d0b025253103b36f954db1a29`.

Luna session ID: `019fa11e-ea73-76f3-97fe-16e3766f90b8`.

The implementation reuses the existing native `telemetry_snapshot()` and the existing `AirSimCoordinateContract`. No native producer, GPU restriction, AirSim reference adaptation, or unrelated change was added.

## Problems and solutions

1. The required behavior had no public telemetry seam. The RED test initially failed because `GspServer` lacked telemetry serialization and control validation methods. Added the smallest public seams for snapshot serialization, rate validation, and fresh-sample requests, then implemented the server path behind them.
2. The existing native snapshot contains the 30 Hz publication metadata and motor/control telemetry but not runtime pose/rates. Added `FlightRuntime.gsp_telemetry_snapshot()` as a cached runtime adapter: it reuses the native publication count and converts the current body state through `AirSimCoordinateContract` into NED/FRD/SI payloads. This keeps serialization/sending out of `_physics_process` and avoids a parallel native producer.
3. Telemetry needed different delivery semantics from #242’s reliable FIFO. Added one latest-wins telemetry slot per authenticated peer and sent it directly outside the reliable queue. Rate zero clears the slot; a fresh request marks the next enabled sample; stalled peers therefore receive the current sample rather than queued history.
4. Returning from a hidden panel needed an explicit freshness boundary. The single-file panel sends rate zero while hidden, requests a fresh sample on visibility return, suppresses display until the fresh marker arrives, and then resumes 30 Hz live updates.
5. A first parallel focused-test run had a shared-port collision between telemetry and transport integration tests. Re-running the tests serially passed; no production issue was present.
6. The first full GUT run caught a GDScript indentation error from tabbed lines in the new runtime adapter. Replaced those lines with the repository’s four-space indentation and reran the suite successfully.
7. The codebase-memory MCP index/search transport was unavailable (`Transport closed` during index/status attempts). Used the required repository files plus targeted `rg`/`sed` fallback inspection; no implementation decision depended on missing index results.

## Sol-high review-fix round

The Sol-high consultation was supplied as `task-3-review-fix-brief.md` for session `019fa11e-ea73-76f3-97fe-16e3766f90b8`. Its seven blocking findings were applied without ambiguity:

1. Replaced the non-replacing slot behavior with a tested latest-wins seam and production use; a due source replaces an existing unsent slot.
2. Added a per-peer monotonic due time for the approved 0–30 Hz cadence while retaining one serialization per new native source publication.
3. Replaced compatibility controls with exact `set_telemetry {hz, extra}` and `request_snapshot {}` messages.
4. Moved telemetry into the parent v2 envelope with sender `seq`, top-level `tick`, and nested `d.sample_seq`.
5. Reused the coordinate contract and native snapshot with approved `pos_ned`, `vel_ned`, `att_euler_deg`, `gyro_body`, Betaflight motor order, `rpm`, and motor detail; added the canonical Z-Y-X degree extraction to the existing coordinate contract and fixture suite.
6. Restored periodic ping/pong RTT measurement; sample send time is no longer displayed as WebSocket RTT.
7. Made the contract test accumulate failures, polled both ends for the hidden-rate assertion, removed the explicit fresh request from stall recovery, and added cadence/latest-slot/protocol behavior checks.

Review-fix RED evidence:

```text
/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 --headless --path . --script res://tests/headless/gsp_telemetry_contract.gd
parse errors: old production lacked the new serializer signature and exact control validators

/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 --headless --path . --script res://tests/headless/gsp_telemetry_integration.gd
FAIL: old control names closed the peer; envelope, cadence, and recovery assertions failed

/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 --headless --path . --script res://tests/headless/gsp_telemetry_contract.gd
FAIL: sample age was still labeled as WebSocket RTT
```

Solutions were implemented only after each focused failure. The first full GUT attempt also caught the mixed tab/space indentation in the runtime adapter; the corrected four-space block passed on rerun. The coordinate fixture initially exposed Godot’s YXZ constructor order; the fixture now composes the approved Z-Y-X quaternion explicitly and retains strict degree assertions. The GUT wrapper initially rejected stale native provenance for the prior HEAD; the prescribed `verify_issue_11.sh` gate regenerated the generated artifact, after which GUT ran normally.

## TDD evidence

RED was run before production changes:

```text
Godot --headless --path . --script res://tests/headless/gsp_telemetry_contract.gd
parse errors: missing serialize_telemetry_snapshot, validate_telemetry_rate_message, validate_telemetry_request
```

After implementation, the same behavior-level tests passed:

```text
/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 --headless --path . --script res://tests/headless/gsp_telemetry_contract.gd
GSP telemetry contract: PASS

/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 --headless --path . --script res://tests/headless/gsp_telemetry_integration.gd
GSP telemetry integration: PASS
```

The integration test covers authentication, NED/FRD/SI fields, independent `sample_seq`, hidden rate zero, fresh recovery, latest/current delivery after a three-second stall, and always-process serialization/send diagnostics.

## Verification

```text
GODOT_BIN=/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 scripts/test_native.sh
PASS (exit 0)

GODOT_BIN=/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 RUNNER_TEMP=/tmp/aerosim-gsp-review-native scripts/test_native.sh
PASS (exit 0)

GODOT_BIN=/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 RUNNER_TEMP=/tmp/aerosim-gsp-review-issue11 scripts/verify_issue_11.sh
PASS; generated native provenance refreshed, license tests passed, extension build remained up to date

GODOT_BIN=/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 scripts/run_gut_tests.sh
PASS — 276 tests, 0 failures, 0 errors

GODOT_BIN=/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 RUNNER_TEMP=/tmp/aerosim-gsp-review-smoke scripts/run_headless_smoke.sh --output build/gsp-headless-review-fix.json --frames 5
PASS (exit 0)

GODOT_BIN=/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 python3 scripts/test_gsp_transport.py
GSP fixed-runner transport: PASS samples=1000 p99_ms=0.081

GODOT_BIN=/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 python3 scripts/test_gsp_transport_boundary.py
PASS — pending, graceful, and forced-close boundaries

sed -n '/<script>/,/<\/script>/p' common/gsp/gsp_panel.html | sed '1d;$d' | node --check
PASS

/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 --headless --path . --script res://tests/headless/replay_integration.gd
complete-session replay integration: PASS

/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 --headless --path . --script res://tests/headless/gsp_telemetry_contract.gd
GSP telemetry contract: PASS

/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 --headless --path . --script res://tests/headless/gsp_telemetry_integration.gd
GSP telemetry integration: PASS

Existing GSP transport contract, integration, boundary, and launch scripts: PASS (serial)
GODOT_BIN=/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 python3 scripts/test_gsp_transport_boundary.py
PASS — pending, graceful, and forced-close boundaries

git diff --check
PASS
```

Existing GSP transport contract/integration/boundary/launch headless checks also passed.

The smoke run emitted the repository’s expected invalid-fixture and Terrain3D mipmap warnings, but exited successfully. No headed/browser evidence was available or claimed.

## Scoped files

- `common/flight/flight_runtime.gd`
- `common/gsp/gsp_launcher.gd`
- `common/gsp/gsp_panel.html`
- `common/gsp/gsp_server.gd`
- `common/rpc/airsim_coordinate_contract.gd`
- `tests/gut/test_airsim_coordinate_contract.gd`
- `tests/headless/gsp_telemetry_contract.gd`
- `tests/headless/gsp_telemetry_integration.gd`
- `.superpowers/sdd/gsp-all-issues/task-3-report.md`

Godot-generated `.uid`, `.import`, and translation artifacts remain unstaged as required.
