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
- Tracked dynamically created tuning-group apply buttons in the same readiness inventory. A hidden-session fresh telemetry frame is ignored while `document.hidden`; visibility restoration requests a new matching snapshot and sends 30 Hz before readiness can return.
- Reset stale session request maps, sequence state, telemetry freshness, and control readiness on replacement.
- Extended the real GSP boundary harness with pre-stop probe snapshots containing timestamp, live/authenticated/closing counts, and process/physics ticks. Added coverage for graceful replacement, abrupt reclaim, same-process token reuse, and restart token rejection/acceptance.
- Kept launcher shell-open failures URL/fragment-free while preserving the single explicit printed launch URL. Added a headless launcher harness with injected display/opener seams so restart evidence captures the real printed `file://...#port=...&token=...` URL without opening a browser.
- Made a missed 250 ms probe publication retryable inside the five-second abrupt-reclaim deadline using the same expected sequence; process exit and total deadline remain fatal.
- Removed display/opener test injection from production launch options. Production uses `get_display_name()` and `open_panel()`; only the harness subclass overrides those methods and records the opener call.
- Added the recovery test to `scripts/verify_issue_11.sh` while preserving the existing server port fallback tests.

## TDD evidence

1. RED: `node tests/test_gsp_panel_recovery.js` first failed because the initial panel controls were not disabled (`false !== true`). Before that, the draft test correctly exposed an incorrect test assumption about server port fallback; the controller clarified #242 must remain, so the server-source assertion was removed and replaced by a panel URL assertion.
2. GREEN: after the minimum panel fix, `node tests/test_gsp_panel_recovery.js` passed with deterministic fake-clock delays `[250, 500, 1000, 2000, 4000, 5000]`, reset to 250 ms after full readiness, disabled controls before readiness, stale-generation rejection, no persistence API, and unchanged hash-port URL.
3. `node tests/test_gsp_panel_behavior.js` passed after its fake DOM was updated to model native disabled controls and the new authenticated/fresh-snapshot startup seam.

### Review-fix round

1. RED: the corrected hidden-session test on `b49b448` delivered the matching fresh snapshot while hidden and failed because the panel became `Connected` (`expected not Connected, got Connected`). The same test also caught the omitted group-apply disabled transition (`false !== true`).
2. RED: the strengthened real boundary test timed out waiting for its new pre-stop probe before the harness supported `--probe-file`.
3. GREEN: `node tests/test_gsp_panel_recovery.js` and `node tests/test_gsp_panel_behavior.js` passed after adding the hidden telemetry guard, visibility re-snapshot assertion, group-button inventory, quick-control assertions, and preserved reconnect backoff assertion (`500 ms` after an unready hidden loss).
4. GREEN: the focused boundary run passed with live/authenticated/closing snapshots `1/1/0 → 0/0/0 → 2/2/0`; abrupt reclaim passed in `0.101s` with positive process/physics tick delta `4965/4965` in one run.

### Final review-fix round

1. RED: `gsp_launch_contract.gd` failed when a token-bearing URL was passed to `shell_open_result`; the returned error contained the full URL. GREEN: the error is now `OS.shell_open failed; panel was not opened`, and the test asserts no URL, fragment, or token text appears.
2. RED: the new second-process launcher harness printed no URL because headless display detection rejected the requested-open test path. GREEN: `GspLauncher.launch` uses the minimum injected display/opener seams; the real restart test now reports `fresh_printed_url=true` and authenticates that printed token while rejecting the first process token.
3. RED: the deterministic probe retry test initially failed at the missing retry helper. GREEN: a delayed first probe is retried with the next sequence and succeeds (`delayed_timeout_retry=true`); the real abrupt-reclaim loop catches only publication timeouts and still fails on process exit or total deadline.

### Final review-fix round 2

1. RED: with the old timeout behavior restored, the real delayed-consumption harness timed out after the harness published sequence 1 because the client had advanced to sequence 2. GREEN: timeout retries retain sequence 1; only successful publication advances it, and the real test reports `same_sequence=true`.
2. GREEN: the launch contract independently stores the raw token and rejects it, the URL, `file://`, `#`, and `token=` from the shell-open error. Complete launcher stdout is retained through shutdown and requires exactly one `GSP panel URL:` record.
3. GREEN: the restart harness subclass overrides the display and opener methods without production option injection, records the opener invocation, and authenticates the fresh printed URL token while rejecting the stale token.
4. GREEN: launcher URL-capture failure cleanup uses bounded `communicate(timeout=2)` and a bounded kill/communicate fallback; it never performs an unbounded stdout read. New harness GDScript uses four-space indentation.

## Real transport evidence

`GODOT_BIN=/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 python3 scripts/test_gsp_transport_boundary.py` passed:

