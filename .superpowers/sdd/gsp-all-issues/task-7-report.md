# Task 7 — Issue #247 implementation report

## Agent and contract

- Agent/thread: fresh independent implementation agent, `CODEX_THREAD_ID=019fa267-1d99-72d1-8dce-b6423951d468`.
- Worktree/branch: `gsp-all-issues` / `codex/gsp-all-issues`.
- Base: `147d6007b0c880de181c8a443415d97bef54e3d4`.
- Contract: save, list, retrieve, load, and compare same-registry tuning presets under fixed `user://gsp/presets`; exact ASCII names are validated before any name-derived path construction; metadata contains name, creation time, registry hash, simulation version, values, and optional note; load uses the existing runtime tuning request and native atomic stage/commit authority; diffs contain changes only and explicitly handle zero/sign-changing percentage baselines.

## Files and commits

Implementation commits:

- `612803f Add GSP preset save and compare`
- `4784800 Run preset tests after native build`
- `ce2db4a Place preset tests after extension setup`

Changed files:

- `common/gsp/gsp_preset_store.gd`: fixed-directory atomic JSON storage, metadata validation, exact ASCII name validation, listing, retrieval, and diff calculation.
- `common/flight/flight_runtime.gd`: registry-scoped save/retrieve/list/compare operations and preset load through `gsp_tuning_batch_request()`.
- `common/gsp/gsp_server.gd`, `common/gsp/gsp_launcher.gd`: trust-boundary validators, WebSocket operations, provider wiring, load ACK/broadcast behavior.
- `common/gsp/gsp_panel.html`, `tests/test_gsp_panel_behavior.js`: save/list/retrieve/load/compare controls and zero/sign-change-safe diff display.
- `tests/headless/gsp_preset_contract.gd`, `tests/headless/gsp_preset_integration.gd`: focused RED/GREEN and real WebSocket coverage.
- `scripts/verify_issue_11.sh`: runs the new tests after native extension setup.

## Problems encountered and solutions

1. Codebase-memory discovery was attempted first. The current worktree was not indexed. `index_repository` failed exactly with:

   ```text
   tool call error: tool call failed for `codebase-memory-mcp/index_repository`

   Caused by: Transport closed
   ```

   Targeted `rg`/`sed` discovery and caller tracing were used afterward. No existing preset implementation existed; the existing #245 runtime/native tuning seam was reused.

2. The GitHub issue page lookup was unavailable: web fetch returned `Failed to fetch ...: Cache miss`, and the GitHub API returned `curl: (22) ... 404`. The supplied task brief was treated as the authoritative contract.

3. Sol consultation was requested for the unspecified wire/API and percentage contract. Agent `019fa268-d679-7ba1-b180-3b3ca064c046` (`Hooke`) timed out twice without a recommendation and was closed. Decision: use the existing GSP message/ACK conventions, a fixed `user://gsp/presets` store, and `null` percentage plus `zero_baseline`/`sign_change` status where a percentage would mislead.

4. Initial RED failed because `gsp_preset_store.gd` did not yet exist:

   ```text
   Parse Error: Preload file "res://common/gsp/gsp_preset_store.gd" does not exist.
   ```

   The minimum store was added. A test type-inference parse error was then fixed by explicitly typing the runtime load result.

5. Runtime save readback rejected an empty project version:

   ```text
   preset readback validation failed: preset sim_version must be a non-empty string
   ```

   Empty project versions now record the required non-empty fallback `unavailable`.

6. The first full-gate attempt ran preset tests before native loading and failed with:

   ```text
   ERROR: Cannot get class 'AeroSimNative'.
   ```

   The tests were moved after the native build, GUT/import, and atomic-boundary extension setup. The exact gate then passed.

7. `scripts/run_gut_tests.sh` without environment setup failed exactly with `Godot executable was not found on PATH: godot`; with the configured binary, normal-mode provenance was stale for the pre-gate HEAD. Recovery-mode GUT was used for the focused broader check, and the exact gate rebuilt/validated the committed native artifact.

8. Godot generated untracked `.uid`, `.import`, and translation artifacts during import. Only those known generated artifacts were removed; no source, user preset, or unrelated worktree content was cleaned.

## TDD evidence

RED:

