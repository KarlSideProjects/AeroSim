# Xbox Flight Controls Report

Date: 2026-07-12

## Scope Delivered

- Confirmed `GamepadProfile` now samples its fixed Xbox axes during the runtime physics path.
- Sticky throttle replaces the fixed flight throttle only for an active confirmed gamepad profile; KeyboardProfile retains its existing fixed fallback behavior.
- Roll, pitch, and yaw now feed Angle/Altitude Hold and ACRO callers. The #106 ACRO helper functions were not changed.
- Arm reads the live profile throttle raw axis and rejects values above `GamepadProfile.THROTTLE_LOW_THRESHOLD` (`0.08`).
- Raw active-device `InputEventJoypadButton` handling tracks Arm/Mode press and release, debounces repeated presses for 50 ms, and shows throttle/button state in the flight HUD.
- Fixed Xbox mapping, SDL-known-device filtering, unknown-device KeyboardProfile fallback, and no-calibration/no-manual-mapping scope remain unchanged.
- The confirmation panel continues to monitor live axes from a known detected Xbox device; only the accepted session profile can control flight or Arm/Mode.

## TDD Evidence

The first new runtime smoke run failed before implementation with:

```
ERROR: Confirmed Xbox profile must show the live high throttle state before arming
```

The discriminating smoke coverage injects a known SDL controller and verifies:

- high live throttle blocks Arm;
- low live throttle permits Arm;
- high versus low profile throttle yields different native motor thrust;
- non-zero Xbox roll/pitch/yaw produces Angle and ACRO native angular response;
- Arm/Mode press and release are visible in the HUD;
- a second Mode press inside 50 ms is ignored and one after the debounce window is accepted.

## Reviewer P2 Follow-up

- Added explicit deadzone assertions: all roll/pitch/yaw output is zero at raw `0.04`.
- Added pitch reversal assertions: raw `+0.50` produces negative processed pitch and raw `-0.50` produces positive processed pitch.
- Added an Altitude Hold runtime assertion using processed profile roll/pitch/yaw and a non-zero native angular response after resetting the body state.
- Replaced wall-clock sleeps in debounce coverage with an injected timestamp source. Arm and Mode independently prove accepted press at `0`/`100` ms, rejection at `49`/`149` ms, and acceptance at `50`/`150` ms; release HUD state remains observable after rejected presses.

The new deterministic-clock smoke first failed before implementation with:

```
ERROR: Flight runtime must accept an injected button timestamp source for deterministic debounce tests
```

## Validation

Passed:

```text
/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 --headless --path . --script res://common/smoke/headless_smoke.gd -- --runtime-only --frames 5
GODOT_BIN=/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 scripts/run_headless_smoke.sh --frames 5
scripts/test_native.sh
git diff --check
python3 -m json.tool build/headless_smoke.json
```

The full smoke produced valid JSON and trajectory artifacts, reporting 5 simulated frames and 800 Jolt collision trials. It emitted the expected invalid-preset rejection messages from the existing hardware-config negative-path test.

## Benchmark

The repository's job-local build method supplied the locked `godot-cpp` checkout and rebuilt the debug GDExtension:

```text
RUNNER_TEMP=/tmp/opencode AEROSIM_TOOL_ROOT=/tmp/opencode/aerosim-tools-issue40-review GODOT_BIN=/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 scripts/verify_issue_11.sh
```

The headed smoke benchmark then completed using that checkout:

```text
GODOT_BIN=/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 GODOT_CPP_DIR=/tmp/opencode/aerosim-tools-issue40-review/godot-cpp SCONS_BIN=/tmp/opencode/aerosim-tools-issue40-review/scons-venv/bin/scons scripts/run_performance_benchmark.sh --mode smoke --warmup-seconds 0 --seconds 1 --effects off --output build/xbox-flight-controls-benchmark.json
```

`build/xbox-flight-controls-benchmark.json` reports smoke mode, 240 samples, NVIDIA GeForce RTX 4060 Ti, P99 `0.552 ms`, and `p99_within_limit=true`. This is a smoke result, not the frozen 10+60 second G0.1 gate.
