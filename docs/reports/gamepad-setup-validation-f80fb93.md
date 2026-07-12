# #40 Gamepad Setup Validation

Validated commit: `f80fb93` (`test: make quick fly calibration smoke discriminating`)

## Automated

- PASS (exit 0):
  ```bash
  RUNNER_TEMP="/tmp/opencode" AEROSIM_TOOL_ROOT="/tmp/opencode/aerosim-tools-issue-40" GODOT_BIN="/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64" scripts/verify_issue_11.sh
  ```
  The job-local build completed native tests, licence scan, native extension build, and five-frame smoke. Its smoke JSON reported `native_probe: 47` and `simulated_frames: 5`.
- PASS (exit 0): `scripts/test_native.sh`.
- PASS (exit 0): `tests/headless/gamepad_calibration_contract.gd` with the fixed Godot path.
- PASS (exit 0):
  ```bash
  GODOT_BIN="/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64" scripts/run_headless_smoke.sh --frames 5
  ```
  The external command wait allowance was 1,200 seconds. `build/headless_smoke.json` and `build/headless_trajectory.csv` were created; JSON verification confirmed `native_probe: 47` and `simulated_frames: 5`.

The smoke runs emitted the expected diagnostics for the intentionally invalid `config/drones/invalid_out_of_range.json` fixture and exited 0.

## Linux Headed

- PASS (exit 0): `GODOT_BIN="/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64" scripts/run_headed_acceptance.sh --xvfb`.
  This is regression evidence only. Godot used llvmpipe and emitted an XIM warning.
- PASS (exit 0): `GODOT_BIN="/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64" scripts/run_headed_acceptance.sh`.
  The local X11 display prerequisite was present as `DISPLAY=:0` with `/tmp/.X11-unix/X0`. Godot reported `NVIDIA GeForce RTX 4060 Ti`.
- Real-display evidence: `build/headed/report.json` is `{"failures":[],"passed":true}`. Screenshots are `00_cold_start.png`, `01_controller_setup.png`, `01_quick_fly.png`, `02_takeoff.png`, `03_paused.png`, `04_reset.png`, and `05_exit.png`.
- The headed acceptance checks active `Camera3D` at cold start and asserts every snapshot's maximum single-color ratio is below 0.99. The no-failures report therefore verifies both conditions.

The acceptance was executed against the local real display. Human observation of the Godot window was not independently performed by this automated run.

## Not Verified

- Xbox 360-compatible hardware playthrough: awaiting @jhihweijhan. This report does not claim it was completed.
- Cross-session persistence, import/export, and reconnect: #49 scope; not claimed as complete.

## PR Body (Not Posted)

```markdown
Refs #40

## Scope

- Implements session-only Gamepad Setup and CalibrationProfile.
- Does not implement #49 persistence, import/export, or reconnect.

## Verification

- Link the automated and real-display headed report.

## Not verified

- Maintainer Xbox 360-compatible gamepad playthrough remains required before #40 can close.
```

No PR was opened and no GitHub issue was modified.
