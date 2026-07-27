# Task 6 report — issue #246

Thread: `019fa20f-e899-7993-9282-c2586d52c23d`

## Contract and implementation

- Preserved the existing #245 GSP tuning request/ACK/broadcast contract and its GPU-neutral native tuning path.
- Added an eight-slot `QuickAdjustProfile` with structural validation, settings persistence, conflict checks, panel controls, headless integration coverage, and a production HUD status label.
- Quick Adjust input is translated into the existing native tuning stage/commit seam. No GPU vendor, device, renderer, or performance-specific branch was added.
- Added session-level `quick_adjust_binding` replay metadata. It carries only a canonical full eight-slot profile snapshot, is validated as exactly eight null/object slots, and is an explicit replay no-op.
- Bumped complete replay schema v3 to v4. Tuning replay events now carry `source` and optional `quick_adjust_slot`.
- Rebinding and unbinding record one atomic full-profile snapshot after every successful configure, including no-op/same-profile configure calls. Quick Adjust is not recorded as `AsyncCommand`.
- Mixed next-physics tuning commits still stage/commit once. Each committed change preserves its last-write-wins source, request sequence, and optional slot. Aggregate source is `mixed` when needed; aggregate slot is emitted only when every winner has the same slot; aggregate request sequence is emitted only for one winning request. Replay recording uses each change’s winning provenance.

## Problems and solutions

1. Codebase-memory indexing was attempted first as required. Both calls failed exactly with:

   ```text
   tool call error: tool call failed for `codebase-memory-mcp/list_projects`
   Caused by: Transport closed
   tool call error: tool call failed for `codebase-memory-mcp/index_repository`
   Caused by: Transport closed
   ```

   Targeted fallback: `rg`, `sed`, `git diff`, and caller tracing were used for the affected replay, runtime, GSP, and test seams.

2. Direct `scons` discovery failed exactly with:

   ```text
   /bin/bash: line 1: scons: command not found
   ```

   The exact issue gate’s job-local Python virtualenv fallback installed and used SCons successfully.

3. The preserved Quick Adjust headless test had a parse error: `_finish()` referenced an undeclared `_runtime`. The cleanup was moved out of `_finish()` and the stale reference was removed. The test then passed.

4. Headless `Input.parse_input_event` did not make `Input.is_key_pressed` reliable for this isolated test. Runtime-local key and axis event state was added through `_unhandled_input`, while live input still uses Godot input as a fallback.

5. Headless mode could not force `Input.mouse_mode` to captured mode; it remained mode 0. The test now verifies the production HUD refresh does not mutate cursor capture instead of asserting an unavailable headless capture transition.

6. Constructing the complete flight HUD in the isolated headless test required the missing `res://locales/ui.en.translation` generated asset and produced unrelated localization errors. The test exercises the production Quick Adjust HUD refresh helper with a minimal label; the full gate covers headed/UI paths.

7. JSON numeric values read from settings can be floats even when the schema requires integral device/axis/key fields. Nested Quick Adjust normalization canonicalizes integral JSON numbers before validation.

8. The first implementation direction recorded Quick Adjust slot changes as `AsyncCommand`. Sol-high identified that repeated rebinding violates AsyncCommand lifecycle semantics and replay ignores it. That interrupted direction was removed and replaced with the dedicated session-level `QuickAdjustBinding` event.

9. The first mixed-commit implementation labeled the whole commit from `pending[0]`. It was replaced with per-parameter winner provenance and one native atomic stage/commit. A focused stress run then exposed one remaining call-site bug: replay recording still passed the aggregate `-1` request sequence instead of the enriched winning sequence. The call now passes each change’s winner metadata.

10. The server initially reintroduced a first-result request sequence while broadcasting a coalesced commit. An internal commit provenance marker now distinguishes ACK correlation from aggregate commit provenance; mixed broadcasts omit `request_seq`, while one-request commits retain it.

11. Existing replay integration assertions and the artifact comparator still expected schema v3. They were updated to schema v4; historical test names mentioning the prior checkpoint shape remain descriptive only.

12. Test-harness assumptions retained explicitly: two authenticated WebSocket peers, manual server polling because the server process loop is disabled in tests, monotonically increasing per-client GSP sequences, and JSON integer values being accepted as integral floats at the trust boundary.

## TDD evidence

- RED: the new native replay contract failed to compile before `QuickAdjustBinding`, v4 fields, and tuning provenance existed.
- GREEN: focused native replay test passed after the minimum serializer/parser/runner implementation.
- Focused checks passed:
  - `scripts/test_native.sh`
  - `scripts/test_license_scan.sh`
  - Quick Adjust integration
  - GSP tuning integration
  - GSP tuning stress
  - complete replay integration
  - GUT: 277 tests, 0 failures, 0 errors
  - `git diff --check`

The exact gate command used for the final verification is:

```text
RUNNER_TEMP=/tmp/aerosim-gsp-246 \
GODOT_BIN=/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 \
scripts/verify_issue_11.sh
```

The gate includes native compilation, license scan, GUT, atomic-boundary checks, GSP integration/stress, headed acceptance, replay integration, and five-frame headless smoke. Expected/provisional engine warnings and intentional negative-path error logs are harness output, not failures.

## Scope and limitations

- No progress ledger was edited.
- No unrelated preserved source edits were reverted.
- No AirSim source was adapted.
- No GPU vendor/device/renderer-specific behavior was introduced; Quick Adjust and replay remain data/configuration driven.
