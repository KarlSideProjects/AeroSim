# Controller Settings Report

## Delivered

- Added `Settings > Controller` with the currently selected device, immutable Xbox four-axis mapping, `0.080` deadzone, Arm/Mode pressed state, and `RESET TO XBOX DEFAULT`.
- Reset returns to the existing Xbox confirmation gate; it does not silently create or authorize a session profile.
- Added a `DeviceState` seam. Production reads `Input.get_connected_joypads()` and `Input.is_joy_known()` through it; test-only adapters supply mutable device snapshots.
- Quick Fly, profile eligibility, Controller device display, fallback status, and the connection handler all read the same `DeviceState` seam.
- Headless and headed harnesses first confirm a known profile, then replace the adapter snapshot with empty and unknown states, emit the Godot connection event, and call `quick_fly()` to reach fallback.

## TDD Evidence

1. RED: the initial Settings assertion failed with `Settings entry must open the Settings screen` before the runtime UI existed.
2. GREEN: the Settings implementation made the headless smoke proceed to the replacement-device assertion.
3. RED: the new harness failed with `Invalid assignment of property or key 'gamepad_device_state'` before the runtime exposed an injectable dependency seam.
4. GREEN: the runtime now reads the mutable adapter after the connection event. The empty snapshot refreshes `No controller` fallback status; the unknown snapshot is rejected by `quick_fly()` without calling the confirmation helper or overwriting the session device id.
5. Headed acceptance verifies the same snapshot replacement and reports no failures.

## Verification

| Check | Result |
|---|---|
| Job-local `scripts/verify_issue_11.sh` with locked `godot-cpp` and SCons | PASS; native tests, extension rebuild, and full smoke complete |
| `Godot --headless --path . --script res://common/smoke/headless_smoke.gd -- --runtime-only` | PASS after adapter seam implementation |
| Job-local full smoke | PASS; JSON reports 5 frames and 800 Jolt trials |
| `GODOT_BIN=... scripts/run_headed_acceptance.sh` | PASS; real display used NVIDIA GeForce RTX 4060 Ti and `build/headed/report.json` has no failures |
| G0.1 effects off benchmark | PASS; 14,400 samples, P95 `0.551 ms`, P99 `0.685 ms` / `3.0 ms` |
| G0.1 effects on benchmark | PASS; 14,400 samples, P95 `0.524 ms`, P99 `0.629 ms` / `3.0 ms` |
| `git diff --check` | PASS |

## Concerns

- The benchmark used the repository's job-local build flow at `/tmp/opencode/aerosim-tools-controller-settings`: locked `godot-cpp` `ba0edfed90512ec64aba51d4295a3e7e30112f86` and its generated SCons executable. Both reports are gate-eligible `G0.1` results, not smoke substitutes.
- Benchmark startup emitted pre-existing GDScript warnings in `hardware_config.gd` and `collision_probe_body.gd`; both benchmark commands exited successfully and their reports have `gate_verdict: "pass"`.
