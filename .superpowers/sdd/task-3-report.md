# Task 3: Complete remaining routes and cold-start evidence

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
