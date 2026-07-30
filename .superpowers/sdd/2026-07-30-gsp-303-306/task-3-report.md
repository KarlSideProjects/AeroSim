# Task 3 — Issue #305 report

## Scope and files

- `common/gsp/gsp_panel.html`: adds the portrait-first `即時狀態` operational surface, preserved scrollable `工程設定`, wind preview/apply/ACK status, a persistent authority/freshness/failure strip, source labels, M1–M4 summaries, and Canvas command/RPM traces. The only scripts remain vendored `three-0.180.0.global.min.js` and `gsp_visual.js`.
- `common/gsp/assets/gsp_visual.js`: adds a dashed non-colour-only ground-truth ghost beside the PX4 estimated Drone; the generated frame is explicitly nominal.
- `tests/test_gsp_issue305_console.js`: focused DOM/offline bundle contract.

## Acceptance evidence

- `即時狀態` is initially a fixed-height `#live-console` with `overflow: hidden`; `工程設定` is hidden until its keyboard-operable button is activated and is intentionally scrollable.
- Wind uses #303's `set_wind` with preview followed by explicit apply. The UI reports pending request, ACK/rejection, meteorological from, resolved toward, and does not mutate presentation physics before the ACK.
- Source text does not merge classes: Commanded uses `commanded_motor_normalized` only when present; Ground truth is local simulation; Estimated is the #304 `px4_mavlink.local_position_ned` only when present; Measured RPM is local simulation. Missing classes remain unavailable.
- The 3D main frame is labeled `Nominal geometry`; the truth ghost is shown only when both PX4 estimated and local truth positions exist. No real asset or real-geometry statement was added.
- Stale display says `STALE — frozen`; wind Apply disables when data is stale, replay is active, authority is unavailable, or the session is not ready. Motor plots retain their last data rather than substituting zeros.
- Reduced motion uses a dashed static outline; source, stale and health use text/borders as well as color.

## Test results

Passed:

```text
node tests/test_gsp_issue305_console.js
node tests/test_gsp_visual_state.js
node tests/test_gsp_panel_behavior.js
node tests/test_gsp_panel_recovery.js
python3 -m unittest tests.test_gsp_issue251_contract
```

The new DOM contract checks the live/engineering labels, nominal geometry, four source classes, wind controls, both canvases, fixed no-scroll live surface, reduced-motion rule, and no network/non-local script URLs.

## Local browser/viewport evidence

Attempted:

```text
AEROSIM_GSP_BROWSER_HEADLESS=1 python3 scripts/test_gsp_panel_browser.py
```

Result: deferred because `godot` is not installed in this worktree environment (`[Errno 2] No such file or directory: 'godot'`). Chrome is installed, but the existing local `file://` bundle browser harness requires Godot to launch/authenticate the normal GSP channel. Therefore there is no false claim of headed 480×854, 560×996, or 640×1138 browser evidence; rerun that command with `GODOT_BIN` set, then execute the headed gate on a DISPLAY/Wayland session.

## Intentionally held for #302

Issue #302's qualified model, real scale, real M1–M4 locations and spin-direction evidence are not implemented or claimed. This task preserves only the procedural `Nominal geometry` visualization. #305 must remain open until that dependency and its qualification evidence land.

## Out of scope

No physics authority, replay timing, flight-control behavior, transport validation, dependencies, or network assets changed. #306 qualification work was not started.

## Fix round 1 evidence

- Solid nominal Drone now consumes PX4 `local_position_ned` and `attitude` as the Estimated transform; the dashed Ground truth ghost remains at the local simulation transform. Both are explicitly source-labelled, and no real geometry claim was introduced.
- Wind controls join the readiness inventory and lock from request send through ACK/rejection, preventing concurrent mutation.
- Source spans remain individually styled after telemetry updates; Commanded traces are dashed and measured-RPM traces solid. New behavioral coverage checks localization, source labels, authoritative motor details, and the wind pending/rejection lock.
- The only renderer is now the live renderer; view controls moved there, avoiding hidden duplicate engineering controls/canvas.

Fresh focused verification: `node tests/test_gsp_panel_behavior.js`, `node tests/test_gsp_issue305_console.js`, `node tests/test_gsp_visual_state.js`, `node tests/test_gsp_panel_recovery.js`, and `python3 -m unittest tests.test_gsp_issue251_contract` all passed. The browser harness remains blocked by missing `godot`.

## Fix round 2 evidence

- A single `windMutationSafe()` predicate now gates every wind control on readiness, fresh non-stale telemetry, non-replay state, available authority, and no pending ACK. It runs both after telemetry and ACK/rejection, so a stale/replay/unavailable authority cannot briefly re-enable mutation.
- Added zh-TW/en labels for the wind direction/control state, view controls, plot labels/legend, source suffixes, and motor detail fields.
- Motor location is emitted only from authoritative `motor.location` or configured `motor_positions`; otherwise the card explicitly says unavailable. Nominal visual positions are never presented as telemetry.
- Focused panel behavior now checks the request lock/rejection path and unavailable motor location. Focused tests passed as listed above; browser evidence remains blocked by the absent Godot binary.
