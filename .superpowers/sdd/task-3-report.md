# Task 3: Replay schema-v3 and collision recovery evidence

## Scope

- Upgraded complete replay artifacts from schema 2 to schema 3 with controller, motor, clock, and first-response checkpoint state.
- Added checked replay batches returning `status`, `rows`, and `failed_frame`; the hard cap is `kMaxBatchTrajectoryFrames=1'000'000`.
- Replaced the collision height/angle proxy with the paired neutral/response counterfactual across the existing four scenes, 100 seeds, and Angle/Acro modes.

## TDD evidence

### RED

```bash
mkdir -p build/tests && g++ -std=c++17 -Wall -Wextra -Werror -ffp-contract=off -Isrc/native tests/native/test_replay.cpp src/native/aerosim_aerodynamics.cpp src/native/aerosim_simulation.cpp src/native/aerosim_flight_control.cpp src/native/aerosim_imu.cpp src/native/aerosim_wind.cpp src/native/aerosim_collision.cpp src/native/aerosim_replay.cpp -o build/tests/test_replay && build/tests/test_replay
```

Failed as expected because `ReplayBatchResult`, checked batch entry points, schema-v3 controller checkpoints, clocks, and first-response fields did not exist.

```bash
g++ -std=c++17 -Wall -Wextra -Werror -ffp-contract=off -Isrc/native tests/native/test_replay.cpp src/native/aerosim_aerodynamics.cpp src/native/aerosim_simulation.cpp src/native/aerosim_flight_control.cpp src/native/aerosim_imu.cpp src/native/aerosim_wind.cpp src/native/aerosim_collision.cpp src/native/aerosim_replay.cpp -o build/tests/test_replay && build/tests/test_replay
```

The second RED exposed the missing field-by-field run comparator for changed controller, motor, and clock checkpoint fields.

### GREEN

```bash
g++ -std=c++17 -Wall -Wextra -Werror -ffp-contract=off -Isrc/native tests/native/test_replay.cpp src/native/aerosim_aerodynamics.cpp src/native/aerosim_simulation.cpp src/native/aerosim_flight_control.cpp src/native/aerosim_imu.cpp src/native/aerosim_wind.cpp src/native/aerosim_collision.cpp src/native/aerosim_replay.cpp -o build/tests/test_replay && build/tests/test_replay
g++ -std=c++17 -Wall -Wextra -Werror -ffp-contract=off -Isrc/native tests/native/test_collision.cpp src/native/aerosim_aerodynamics.cpp src/native/aerosim_simulation.cpp src/native/aerosim_flight_control.cpp src/native/aerosim_imu.cpp src/native/aerosim_wind.cpp src/native/aerosim_collision.cpp src/native/aerosim_replay.cpp -o build/tests/test_collision && build/tests/test_collision
scripts/test_native.sh
GODOT_CPP_DIR=/tmp/aerosim-issue36-ci/aerosim-tools-local-1772574-1-verify-issue-11/godot-cpp /tmp/aerosim-issue36-ci/aerosim-tools-local-1772574-1-verify-issue-11/scons-venv/bin/scons -j4 target=template_debug platform=linux
GODOT_BIN=/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 scripts/test_replay_integration.sh
AEROSIM_REPLAY_ARTIFACT=build/replay_task3.json build/tests/test_replay && python3 scripts/compare_replay_artifacts.py build/replay_task3.json build/replay_task3.json
```

All commands passed. The first integration attempt intentionally caught a stale pre-change native `.so`; rebuilding the pinned GDExtension made the schema-v3 integration pass.

## Review-fix evidence

