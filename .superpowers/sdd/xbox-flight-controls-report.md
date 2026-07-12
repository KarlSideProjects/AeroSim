# Xbox Flight Controls Report

Date: 2026-07-12

## Scope Delivered

- Confirmed `GamepadProfile` now samples its fixed Xbox axes during the runtime physics path.
- Sticky throttle replaces the fixed flight throttle only for an active confirmed gamepad profile; KeyboardProfile retains its existing fixed fallback behavior.
- Roll, pitch, and yaw now feed Angle/Altitude Hold and ACRO callers. The #106 ACRO helper functions were not changed.
- Arm reads the live profile throttle raw axis and rejects values above `GamepadProfile.THROTTLE_LOW_THRESHOLD` (`0.08`).
- Raw active-device `InputEventJoypadButton` handling tracks Arm/Mode press and release, debounces repeated presses for 50 ms, and shows throttle/button state in the flight HUD.
- Fixed Xbox mapping, SDL-known-device filtering, unknown-device KeyboardProfile fallback, and no-calibration/no-manual-mapping scope remain unchanged.

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

Not verified. The requested smoke benchmark failed loudly before rebuilding or running because the required dependency is absent:

```text
godot-cpp checkout is required: .deps/godot-cpp
```

Command attempted:

```text
GODOT_BIN=/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 scripts/run_performance_benchmark.sh --mode smoke --warmup-seconds 0 --seconds 1 --effects off --output build/xbox-flight-controls-benchmark.json
```

No alternate checkout, display setup, or benchmark configuration was substituted.