```text
/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 \
  --headless --path . --script res://tests/headless/gsp_preset_contract.gd
# failed: missing gsp_preset_store.gd preload
```

GREEN focused checks:

```text
node tests/test_gsp_panel_behavior.js
# GSP panel row behavior passed

/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 \
  --headless --path . --script res://tests/headless/gsp_preset_contract.gd
# GSP preset contract: PASS

/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 \
  --headless --path . --script res://tests/headless/gsp_preset_integration.gd
# GSP preset integration: PASS

/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 \
  --headless --path . --script res://tests/headless/gsp_tuning_contract.gd
# GSP tuning contract: PASS

/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 \
  --headless --path . --script res://tests/headless/gsp_tuning_integration.gd
# GSP tuning integration: PASS

GODOT_BIN=/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 \
  scripts/run_gut_tests.sh --recovery-mode
# GUT JUnit: 277 tests, 0 failures, 0 errors; 13 expected native-dependent pending checks
```

## Exact full gate

```text
RUNNER_TEMP=/tmp/aerosim-gsp-247 \
GODOT_BIN=/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 \
scripts/verify_issue_11.sh
```

Result: exit `0` on committed HEAD `ce2db4a`.

Observed gate evidence:

- native build and provenance completed;
- license scan passed for 11 dependencies, including the expected GPL fixture rejection;
- GUT: 277/277, 0 failures/errors;
- GSP preset contract/integration passed;
- existing GSP tuning integration and 7,200-frame stress passed;
- Quick Adjust integration passed;
- headed acceptance passed on the available NVIDIA Vulkan device;
- complete-session replay integration passed;
- headless smoke passed with `native_probe=47` and `simulated_frames=5`.

Expected negative-path native error logs, terrain texture mipmap warnings, and three existing GUT orphan warnings remained non-fatal and were accepted by the gate.

## Scope and limitations

- Presets are intentionally same-registry only: registry hash mismatch rejects load and comparison.
- Preset load stores no second active state; it translates stored values into the canonical runtime tuning batch and native atomic commit path.
- No registry migration, lifecycle recovery, or expanded replay/session marker work was added; those remain #248–#250 scope.
- No new dependency, Hardware configuration authority, SettingsStore path, or replay authority was introduced.
- No AirSim source was adapted.
- GPU qualification is vendor/type neutral. No vendor, device, adapter, renderer, or GPU allowlist/restriction was added; the NVIDIA Vulkan device appeared only as the environment used by the existing headed gate.

## Post-review Sol-high reconciliation

This section records the independent read-only Sol-high recommendation supplied after the initial implementation commits `612803f..bde7480`. The recommendation was verified against the current seams and implemented in the same #247 scope. Agent/thread identity remains `CODEX_THREAD_ID=019fa267-1d99-72d1-8dce-b6423951d468`; this was the same implementation thread continuing after review. No GitHub issue or progress ledger was edited.

### Discovery and findings

The required codebase-memory discovery was retried with the exact available project name `home-karl-Workspace-Toys-AeroSim-.worktrees-gsp-all-issues`; `index_status` returned `status: ready`, `nodes: 7050`, and `edges: 27416`. Graph search and caller tracing confirmed that `gsp_load_preset` reaches tuning only through `gsp_tuning_batch_request`, while `GspPresetStore` owns the fixed `user://gsp/presets` directory. The earlier indexing transport failure (`Transport closed`) is recorded above.

The review found these concrete gaps in `bde7480`:

