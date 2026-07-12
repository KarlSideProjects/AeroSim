# Controller Settings Report

## Delivered

- Added `Settings > Controller` with the currently selected device, immutable Xbox four-axis mapping, `0.080` deadzone, Arm/Mode pressed state, and `RESET TO XBOX DEFAULT`.
- Reset returns to the existing Xbox confirmation gate; it does not silently create or authorize a session profile.
- The runtime now follows `Input.joy_connection_changed` so Quick Fly evaluates the currently connected device after replacement.
- Headless and headed harnesses cover Settings > Controller and replace a confirmed known device through the Godot connection signal with an unknown device before calling `quick_fly()`.

## TDD Evidence

1. RED: the initial Settings assertion failed with `Settings entry must open the Settings screen` before the runtime UI existed.
2. GREEN: the Settings implementation made the headless smoke proceed to the replacement-device assertion.
3. RED: the replacement assertion failed before the runtime tracked `joy_connection_changed`.
4. GREEN: the runtime now tracks connection changes and Quick Fly reaches explicit KeyboardProfile fallback without calling the confirmation helper or overwriting the session device id.
5. Headed acceptance exposed the flight HUD covering the Settings button. Hiding that HUD while Settings is open produced a passing real-display report.

## Verification

| Check | Result |
|---|---|
| `scripts/test_native.sh` | PASS |
| `Godot --headless --path . --script res://common/smoke/headless_smoke.gd -- --runtime-only` | PASS |
| `GODOT_BIN=... scripts/run_headless_smoke.sh --frames 5` | PASS; JSON reports 5 frames and 800 Jolt trials |
| `GODOT_BIN=... scripts/run_headed_acceptance.sh` | PASS; real display used NVIDIA GeForce RTX 4060 Ti and `build/headed/report.json` has no failures |
| `scripts/run_performance_benchmark.sh --mode smoke --warmup-seconds 0 --seconds 1 --effects off` | BLOCKED: required `.deps/godot-cpp` checkout is absent |
| `git diff --check` | PASS |

## Concerns

- Benchmark smoke is not verified because `.deps/godot-cpp` is absent. No fallback benchmark mode was substituted.
- The harness emits Godot's `joy_connection_changed` signal to model a physical replacement; the unknown replacement id is asserted with `Input.is_joy_known() == false`, and routing still starts at `quick_fly()`.
