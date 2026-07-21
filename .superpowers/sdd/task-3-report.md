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
