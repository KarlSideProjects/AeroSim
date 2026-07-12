# #40 Xbox Default Profile Validation

Validated implementation commit: `598daef` (`fix: harden xbox confirmation routing`)

## Automated

- PASS (exit 0): `scripts/test_native.sh`.
- PASS (exit 0):
  ```bash
  RUNNER_TEMP="/tmp/opencode" AEROSIM_TOOL_ROOT="/tmp/opencode/aerosim-tools-issue-40-task3" GODOT_BIN="/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64" scripts/verify_issue_11.sh
  ```
  This job-local run completed native tests, licence scan, pinned `godot-cpp` build, native extension build, and its five-frame full smoke. Its JSON reported `native_probe: 47` and `simulated_frames: 5`.
- PASS (exit 0):
  ```bash
  XDG_CACHE_HOME="/tmp/opencode/aerosim-tools-issue-40-task3/xdg-cache" XDG_CONFIG_HOME="/tmp/opencode/aerosim-tools-issue-40-task3/xdg-config" XDG_DATA_HOME="/tmp/opencode/aerosim-tools-issue-40-task3/xdg-data" /home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 --headless --path . --script res://common/smoke/headless_smoke.gd -- --runtime-only
  ```
  The runtime smoke verifies known-controller confirmation, the fixed Xbox mapping, session profile creation, replacement-controller reconfirmation, and explicit KeyboardProfile fallback for an unsupported controller.
- PASS (exit 0):
  ```bash
  XDG_CACHE_HOME="/tmp/opencode/aerosim-tools-issue-40-task3/xdg-cache" XDG_CONFIG_HOME="/tmp/opencode/aerosim-tools-issue-40-task3/xdg-config" XDG_DATA_HOME="/tmp/opencode/aerosim-tools-issue-40-task3/xdg-data" GODOT_BIN="/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64" scripts/run_headless_smoke.sh --frames 5
  ```
  `build/headless_smoke.json` recorded `native_probe: 47`, `simulated_frames: 5`, `trajectory_samples: 5`, and `jolt_collision_trials: 800`.

The two `invalid_out_of_range.json: battery.cells out of range` diagnostics are expected checks of the intentionally invalid fixture; every command above exited 0.

## Real-Display Headed Acceptance

- PASS (exit 0):
  ```bash
  XDG_CACHE_HOME="/tmp/opencode/aerosim-tools-issue-40-task3/xdg-cache" XDG_CONFIG_HOME="/tmp/opencode/aerosim-tools-issue-40-task3/xdg-config" XDG_DATA_HOME="/tmp/opencode/aerosim-tools-issue-40-task3/xdg-data" GODOT_BIN="/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64" scripts/run_headed_acceptance.sh
  ```
  The non-Xvfb run used `DISPLAY=:0` with `/tmp/.X11-unix/X0`; Godot reported `NVIDIA GeForce RTX 4060 Ti`. `build/headed/report.json` was `{"failures":[],"passed":true}`.
- This automated acceptance verifies the visible Xbox default-profile confirmation, fixed-axis values, confirmation routing, KeyboardProfile fallback, and the flight UI progression. It does not substitute for a human hardware playthrough.

## Handoff and Limits

- Confirmed fixed mapping: GamepadProfile schema version 1, Roll/Pitch/Yaw/Throttle on axes 0/1/2/3, pitch reversed, Arm on A, and Mode on Y. The session profile remains in memory only.
- #49 owns persistence, serialized-schema validation, import/export, reconnect behavior, and later schema migration.
- Maintainer Xbox 360-compatible hardware playthrough remains unverified and required before #40 can close. This report makes no calibration, endpoint, reverse-detection, or manual-mapping claim.
