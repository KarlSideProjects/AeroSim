# Task 4: Persistent physical four-motor HUD

## Delivered

- Added a permanent `FlightHud` Quad-X motor panel in physical nose-up order: `FL FR / RL RR` from frozen telemetry order `[RR, FR, RL, FL]`.
- Reused the status diagram's publish-count and receipt-age freshness path; the HUD performs no native polling, simulation mutation, or replay change.
- Each cell renders localized N, RPM (converted from rad/s), A, and a textual saturation marker. Invalid, incomplete, stale, paused, and atomic-error states render explicit unavailable/error cells.
- Kept the panel outside the OSD profile and moved only the default reset hint while the panel is visible to preserve readable, non-overlapping overlays.
- Added headed report evidence under `motor_hud` using the existing `03_takeoff.png` artifact.

## TDD evidence

### RED

`GODOT_BIN=/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 scripts/run_gut_tests.sh`

The three new status-diagram tests failed as expected because `get_motor_hud_state` did not exist. The run also contained the pre-existing replay checkpoint failure in `test_runtime_replay_records_and_replays_two_bound_native_vehicles`.

### GREEN

`GODOT_BIN=/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 /home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 --headless --path . --script res://addons/gut/gut_cmdln.gd -- -gconfig= -gtest=res://tests/gut/test_status_diagram_vehicle_selector.gd,res://tests/gut/test_flight_runtime_load.gd -gunit_test_name=motor_hud -gexit -gdisable_colors`

Passed: 4 tests, 24 assertions. Coverage includes physical mapping, rad/s→RPM, N/RPM/A, saturation text, localization, malformed/non-finite/incomplete data, stale receipt age, paused/error state, and Minimal-preset visibility.

## Headed evidence

`GODOT_BIN=/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 scripts/run_headed_acceptance.sh --xvfb --out-dir build/headed-task4`

Passed. `build/headed-task4/report.json` records physical labels `FL`, `FR`, `RL`, `RR`, visibility under Minimal, and `build/headed-task4/03_takeoff.png`. Codex visual inspection confirmed all four cells are readable and fit at 1280×720.

## Known unrelated gate

The complete GUT suite remains blocked by the existing replay test failure: `checkpoint.controller[1].mode_or_clock` in `test_runtime_replay_records_and_replays_two_bound_native_vehicles`. The Task 4 tests pass.