1. `validate_name` added an unapproved first-character alphanumeric restriction. It rejected valid leading `-` and `_` names. The restriction was removed; tests now cover exact 1/64 valid boundaries, leading hyphen/underscore, 0/65 invalid lengths, traversal, absolute paths, separators, `.`, `..`, and a Unicode lookalike.
2. `_read_preset_file` called `get_as_text()` without a byte bound. A single `MAX_FILE_BYTES = 64 * 1024` limit now rejects oversized files before parsing. Save still uses temporary write, readback, and atomic rename.
3. Preset documents had no schema marker or strict root shape. `schema_version: 1` is now written and validated; unknown root fields, wrong schema, malformed JSON, non-finite values, empty metadata strings, and oversized input reject. Note limits use UTF-8 bytes in both the store and GSP request validator. Existing valid preset overwrite is covered.
4. `diff_values` used approximate equality and approximate zero. It now uses exact equality and exact zero, computes `delta / abs(left) * 100`, explicitly reports `zero_baseline` and `sign_change`, and returns `unrepresentable` with `null` for non-finite arithmetic. Tests cover positive, same-sign negative, zero baseline, sign change, target zero, tiny real differences, and overflow arithmetic; no NaN or Infinity is emitted.
5. `gsp_load_preset` iterated Dictionary order. It now iterates `_gsp_tuning_registry` order and calls only `gsp_tuning_batch_request(..., "preset", -1)`. Tests cover mismatched registry rejection without native state/commit mutation, unchanged active state before the next boundary, one atomic boundary commit, paused immediate commit, and reverse-ordered input producing canonical registry order.
6. The Node panel test only covered Quick Adjust. It now drives save, preset ACK/list refresh, retrieve, current comparison, preset-to-preset comparison, changed-only diff rendering including zero-baseline status, and load via `tuning_ack` over the fake WebSocket. The existing current-vs-preset and preset-vs-preset UI behavior remains intact.

### Reconciliation TDD evidence

RED after adding the focused assertions, before implementation:

```text
/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 --headless --path . \
  --script res://tests/headless/gsp_preset_contract.gd
# failed at parse time: Cannot find member "SCHEMA_VERSION" in base "GspPresetStore"
# failed at parse time: Cannot find member "MAX_FILE_BYTES" in base "GspPresetStore"
```

The new executable Node panel test passed immediately because the existing panel implementation already had the requested behavior; the missing coverage, rather than a panel defect, was the review gap.

GREEN focused checks:

```text
node tests/test_gsp_panel_behavior.js
# GSP panel row behavior passed

/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 --headless --path . \
  --script res://tests/headless/gsp_preset_contract.gd
# GSP preset contract: PASS
# Godot emitted two expected "Exponent too high" warnings while parsing the deliberate 1e999 non-finite fixture.

/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 --headless --path . \
  --script res://tests/headless/gsp_preset_integration.gd
# GSP preset integration: PASS

/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 --headless --path . \
  --script res://tests/headless/gsp_tuning_integration.gd
# GSP tuning integration: PASS

/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 --headless --path . \
  --script res://tests/headless/quick_adjust_integration.gd
# Quick Adjust integration: PASS
```

The initial focused contract run also exposed two test-fixture problems: Godot parses JSON numeric literals as `float` variants, and the paused-load assertion attempted to prove a new commit without first changing the active value. The schema check now accepts the parser’s exact numeric representation while requiring value `1`; the paused test mutates back to `1.2` before loading. Both were corrected before GREEN.

### Changes and commits

The post-review implementation changes are in `common/gsp/gsp_preset_store.gd`, `common/gsp/gsp_server.gd`, and `common/flight/flight_runtime.gd`; focused coverage is in `tests/headless/gsp_preset_contract.gd` and `tests/test_gsp_panel_behavior.js`. The final commit identifiers and full-gate result are appended after the committed gate run below.

The correction commit is `dcaf47a` (`Fix #247 preset review gaps`). It preserves the prior #247 range `612803f..bde7480` and all unrelated work. The report itself was force-added because its directory is ignored.

### Exact full gate on correction commit

Command:

```text
RUNNER_TEMP=/tmp/aerosim-gsp-247 \
GODOT_BIN=/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 \
scripts/verify_issue_11.sh
```

Result: exit `0` on committed HEAD `dcaf47a`.

Observed results:

- native build and provenance completed;
- license scan passed for 11 dependencies, including the expected GPL fixture rejection;
- GUT: 277 tests, 0 failures, 0 errors;
- GSP preset contract and WebSocket integration passed;
- existing GSP tuning integration and stress passed;
- Quick Adjust integration passed;
- headed acceptance passed on the available NVIDIA Vulkan environment;
- complete-session replay integration passed;
- headless smoke passed with `native_probe=47`, `physics_ticks_per_second=240`, and `simulated_frames=5`.

The gate also emitted the repository’s expected negative-path native errors, Terrain3D mipmap warnings, one editor/input-method warning, three existing GUT orphans, and the deliberate `1e999` non-finite fixture’s `Exponent too high` parser warning. None changed the exit status.

### Consultation and scope