- RED: a full-checkpoint recorder call did not compile because the recorder accepted only `DualAircraftState`.
- GREEN: the recorder now accepts a complete checkpoint; the existing native binding fills it from live controller, clock, motor, propwash, and first-response state without changing the GDScript call signature.
- Both session and run comparators now include checkpoint motor/propwash and every first-response rigid-body field. The randomized collision proof uses one direct recovery run to record its commands, collision, release-frame operation, response operation, full checkpoints, and first response; it then calls `ReplaySessionRecorder::serialize()`, `load_replay_session()`, and `replay_session()` on the deserialized session. It bitwise-compares the replay's ready checkpoint, final checkpoint, and first-response sample to the recorded run. It does not invoke the collision simulation helper a second time as a stand-in for replay.
- Added explicit schema-v2 rejection and checked finite/capped duration-to-`size_t` frame conversion coverage.

## Final review fixes

- Secondary checkpoints now receive the live secondary `AeroSimNative` instance from `FlightRuntime`. The primary recorder copies its controller state, simulation clock, motor/propwash body state, and cached first response; the secondary begins capture alongside the primary recording session, so vehicle 1 is no longer silently defaulted.
- First-response capture moved to the successful native-step path (Angle, Acro, altitude-hold, collision, and actuator rows). It snapshots the first returned physical substep immediately, before a later checkpoint can observe a different motor state.
- Zero-tolerance comparator paths now compare the IEEE-754 bit representation of each double. The RED signed-zero replay comparator test failed under numerical comparison and passes with the bitwise implementation; this also preserves distinct NaN payloads/non-finite representations.
- The 4 scenarios × 100 seeds × Angle/Acro collision matrix enables A6 propwash. Its inverted tumble recovery has a non-zero first-response propwash assertion, and the record/serialize/load/replay path bitwise-compares that sample, including propwash.
- `test_replay` artifacts now include propwash, controller target/rate/PID/latch state, and first-response time/substeps/motors/propwash. `compare_replay_artifacts.py` rejects divergence in each of those fields. The GDExtension integration verifies both vehicles' checkpoint controller, clock, motor, propwash, and response fields.
- Comparator reporting now uses the same IEEE-bit predicate for every zero-tolerance floating-point branch, including simulation-time events, collision vectors/scalars, and scene transforms, so signed-zero cannot be silently accepted while selecting a divergence field.
- Live and replay use the same response definition: the first successful substep associated with a recorded non-neutral command. Native steps retain the returned sample, then the recorder latches it only after that command is recorded; neutral and zero-substep prefixes do not latch. The integration runner uses two distinct armed native instances, steps both with non-neutral input, and records their real live checkpoint state.

Validation after the review fixes:

```bash
scripts/test_native.sh
GODOT_CPP_DIR=/tmp/aerosim-issue36-ci/aerosim-tools-local-1772574-1-verify-issue-11/godot-cpp /tmp/aerosim-issue36-ci/aerosim-tools-local-1772574-1-verify-issue-11/scons-venv/bin/scons -j4 target=template_debug platform=linux
GODOT_BIN=/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 scripts/test_replay_integration.sh
```

## Scope

Implemented only the requested CAP-006 Task 3 behavior in:

- `common/flight/flight_runtime.gd`
- `tests/gut/test_flight_runtime_load.gd`
- `common/smoke/headless_smoke.gd`

No PRD, scene, persistence, second runtime/session, or diagnostics-system changes were made. Task 1 license-gate behavior and Task 2 shared seven-entry setup were preserved.

## Implementation

- Added caller-aware controller routing. Controller opened from the main menu now returns to the main menu after confirmation, keyboard fallback acceptance, or cancel. Quick Fly remains the only controller flow whose confirmation/fallback completion enters preflight. Settings controller reset returns to controller settings.
- Wired the exact seven main-menu entries: Quick Fly, Lab Mode, Controller, Drone, Map, Settings, Quit.
- Wired Lab Mode to the existing runtime and dashboard: it sets the existing dashboard to `full`, does not replace `native`, and returns to the main menu with `compact` layout. Escape returns from Lab Mode without invoking process exit.
- Wired Settings through existing `show_settings` and Quit through existing cleanup-safe `request_exit`.
- Expanded cold-start smoke evidence for the exact seven entries, shared Drone/Map setup and focus, Quick Fly default reset, same-native Lab Mode, Settings, cleanup-safe Quit, controller confirmation/fallback/cancel routes, and missing provider failure without secret markers. The smoke harness uses an in-process valid provider only for gameplay-route coverage; production license behavior is unchanged.

