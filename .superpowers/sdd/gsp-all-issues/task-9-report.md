# Task 9 report — GitHub issue #249

## Scope

Implemented only the GSP panel lifecycle recovery work for #249. The existing #242 `GspServer.PORT_RANGE` sequential bind fallback remains unchanged. No ledger, GitHub issue, runtime/native authority, GPU policy, or credential persistence was modified.

## Discovery and decisions

- The worktree was not indexed initially. Codebase-memory indexing was run in moderate mode for `/home/karl/Workspace/Toys/AeroSim/.worktrees/gsp-all-issues` and completed successfully as project `home-karl-Workspace-Toys-AeroSim-.worktrees-gsp-all-issues`.
- The traced lifecycle was `GspLauncher.launch()` → `GspServer.start()` → `GspServer.poll()` and peer state sets → printed `file://...#port=...&token=...` → panel `new WebSocket()` → authenticated `hello` → requested fresh telemetry snapshot.
- Root causes were panel one-shot connection setup, no generation guard on callbacks, no replacement-session readiness barrier, and no reconnect timer. Server token generation/auth/cleanup seams were reused; server port fallback was deliberately left alone.

## Implementation

- Added panel-local bounded exponential reconnect using only the original URL fragment token and port.
  - Minimum delay: 250 ms.
  - Maximum delay: 5000 ms.
  - Delays do not create a tight loop and reset only after both fresh `hello` and fresh authoritative snapshot.
  - Every retry remains on the single `ws://127.0.0.1:<hash-port>` URL; no browser port probing or persistence API is used.
- Added per-connection generation checks for open/message/close/error callbacks and transient/tuning timeout callbacks. Old peers cannot mutate current panel state.
- Disabled static, tuning, quick-adjust, preset, migration, and simulation-related controls until the current generation has received authenticated `hello` and matching fresh snapshot telemetry. Added visible disabled styling and control-send guards.
- Reset stale session request maps, sequence state, telemetry freshness, and control readiness on replacement.
- Extended the real GSP boundary harness to record process/physics progress and added coverage for graceful replacement, abrupt reclaim, same-process token reuse, and restart token rejection/acceptance.
- Added the recovery test to `scripts/verify_issue_11.sh` while preserving the existing server port fallback tests.

## TDD evidence

1. RED: `node tests/test_gsp_panel_recovery.js` first failed because the initial panel controls were not disabled (`false !== true`). Before that, the draft test correctly exposed an incorrect test assumption about server port fallback; the controller clarified #242 must remain, so the server-source assertion was removed and replaced by a panel URL assertion.
2. GREEN: after the minimum panel fix, `node tests/test_gsp_panel_recovery.js` passed with deterministic fake-clock delays `[250, 500, 1000, 2000, 4000, 5000]`, reset to 250 ms after full readiness, disabled controls before readiness, stale-generation rejection, no persistence API, and unchanged hash-port URL.
3. `node tests/test_gsp_panel_behavior.js` passed after its fake DOM was updated to model native disabled controls and the new authenticated/fresh-snapshot startup seam.

## Real transport evidence

`GODOT_BIN=/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 python3 scripts/test_gsp_transport_boundary.py` passed:

- pending handshake reclaim and capacity reuse;
- graceful replacement with the existing token and two authenticated peers, proving the old peer no longer inflates count;
- forced reliable-close cleanup;
- same-process replacement;
- abrupt reclaim within the five-second bound while physics frames continued;
- server restart with stale-token rejection and fresh-token authentication.

## Full gate

Implementation commit: `3f0b0756a367219b1b171c20b214164d672f7940` (`Fix GSP panel lifecycle recovery`).

Ran the exact required command from that committed HEAD:

```text
RUNNER_TEMP=/tmp/aerosim-gsp-249 \
GODOT_BIN=/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 \
scripts/verify_issue_11.sh
```

Result: exit 0. The gate passed native tests, license scan, panel tests, real GSP boundary tests, GDExtension build, terrain dependency, GUT (277/277), native atomic boundary, preset contract/integration, tuning integration/stress, quick-adjust integration, headed acceptance, replay integration, and headless smoke.

## Problems and exact resolutions

- Worktree code-memory index was missing: indexed the worktree in moderate mode before direct source inspection.
- Initial draft RED check wrongly treated `PORT_RANGE` as forbidden: removed that check after controller clarification and asserted all fake panel sockets stay on the single URL-fragment port instead.
- First panel GREEN run found the tuning control record omitted its button element: added the existing button to that record so the readiness gate disables/enables the complete tuning row.
- First real harness run found mixed space/tab GDScript indentation in the newly added status fields: converted only the new lines to the repository’s tab indentation; boundary tests then passed.
- One chained boundary invocation reported a transient executable lookup error despite the configured Godot binary existing; a direct rerun with the exact binary passed all six boundary cases. No code change was made for that environmental transient.
- The full gate emitted known non-fatal diagnostics: generated missing `.uid`/`.import`/translation artifacts, existing Terrain3D mipmap warnings, expected negative-path native error logs, existing GUT orphan/leak warnings, and the environment’s NVIDIA Vulkan headed lane. The command still exited 0 and no #249 failure was observed.

## Concerns

- The headed gate ran on the available NVIDIA Vulkan device, but #249 introduces no vendor/type/adapter restriction and the panel behavior is GPU-neutral.
- Generated Godot `.uid`, `.import`, and translation files from verification are removed after this report commit; build outputs remain ignored/generated and are not part of the task diff.