The separate configured read-only Sol-high recommendation was supplied by the user/controller and verified against the indexed code seams. No additional Sol consultation was needed in this reconciliation. No registry migration (#248), lifecycle recovery (#249), expanded replay/session markers (#250), dependency, Hardware configuration/SettingsStore authority, replay authority, or GPU restriction was added.

GPU qualification remains vendor/type neutral: no vendor, device, adapter, renderer, or GPU allowlist/restriction exists in the #247 changes. Any GPU named in headed-gate output is only the test environment, not a product qualification rule.

## Fix round 1 — independent Sol-high SPEC/QUALITY findings

Fix base: `1f108ac`. This round stayed within #247 and did not edit the progress ledger or GitHub. Agent/thread identity remains `CODEX_THREAD_ID=019fa267-1d99-72d1-8dce-b6423951d468`.

### Findings and solutions

- Diff sign detection now compares signs directly, so `1e-308 -> -1e-308` is `sign_change` even when multiplication would underflow. Delta is calculated before percentage classification; overflowing deltas emit `absolute: null`, `absolute_status: "unrepresentable"`, and `percentage: null`, with no non-finite numeric field.
- FlightRuntime now requires preset value keys to equal the canonical registry key set exactly before save, load, or compare. Matching-hash truncated and unknown-key documents reject as `registry_values_mismatch` without state or commit mutation; migration remains #248 scope.
- Schema validation compares the numeric value exactly to schema version 1 rather than truncating with `int()`. JSON-parsed `1.0` is accepted; `1.9` is rejected.
- Standalone headless tests no longer remove fixed names. Each run generates an ASCII name from process ID, monotonic ticks, and a counter, verifies the path is absent, records only successfully created names, and cleans only those names. Pre-existing user presets are never overwritten or deleted.
- Real WebSocket integration now authenticates two peers. It saves/retrieves a baseline, mutates through normal tuning, resumes active mode, sends load from the origin, proves no immediate ACK or native mutation, applies one next-boundary commit, and verifies the origin ACK plus identical source-tagged commit identity on both peers and the final native value. The paused direct contract remains covered.

### Fix-round TDD evidence

RED test command:

```text
/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 --headless --path . \
  --script res://tests/headless/gsp_preset_contract.gd
# exit 1: fractional schema, diff edge cases, and matching-hash key-set assertions failed
# the pre-fix integration path was also exercised but did not fail because its new behavior was regression coverage
```

GREEN focused commands and results:

```text
node tests/test_gsp_panel_behavior.js
# GSP panel row behavior passed

/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 --headless --path . \
  --script res://tests/headless/gsp_preset_contract.gd
# GSP preset contract: PASS

/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 --headless --path . \
  --script res://tests/headless/gsp_preset_integration.gd
# GSP preset integration: PASS

/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 --headless --path . \
  --script res://tests/headless/gsp_tuning_integration.gd
# GSP tuning integration: PASS

/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 --headless --path . \
  --script res://tests/headless/quick_adjust_integration.gd
# Quick Adjust integration: PASS
```

The contract’s deliberate `1e999` non-finite fixture still produces Godot’s expected `Exponent too high` parser warning before rejection. Existing Godot ObjectDB/RID leak warnings remain non-fatal and unrelated.

### Fix-round files and commit

Implementation: `common/gsp/gsp_preset_store.gd`, `common/flight/flight_runtime.gd`. Coverage: `tests/headless/gsp_preset_contract.gd`, `tests/headless/gsp_preset_integration.gd`. The existing GSP server path and panel behavior were preserved and exercised; no GPU vendor/type restriction was introduced.

### Fix-round exact full gate

Command:

```text
RUNNER_TEMP=/tmp/aerosim-gsp-247 \
GODOT_BIN=/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 \
scripts/verify_issue_11.sh
```

Result: exit `0` on committed HEAD `38f3a33`.

Observed results:

- native build and provenance completed;
- license scan passed for 11 dependencies, including the expected GPL fixture rejection;
- GUT: 277 tests, 0 failures, 0 errors;
- panel behavior, preset contract, preset two-peer integration, existing GSP tuning integration, Quick Adjust integration, and GSP tuning stress passed;
- headed acceptance passed on the available NVIDIA Vulkan environment;
- complete-session replay integration passed;
- headless smoke passed with `native_probe=47`, `physics_ticks_per_second=240`, and `simulated_frames=5`.

The gate emitted only known non-fatal repository diagnostics: negative-path native errors, Terrain3D mipmap warnings, editor/import warnings, existing GUT orphans/leaks, and the deliberate non-finite preset fixture’s `Exponent too high` parser warning. GPU behavior remains vendor/type neutral; the NVIDIA device appears only as the test environment.

### Post-gate self-review correction

The complete diff self-review found one remaining direct-helper seam: `diff_values` still skipped one-sided keys even though FlightRuntime rejected them before valid comparisons. The helper now emits explicit `missing_value` rows with null percentage/absolute fields, and the panel renders missing endpoints safely. The focused contract, panel, and two-peer integration rerun passed after this correction. This is still #247 trust-boundary hardening; no migration behavior was added.

The exact gate was rerun after that correction:

```text
RUNNER_TEMP=/tmp/aerosim-gsp-247 \
GODOT_BIN=/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 \
scripts/verify_issue_11.sh
# exit 0 on committed HEAD 20b0c58
# license scan: 11 dependencies passed; GUT: 277/277; preset/tuning/Quick Adjust/stress/headed/replay/smoke passed
# smoke: native_probe=47, physics_ticks_per_second=240, simulated_frames=5
```

## Fix round 2 — independent Sol-high quality findings

Fix base: `a0e2516`. This round addressed only the two reported test/report defects. Agent/thread identity remains `CODEX_THREAD_ID=019fa267-1d99-72d1-8dce-b6423951d468`.

### Findings and solutions

- The canonical-order contract fixture still wrote the fixed name `ordered` while loading the generated `ordered_name`. It now saves, loads, and cleans the same collision-safe generated name, records it only after a successful save, and requires both save/load success and a non-empty full-size change list before checking canonical registry order. No fixed or pre-existing preset is pre-deleted or removed.
- Real backend preset-A-versus-B comparison coverage was missing from the WebSocket integration. The test now authenticates origin and observer peers, saves baseline A, mutates through the normal tuning authority, saves distinct B through the authenticated origin, sends `compare_presets` through the real GSP provider path, and asserts `preset_ack` operation/sequence, exactly one changed `simpleflight.rate_p` row, and finite percentage data with explicit `percentage_status`. The existing active pending load and two-peer source-tagged commit assertions remain intact.

### Fix-round TDD evidence

RED discovery checks before the correction:

```text
! rg -n 'save_preset\("ordered"|gsp_load_preset\([^\n]*"ordered"' tests/headless/gsp_preset_contract.gd
# exit 1; output showed tests/headless/gsp_preset_contract.gd:197 still writing literal "ordered"

rg -n 'compare_presets' tests/headless/gsp_preset_integration.gd
# exit 1; no output: real integration compare coverage was absent
```

The first focused contract run after the test correction was also RED on test syntax:

```text
/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 --headless --path . \
  --script res://tests/headless/gsp_preset_contract.gd
# exit 1: Parse Error: Expected expression after "and" operator at line 224
# after parenthesizing the multiline expression, the next run exposed the same
# GDScript continuation rule for the multiline "or" at line 228; both were corrected.
```

Focused GREEN checks:

```text
node tests/test_gsp_panel_behavior.js
# GSP panel row behavior passed

/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 --headless --path . \
  --script res://tests/headless/gsp_preset_contract.gd
# GSP preset contract: PASS
# expected Exponent too high warnings came from the deliberate 1e999 rejection fixture;
# existing ObjectDB/resource leak diagnostics were non-fatal

/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 --headless --path . \
  --script res://tests/headless/gsp_preset_integration.gd
# GSP preset integration: PASS
# existing ObjectDB/resource leak diagnostics were non-fatal
```

### Fix-round files and scope

Only `tests/headless/gsp_preset_contract.gd` and `tests/headless/gsp_preset_integration.gd` changed in this round. No production behavior, registry migration, lifecycle recovery, replay/session markers, dependency, Hardware configuration/SettingsStore/replay authority, or GPU qualification rule changed. GPU qualification remains vendor/type neutral: no vendor, device, adapter, or renderer allowlist/restriction was added.

The committed fix-round gate result is appended below.