- pending handshake reclaim and capacity reuse;
- graceful replacement with the existing token and two authenticated peers, proving the old peer no longer inflates count;
- forced reliable-close cleanup;
- same-process replacement with exact pre-stop counts `1/1/0`, reclaimed counts `0/0/0` before replacement, and replacement/observer counts `2/2/0`;
- abrupt RST with pre-loss counts, polling diagnostics, timestamp/tick deltas, reclaim within five seconds, and replacement/observer counts `2/2/0`;
- server restart with stale-token rejection and fresh authentication from the newly printed launcher URL;
- deterministic delayed-consumption retry with the same probe sequence.

## Full gate

Implementation commits: `3f0b0756a367219b1b171c20b214164d672f7940` (`Fix GSP panel lifecycle recovery`), `b49b448` (`Fix GSP hidden reconnect and lifecycle evidence`), `5572d9c` (`Keep hidden GSP sessions inactive`), `facd36a` (`Fix final GSP review findings`), and `4fe4528` (`Fix GSP review round two findings`).

Ran the exact required command from the final committed HEAD (`facd36a`):

```text
RUNNER_TEMP=/tmp/aerosim-gsp-249 \
GODOT_BIN=/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 \
scripts/verify_issue_11.sh
```

Validation result from implementation HEAD `4fe4528`: exit 0. The gate passed native tests, license scan, panel tests, same-sequence probe retry and real GSP boundary tests, GDExtension build, terrain dependency, GUT (277/277), native atomic boundary, preset contract/integration, tuning integration/stress, quick-adjust integration, headed acceptance, replay integration, and headless smoke (`completed: true`, `simulated_frames: 5`). The focused launcher contract also passed. This report is committed before the required exact rerun from the report-bearing final HEAD.

## Problems and exact resolutions

- Worktree code-memory index was missing: indexed the worktree in moderate mode before direct source inspection.
- Initial draft RED check wrongly treated `PORT_RANGE` as forbidden: removed that check after controller clarification and asserted all fake panel sockets stay on the single URL-fragment port instead.
- First panel GREEN run found the tuning control record omitted its button element: added the existing button to that record so the readiness gate disables/enables the complete tuning row.
- Review found dynamically created group apply buttons were outside the tracked inventory: added the existing group buttons to that inventory and asserted disabled/enabled state directly.
- Review found a hidden reconnect could become active from its matching snapshot: ignored telemetry while hidden, retaining the existing visibility handler as the sole visible reactivation path.
- Review found the real evidence only inspected final stop state: added harness probe snapshots and polling assertions for exact pre-stop counts, timestamps, and process/physics progress.
- Final review found shell-open errors duplicated token-bearing launch URLs: removed URL data from the error while retaining the explicit printed URL and added a focused contract assertion.
- Final review required restart evidence from the launcher seam: added only test display/opener injection and a headless harness that captures the printed URL, without a browser or secondary credential channel.
- Final review found a single missed probe publication could falsely fail abrupt reclaim: introduced a typed publication-timeout retry path and deterministic delayed-probe regression.
- Final review round 2 found timeout retries advanced the expected sequence: added a real delayed-consumption harness and kept the sequence unchanged on timeout.
- Final review round 2 found raw-token and exact-log-count assertions were missing: retained full launcher stdout, asserted one URL record, and rejected the independently stored raw token.
- Final review round 2 found production launch options were carrying test injection: moved the seam to a harness-only subclass overriding display and opener methods.
- Final review round 2 found launcher URL-capture failure cleanup could block on stdout: bounded stop/kill and `communicate` cleanup.
- First real harness run found mixed space/tab GDScript indentation in the newly added status fields: converted only the new lines to the repository’s tab indentation; boundary tests then passed.
- One chained boundary invocation reported a transient executable lookup error despite the configured Godot binary existing; a direct rerun with the exact binary passed all six boundary cases. No code change was made for that environmental transient.
- One focused rerun initially used a malformed `GODOT_BIN` path; rerunning with `/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64` passed. No code change was made.
- One focused launcher-contract command initially expanded an environment variable before assignment and did not invoke Godot; the corrected direct binary invocation passed. No code change was made.
- One direct Python import of the boundary helper omitted its `scripts` module path; rerunning with `PYTHONPATH=scripts` produced the intended RED and GREEN evidence. No code change was made.
- The first streamed full-gate observation was interrupted before its late lanes were visible; a second exact committed-HEAD run captured its exit code and completed with exit 0.
- The full gate emitted known non-fatal diagnostics: generated missing `.uid`/`.import`/translation artifacts, existing Terrain3D mipmap warnings, expected negative-path native error logs, existing GUT orphan/leak warnings, and the environment’s NVIDIA Vulkan headed lane. The command still exited 0 and no #249 failure was observed.

## Concerns

- The headed gate ran on the available NVIDIA Vulkan device, but #249 introduces no vendor/type/adapter restriction and the panel behavior is GPU-neutral.
- Generated Godot `.uid`, `.import`, and translation files from verification are removed after this report commit; build outputs remain ignored/generated and are not part of the task diff.