## TDD evidence

1. Added failing GUT assertions for menu controller confirmation/fallback/cancel routing and same-runtime Lab Mode behavior.
2. Red recovery GUT reached the intended missing public-route failures: `open_controller_from_menu`, `open_lab_mode`, and Lab return were absent.
3. Implemented the minimum route state and wiring.
4. Recovery GUT went green for those behaviors and the existing suite.
5. The first full native GUT run exposed mechanical test drift from the required seven-entry menu: the two existing Settings navigation cases still used `range(4)`, landing on Map. Only those two loops were changed to `range(5)`; their `screen == "settings"` assertions were retained.

## Validation

- `GODOT_BIN=/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 scripts/run_gut_tests.sh --recovery-mode`
  - PASS: 179 tests, 0 failures, 11 expected native-dependent pending tests.
- `GODOT_BIN=/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 scripts/run_headless_smoke.sh --output build/headless_smoke.json --frames 5`
  - PASS: completed smoke report, native probe 47, 5 simulated frames, route assertions passed.
  - Expected fixture diagnostics were emitted for `missing_map` and `invalid_out_of_range.json`; the command exited 0.
- `GODOT_BIN=/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 RUNNER_TEMP=/tmp/aerosim-ci-43 scripts/verify_issue_11.sh`
  - PASS: native tests, license scan/API tests, pinned Godot C++ extension build, headless smoke, and final artifact assertions.
  - Final artifact: `completed=true`, `native_probe=47`, `simulated_frames=5`, `trajectory_stride=12`, collision and hardware paths true.

## Diagnosed failures

- Initial smoke run failed before route assertions because the worktree had no built Linux GDExtension. The required Ubuntu verification built the pinned extension.
- First route smoke attempt correctly stopped because the local license state was not Quick-Fly-valid, so Quick Fly did not mutate setup. The smoke harness now injects a valid provider for deterministic route coverage; missing-provider behavior remains separately asserted.
- First full native GUT run failed only because two pre-existing navigation loops still assumed five menu entries. Changing exactly `range(4)` to `range(5)` resolved that drift.

## Concerns and disposition

- Godot/Jolt emitted an existing job-system warning during smoke; all gates completed successfully.
- Human visual review remains deferred until the Playable Game Milestone, as required by repository policy.
- No GitHub comment was posted.

## Adversarial smoke/test evidence fix

The adversarial review required evidence corrections only. Production behavior in `common/flight/flight_runtime.gd` was retained unchanged; the fix changed only `common/smoke/headless_smoke.gd` and this report.

### TDD and diagnosis

1. Added the stronger smoke assertions before changing any production code: real Quick Fly confirmation completion, real Lab Mode button and Escape route, real Settings controller-reset confirmation, controlled provider canaries, and tight visible-output checks.
2. The first smoke execution exposed a test-script parse failure: Godot could not infer the type of `replacement_confirmation` from the dynamically typed controller panel. The minimal test-only fix was `var replacement_confirmation: Control`.
3. The next smoke execution reached existing flight-input coverage and failed because the new test sequence called `show_main_menu()` after Quick Fly preflight. That test-only transition prevented the later high-throttle assertion from observing `HIGH`; removing that transition restored the original state. No production defect was exposed.
4. The corrected smoke passed without production changes.

### Corrected evidence

