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
