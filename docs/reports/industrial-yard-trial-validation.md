# Industrial Yard time-trial validation

Implementation commit: `8b9d763`; pause-clock evidence refinement: `2ead0c5`.

The #38 slice adds a scene-authored Industrial Yard route with three ordered checkpoints and a finish marker. `TimeTrial` advances only on simulation physics frames, rejects skipped checkpoints, resets at `SpawnNorth`, and drives the Player HUD finish, Retry, pause, Change Map, and Exit states.

Validation results:

- `GODOT_BIN=... scripts/run_gut_tests.sh --recovery-mode`: 10 scripts, 55 tests, 244 assertions pass.
- `GODOT_BIN=... scripts/run_headed_acceptance.sh --xvfb`: pass; headed evidence covers route discovery, finish state, Retry, pause/resume, Change Map, respawn, and Exit.
- `GODOT_BIN=... scripts/test_industrial_yard_renderers.sh`: pass for `forward_plus` and `mobile`, including route markers and Finish.
- `GODOT_BIN=... scripts/run_headless_smoke.sh --output build/headless_smoke.json --frames 5`: pass; `completed=true`, `simulated_frames=5`, `desktop_substeps=20`, `mobile_substeps_1s=500`, `native_probe=47`, `jolt_collision_trials=800`, and all public-path invariants true.
- `git diff --check`: pass.

The existing #35 gates remain intact: shared-map asset checks, native tests, hardcoded-airframe checks, license scan, license-server tests, and the Industrial Yard renderer smoke continue to pass. No AirSim source path or symbol was copied or adapted for this slice, so the AirSim reference audit is not applicable.

Before CAP-006, visual evidence remains provisional. Fixed-view evidence is recorded in `industrial-yard-trial-visual-verification.json`; no human visual review is requested.