- Quick Fly clears `persisted_gamepad_profile`, `session_gamepad_profile`, and the session device before opening the route. It presses the actual `UseXboxDefaultProfile` button and asserts `controller_return_screen == "preflight"`, then `screen == "preflight"`, disarmed, and not `main_menu`. The replacement runtime repeats the fresh confirmation route. The connected-unknown-device route presses `USE KEYBOARD FALLBACK` and asserts preflight rather than menu.
- Missing-provider coverage uses `SmokeFailingLicenseProvider` with a controlled config snapshot containing four distinct non-secret canaries for token, key, customer, and claim. The fake provider receives and records the config but returns only `controlled_provider_failure`; the serialized blocked screen, error, license status, arm status, and sanitized provider snapshot are checked for absence of every exact canary. No production credential or secret is used or logged.
- Lab coverage presses `MainMenu/Entries/LabMode`, captures `status_diagram.get_render_evidence()`, and asserts the same native object, full layout, visible dashboard, and visible selector. It sends Escape and asserts compact layout plus main menu with the existing dashboard still visible.
- Settings coverage presses `ResetXboxDefault`, uses the actual `UseXboxDefaultProfile` confirmation action, and asserts return to `controller_settings`. It then uses the actual Controller Settings and Settings Back buttons to return to the main menu. No hidden main-menu button is emitted while confirmation is active.

### Final validation

- `GODOT_BIN=/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 scripts/run_gut_tests.sh --recovery-mode` — PASS: 179 tests, 0 failures, 11 expected native-dependent pending tests.
- `GODOT_BIN=/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 scripts/run_headless_smoke.sh --output build/headless_smoke.json --frames 5` — PASS: `completed=true`, `native_probe=47`, `simulated_frames=5`, `trajectory_stride=12`. Expected missing-map and invalid-fixture diagnostics were emitted; the known Jolt job-system warning remained non-fatal.
- `GODOT_BIN=/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 RUNNER_TEMP=/tmp/aerosim-ci-43 scripts/verify_issue_11.sh` — PASS confirmed after the interrupted session: the process completed after the pinned Godot C++ build and its final smoke artifact contained the required values above. The terminal wrapper exit-code line was not retained after interruption.

Self-review found no production-file changes, no new architecture, no persistence/session additions, no scene changes, and no real secret material. Generated Godot `.uid`/import files remain untracked and were not included in the commit. No GitHub comment was posted.

## Final narrow license-evidence fix

The smoke canary path now uses the real `LicenseProviderScript` created by `FlightRuntime._configure_license_provider()`. The prior `SmokeFailingLicenseProvider` fake was removed. The empty `{}` configuration remains a separate real-provider missing-configuration assertion, while the canary case uses a complete-looking config with a deliberately missing public-key path and distinct non-secret token, key, customer, and claim canaries. The blocked screen/error/status and real provider’s sanitized snapshot are serialized and checked against every exact canary.

TDD evidence: the new real-provider assertion was added first. The first smoke run was red only because the assertion inverted the expected `false` result from invalid configuration; the exact root cause was `not _configure_license_provider(...)` in the test. Removing `not` was the minimal test-only correction. No production defect or production-file change resulted.

Final validation:

- `GODOT_BIN=/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 scripts/run_headless_smoke.sh --output build/headless_smoke.json --frames 5` — PASS; `completed=true`, `native_probe=47`, `simulated_frames=5`, `trajectory_stride=12`.
- `GODOT_BIN=/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 scripts/run_gut_tests.sh --recovery-mode` — PASS; 179 tests, 0 failures, 11 expected native-dependent pending tests.
- `GODOT_BIN=/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 RUNNER_TEMP=/tmp/aerosim-ci-43 scripts/verify_issue_11.sh` — EXIT 0. Final stdout printed the required artifact dictionary: `completed=true`, `native_probe=47`, `simulated_frames=5`, `trajectory_stride=12`, plus all public-path and collision assertions true. The pinned Godot C++ build, native tests, license checks, and final smoke therefore completed successfully.

This final fix remains smoke/report-only; no GitHub comment was posted.

## Final Sol whole-branch fix wave

### Scope and implementation

This review wave changed only the existing runtime, GUT coverage, headed acceptance, and this report. It added no scene, persistence, runtime/session, diagnostics system, PRD, or product decision.

