# Final fix report — #303–#306

## Commit

- `1e1ebe1 fix: harden GSP PX4 telemetry and wind ACKs (#303 #304 #305 #306)`

## Fixed findings

- `ATTITUDE_TARGET` now reads the quaternion as `w@4/x@8/y@12/z@16`, omits ignored attitude/body-rate targets, and retains its type mask. `POSITION_TARGET_LOCAL_NED` requires `MAV_FRAME_LOCAL_NED` and omits masked position, velocity, yaw, and yaw-rate fields.
- HIL actuator observability exposes M1–M4 only when the configured `HilActuatorQuadXOrder` exactly verifies the active canonical Quad-X order. The pinned PX4 Iris settings supply that mapping; absent mapping preserves the received sample but reports `mapping_verified: false` and no command fields.
- The GSP console reads only `px4_mavlink.hil_actuator_controls.sample.command_normalized`; it labels PX4 command freshness, freezes command history on stale data, freezes stale visual estimates, derives RPM plot scale from `hardware_power_model.max_motor_rpm`, and localizes wind success/rejection text in zh-TW/en.
- The panel bundle now installs and hashes `THREE-LICENSE` and `asset_notes.md`.
- A GSP wind transaction now fails with `replay_recording_failed` when recording is failed and restores environment/native wind boundaries before ACKing failure.

## Focused evidence

- `node tests/test_gsp_panel_behavior.js` — passed.
- `node tests/test_gsp_visual_state.js` — passed.
- `node tests/test_gsp_issue305_console.js` — passed.
- `node tests/test_gsp_panel_recovery.js` — passed.
- `GODOT_BIN=/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 ...gut_cmdln.gd ...test_px4_sitl_bridge.gd...` — passed: 315 tests, 0 failures, 11 pre-existing recovery pending. The runner currently executes the GUT suite despite the focused selector. Native extension is absent in this worktree; recovery-mode tests still exercised the parser/launcher contracts.
- `GODOT_BIN=/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 --headless --path . --script res://tests/headless/gsp_wind_contract.gd` — passed (exit 0). Godot reports the missing native extension at start, but this focused fake-native contract passed.
- `scripts/test_px4_sitl_launcher.sh --check` — passed pinned-source contract.
- `git diff --check` — passed before commit.

## Gaps kept explicit

- No authentic PX4 wind-step qualification was run: this worktree lacks both the pinned PX4 checkout/build and native extension. The existing mission remains smoke; no fresh-actuator, mapping, lean, replay-identity, or frozen RMS/max hold result is claimed.
- The authentic browser harness was not expanded/run for 480×854, 560×996, and 640×1138. It still requires its normal Godot-launched local bundle/Chrome environment; no no-scroll/keyboard/offline visual qualification is claimed.
- #302 geometry was not changed or claimed. No computer-use validation was run and no GitHub issue was closed.

## Final qualification follow-up

- Added `scripts/px4_wind_step_qualification.py` and `scripts/test_px4_sitl_launcher.sh --wind-step-qualification`. The distinct real-PX4 gate accepts only evidence for the pinned revision with real exclusive authority, matching applied/replay tick and replay identity, fresh explicitly mapped actuators, an observed lean, and frozen RMS/max position-error limits. Missing evidence writes `unavailable` and returns failure; it does not claim a simulated or fake PX4 result.
- Extended the installed `file://` Chrome harness (not a DOM substitute) across 480×854, 560×996, and 640×1138. It verifies no live-console scroll or out-of-bounds elements, keyboard focusability, both locales, file-only/offline resources, and stale PX4 command-source rendering. The test hook only injects a stale telemetry sample into the real loaded panel to exercise its presentation boundary.

## Follow-up evidence

- `python3 -m unittest tests.test_px4_wind_step_qualification tests.test_gsp_portrait_browser_contract` — passed (5 tests).
- `AEROSIM_GSP_BROWSER_HEADLESS=1 GODOT_BIN=/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 python3 scripts/test_gsp_panel_browser.py` — qualified; all three portrait sizes passed the authentic installed-bundle checks.
- `python3 scripts/px4_wind_step_qualification.py --output /tmp/aerosim-px4-wind-step.json` — expected exit 2 and `unavailable`: this checkout has no authentic PX4 wind-step evidence. No qualification result is claimed.
- `node tests/test_gsp_panel_behavior.js`, `node tests/test_gsp_visual_state.js`, `node tests/test_gsp_issue305_console.js`, `scripts/test_px4_sitl_launcher.sh --check`, and `git diff --check` — passed.
