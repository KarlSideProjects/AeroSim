# Task 2 Report: Industrial Yard Map Lifecycle

Status: DONE with full-smoke concern recorded below.

## Delivered

- Commit `47f90cd feat: load industrial yard free flight` adds `load_map("industrial_yard")`, `reset_to_spawn()`, explicit missing-map errors, and exit cleanup returning to the main-menu stub.
- Quick Fly preflight loads Industrial Yard and places the drone at `SpawnNorth`.
- Reset clears linear and angular velocity at `SpawnNorth`; exit stops runtime flight, frees `LoadedMap`, and returns to `main_menu`.
- The reviewer follow-up binds lifecycle validation to Industrial Yard: headless asserts the active `ChaseCamera` before and after reset, while headed captures `build/headed/01_industrial_yard_preflight.png` and asserts that frame is non-monochrome.

## TDD Evidence

1. The original lifecycle assertions were added before `47f90cd`; runtime-only smoke failed because `flight_runtime.gd` did not expose `loaded_map_id`.
2. The lifecycle implementation was then added and runtime-only smoke passed.
3. This reviewer correction adds coverage only: it does not change production lifecycle behavior.

## Validation

| Command | Result |
| --- | --- |
| `/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 --headless --path . --script res://common/smoke/headless_smoke.gd -- --runtime-only` | Exit 0. The expected `missing_map` fail-loud assertions emit explicit errors. |
| `GODOT_BIN=/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 scripts/run_headed_acceptance.sh --xvfb` | Exit 0. `build/headed/report.json` is `{"failures":[],"passed":true}`; Industrial Yard preflight capture, reset, and exit assertions ran. |
| `GODOT_BIN=/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 scripts/run_headless_smoke.sh --frames 5` | Not verified: the command did not finish within 900 seconds. No `build/headless_smoke.json` or `build/headless_trajectory.csv` artifact was written. |
| `git diff --check` | Exit 0; no whitespace errors. |

## Concerns

- Full headless smoke remains unverified. Its existing 800 Jolt collision trials did not complete within the 900-second command limit; no fallback runner or reduced test scope was used.