- `flight_exit` now cancels an active `controller_confirmation` or `fallback_prompt` through `_cancel_controller_route()`. Escape and gamepad B therefore return to Main Menu for menu/Quick Fly callers and Controller Settings for reset callers, without calling `request_exit`.
- `_complete_controller_route()` rechecks `can_start_quick_fly()` immediately before its sole preflight transition. A confirmation/fallback completed after an expired or revoked snapshot now presents the existing blocked-license route rather than loading preflight.
- Confirmation focuses `UseXboxDefaultProfile`; fallback focuses its visible keyboard-fallback primary action. Lab Mode exposes an existing-HUD `BACK TO MENU` button, focused while visible and wired to `return_from_lab_mode()`.
- Failed activation and retry paths record only `error_type` and `error_code` as `License <type> failed: <code>` before reconciliation. The existing Diagnostics route therefore shows the current sanitized reason and does not surface provider `error` payload text.
- Headed acceptance now injects a deterministic valid test provider, asserts the exact seven-entry menu, exercises Drone/Map shared Flight Setup, Lab/Back/Escape, real Quit, the actual reset confirmation return, and Quick Fly’s actual confirmation route.

### TDD evidence

1. Added focused GUT assertions first for Escape/B cancellation across main-menu, controller-settings, and Quick Fly callers; confirmation/fallback revocation between route start and completion; focus ownership; actual Lab/Back control navigation; and sanitized activation/retry Diagnostics text.
2. The first direct focused GUT command could not start because the GUT global class cache had not been imported (`Missing class_names: ["GutErrorTracker", "GutHookScript", "GutInputFactory", "GutInputSender", "GutMain", "GutStringUtils", "GutTest", "GutTrackedError", "GutUtils"]`). The prescribed recovery import restored that cache.
3. The red focused run then failed for the requested missing behavior: Escape/B invoked `request_exit`, invalidated controller routes entered preflight, focus was unset, Lab Back did not exist, and failed provider actions left Diagnostics stale. The initial bare-runtime test fixture also produced a null-tree cleanup error when the obsolete `request_exit` path ran; the fixture was narrowed to attached UI layers so green tests do not execute full scene startup.
4. Implemented the minimum runtime code above. The focused recovery-mode GUT retry passed `37/48` with `11` expected native-extension pending tests and `271` assertions.
5. The first focused green invocation experienced one Godot 4.7 signal-11 crash with no GDScript error output. An immediate identical retry completed normally, and the required full recovery suite, smoke, headed acceptance, and Ubuntu verification all passed. This was treated as a transient runner event, not bypassed.

### Final validation

- Focused recovery GUT: direct `gut_cmdln.gd -gtest=res://tests/gut/test_flight_runtime_load.gd` — PASS on retry: 37 passing, 11 expected recovery-mode pending, 271 assertions.
- `GODOT_BIN=/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 scripts/run_gut_tests.sh --recovery-mode` — PASS: 183 tests, 0 failures, 0 errors; 11 expected native-dependent pending tests.
- `GODOT_BIN=/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 scripts/run_headless_smoke.sh --output build/headless_smoke-final-sol.json --frames 5` — PASS (exit 0). Godot emitted the existing non-fatal Jolt job-system warning.
- `GODOT_BIN=/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 scripts/run_headed_acceptance.sh --xvfb --out-dir build/headed-final-sol` — PASS (exit 0). It produced the required report/screenshots; the existing deliberate missing-map assertion emitted its expected warnings.
- `GODOT_BIN=/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 RUNNER_TEMP=/tmp/aerosim-ci-43 scripts/verify_issue_11.sh` — PASS (exit 0).

### Self-review

- Checked the final diff for scope, formatting, route targets, license-message provenance, and control visibility/focus. No production defect beyond the reviewed gaps emerged.
- Generated Godot `.uid` and `.import` artifacts remain untracked and are excluded from the commit.
- No GitHub comment was posted. Human visual review remains deferred until the Playable Game Milestone.
