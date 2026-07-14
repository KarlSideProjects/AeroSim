# Industrial Yard validation

Commit: `01dc2e52bfc7ce18653cfbd9ee262bc790716b1f`

The #35 slice preserves one renderer-shared `industrial_yard.tscn`, validates its descriptor and collision landmarks, loads it through Quick Fly, resets to `SpawnNorth`, uses that marker as the AirSim NED origin, and exits by freeing the loaded map.

Validation results:

- `scripts/test_shared_map_assets.sh` and `scripts/check_shared_map_assets.sh`: pass.
- `scripts/test_native.sh`: pass.
- `scripts/check_hardcoded_airframe_constants.sh`: pass.
- `scripts/test_license_scan.sh`: pass.
- `python3 -m unittest license_server.test_license_server`: 6 tests pass.
- `GODOT_BIN=... scripts/run_gut_tests.sh --recovery-mode`: 9 scripts, 52 tests, 233 assertions pass.
- `GODOT_BIN=... scripts/run_headed_acceptance.sh`: pass with report `passed: true`, required screenshots, exit cleanup, and zero AirSim NED position at `SpawnNorth`.
- `GODOT_BIN=... scripts/run_headless_smoke.sh --output build/headless_smoke.json --frames 5`: pass; artifact reports `completed: true`, `native_probe: 47`, `jolt_collision_trials: 800`, and five trajectory rows.

The headless log contains expected negative-path diagnostics for rejected `missing_map`, RPC listener setup in the harness, and an invalid hardware preset; the command and artifact passed. No AirSim upstream source path or symbol was copied or adapted in this slice, so the AirSim reference audit is not applicable.

Before CAP-006, visual evidence remains provisional. The fixed-view evidence and its hashes are in `industrial-yard-visual-verification.json`; no human visual review is requested.
