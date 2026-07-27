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
