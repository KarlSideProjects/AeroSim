# GSP Flight Health Console Design

## Goal

Make the first GSP view answer one pre-flight question immediately: are the quad-X airframe's four motors and surrounding airflow behaving normally? The panel remains a single live simulation view for flight preparation and teaching.

## Scope

- Replace the current procedural 2D airframe canvas with a Three.js live Quad-X scene.
- Show all four motors in their physical positions, with live rotational motion and clear per-motor status/data.
- Visualize available body-frame airflow and wind data with animated, labelled flow vectors.
- Reorganize the existing panel so the flight-health view leads; retain telemetry, tuning, quick adjust, and preset capabilities below it.
- Vendor a `file://`-loadable Three.js build and install it alongside the panel.
- Preserve Traditional Chinese and English support, local-session behavior, NED/FRD/SI labels, and the existing authenticated-fresh-snapshot readiness boundary for controls.

## Non-goals

- No new simulator protocol, aerodynamic model, or motor telemetry fields.
- No comparison mode or split-screen before/after tuning workflow.
- No change to tuning, quick-adjust, preset, or WebSocket authority semantics.
- No static HTTP file serving added to `gsp_server.gd`; the panel keeps loading from `file://`.
- No third-party 3D model asset; the airframe is procedural geometry.
- No network access at panel runtime; every asset ships in the installed bundle.

## Experience

The first viewport is an operational flight-health console:

1. The connection and freshness state remain continuously visible.
2. A large Three.js Quad-X view occupies the visual center.
3. Four persistent motor cards surround or align with the model in the same physical order. Each presents motor name, RPM, thrust, current, saturation/state, and a non-color state cue.
4. Animated airflow vectors in the model communicate the available wind/body-flow direction and magnitude; labels retain FRD and SI context.
5. A compact live trend below the scene gives recent motor/flight context without displacing the health verdict.
6. Existing detailed telemetry and configuration appear as progressive disclosure, followed by adjustment and preset tools.

## Delivery Constraints

These three facts about the current tree block a naive Three.js integration and drive the architecture below.

### The panel runs from `file://`

`gsp_launcher.gd` installs the panel into the user data directory and opens it with a `file://` URL (`_file_url`, `panel_url`). Chrome and Firefox apply CORS to module scripts on `file://`, so `<script type="module">` and any `import` statement fail there. `gsp_panel.html` works today only because `assets/gsp_visual.js` is a classic script.

Three.js r160 and later ship no UMD build — `three@0.180.0` contains only `three.cjs`, `three.module.js`, `three.core.js`, and the `tsl`/`webgpu` variants. A classic-script build therefore has to be produced, not downloaded.

### The vendored Three.js copy is incomplete

`common/gsp/assets/three-0.180.0.module.min.js` is a pure ES module whose first statement imports from `./three.core.min.js`, a file that is not in the repository. The vendored copy cannot load even if the module problem were solved, and nothing references it.

### Panel assets are installed from an explicit list

`gsp_launcher.gd`'s `PANEL_ASSET_PATHS` contains only `gsp_visual.js`. Assets absent from that list never reach the installed bundle directory, and the list also feeds the bundle SHA-256 that names the bundle directory.

## Vendoring and Build

- Produce a single self-contained classic script `common/gsp/assets/three-0.180.0.global.min.js` that assigns the Three.js namespace to a `THREE` global.
- `RoomEnvironment` lives in `examples/jsm`, not in `three.module.js`, so the bundle entry is an explicit re-export file rather than the core build. Anything else pulled from `examples/jsm` later is added to the same entry.

  ```js
  // scripts/gsp_three_entry.js
  export * from "three";
  export { RoomEnvironment } from "three/examples/jsm/environments/RoomEnvironment.js";
  ```

- Build recipe, run only when the Three.js version changes:

  ```sh
  npm install three@0.180.0
  npx esbuild scripts/gsp_three_entry.js \
      --bundle --format=iife --global-name=THREE --minify \
      --outfile=common/gsp/assets/three-0.180.0.global.min.js
  ```

  This produces a ~687 KB self-contained classic script defining a `THREE` global at revision 180, carrying `RoomEnvironment`, `PMREMGenerator`, `ACESFilmicToneMapping`, and `PCFSoftShadowMap`. Verified against `three@0.180.0` with esbuild 0.28.1.

- Commit the built artifact and `scripts/gsp_three_entry.js`. Do not commit `package.json` or `node_modules`: the repository has no JavaScript build pipeline, the Node dependency exists only on the maintainer's machine during a version bump, and CI gains nothing to install.
- Record source package, version, SHA-256, build command, and license in `common/gsp/assets/asset_notes.md`, matching the convention in `assets/third_party/free3d_drone/asset_notes.md`. Keep `THREE-LICENSE`.
- Delete `three-0.180.0.module.min.js`; it is unloadable and its `three.core.min.js` dependency is missing.
- Add the built artifact to `PANEL_ASSET_PATHS` so it is hashed into the bundle and installed next to `panel.html`.
- `gsp_visual.js` stays hand-written, unbundled, and classic. It reads the `THREE` global. Only the vendored artifact is generated, so editing scene code never requires a build.

## Architecture

- `common/gsp/gsp_panel.html` remains the static panel, WebSocket client, localization owner, and DOM host for controls and motor cards. It loads the vendored Three.js as a classic script before `gsp_visual.js`.
- `common/gsp/assets/gsp_visual.js` becomes the isolated scene owner. It consumes the existing `aerosim-gsp-telemetry` event and exports only testable view controls/state on `window.__AEROSIM_GSP_VISUAL__`.
- Localization stays with the panel. `gsp_visual.js` hardcodes no display strings; the panel passes a label bundle through an exported setter and calls it again on language change. In-scene text uses the same `translations` table as `data-i18n` nodes.
- Telemetry-to-visual mapping is a pure function, `mapTelemetryToViewState(sample, powerModel)`, exported for tests. It performs every clamp, normalization, threshold, and availability decision. Scene code only applies the returned view state; it makes no decisions of its own.
- If the `THREE` global is absent or WebGL context creation fails, the panel shows an explicit visualization-unavailable state and keeps every readout and control working.
- Existing telemetry payloads drive the visualization. Missing data is rendered explicitly as unavailable rather than inferred.
- CSS stays colocated with the panel and supplies the responsive layout, readable state hierarchy, and reduced-motion behavior.

## Body-Axis and View Contract

The telemetry frame is FRD (`coordinate_frame: "FRD"`): x forward, y right, z down. Scene axes are fixed as:

| Body axis (FRD) | Scene axis (Three.js, Y-up) |
| --- | --- |
| +x forward | −Z |
| +y right | +X |
| +z down | −Y |

Motor placement follows `motor_order` from the snapshot, standard `Betaflight quad-X 1-4`, never a hardcoded index-to-corner table:

| Index | `motor_order` | Body x | Body y |
| --- | --- | --- | --- |
| 0 | `rear_right` | −arm | +arm |
| 1 | `front_right` | +arm | +arm |
| 2 | `rear_left` | −arm | −arm |
| 3 | `front_left` | +arm | −arm |

- Motor card DOM order and on-screen anchor positions derive from the same table, so the cards and the geometry cannot disagree.
- View presets are defined against the body frame: `top` looks down −z with +x toward screen top; `side` looks along −y with +x to screen right; `rear` looks along +x with +y to screen right; `isometric` is the default three-quarter view above, behind, and left.
- A persistent forward indicator marks the nose so the orientation stays unambiguous in every preset and after free orbit.
- Spin direction comes from `hardware_configuration.spin_direction[i]`. When the array is absent or shorter than the motor list, that rotor's direction renders as unavailable; no default handedness is assumed.

## Rendering Specification

Precision, not decoration. The scene must look deliberate at both viewport sizes.

- **Geometry.** Procedural: extruded arm profiles with chamfered edges, a bevelled center hub carrying the flight-controller stack, motor bells with visible stator detail, and 2-blade props with real chord taper and pitch twist. Arm length, motor spacing, and prop diameter come from `hardware_configuration` where present; otherwise a labelled nominal geometry is used and the panel says so.
- **Materials.** `MeshStandardMaterial` throughout. Distinct metalness/roughness for frame, motor bell, and props so the parts read apart under one light rig.
- **Lighting.** One key directional light with shadows, one fill, and a low hemisphere ambient. Environment reflection comes from a procedurally generated room environment (`RoomEnvironment` plus `PMREMGenerator`), never an external HDR file — nothing may be fetched at runtime.
- **Shadows.** `PCFSoftShadowMap`, cast by the airframe onto a ground plane that also anchors the ground-effect cue.
- **Output.** `ACESFilmicToneMapping`, `SRGBColorSpace`, antialias enabled, `setPixelRatio(Math.min(devicePixelRatio, 2))`.
- **Interaction.** Keep the existing orbit and zoom bindings and the four view-preset buttons.
- **Performance budget.** Target 60 fps at 1920×1080 on integrated graphics. Cap total scene triangles at ~150k. Rebuild geometry only when `hardware_configuration` changes, never per frame.
- **Degradation.** On WebGL context loss, freeze the last view state, show the unavailable cue, and attempt one restore.

## Rotor Motion Model

Mapping true rotor speed directly to per-frame rotation aliases badly: a 2-blade prop's pattern repeats every 180°, so above 90° of rotation per frame the direction becomes ambiguous and the prop appears stopped or reversed. Real speeds reach thousands of rpm, far past that limit.

- Rendered angular step is capped so that per-frame rotation stays at or below 30°, computed from the measured frame interval rather than an assumed 60 fps.
- True speed is carried by two channels instead: blade opacity ramps from 1.0 down to about 0.15, and a translucent swept disc ramps from 0 up to about 0.85, as normalized rpm goes 0 to 1. A saturated rotor therefore reads as a solid blurred disc, which is both physically honest and visually correct.
- Normalization uses the per-motor maximum implied by `hardware_power_model`; see thresholds below.
- The numeric rpm on each motor card is always the true value. The scene never implies a speed the readout contradicts.
- Spin handedness renders only when known, per the body-axis contract.

## Airflow Visualization Data Binding

Each visual channel binds to exactly one telemetry field. Any field that is missing, non-finite, or gated `unavailable` renders as an explicit unavailable cue rather than as zero.

| Telemetry field | Visual channel | Scale / note |
| --- | --- | --- |
| `wind_body_mps` (Vec3, FRD) | Primary flow ribbons crossing the scene | Direction from the vector; length and density from `clamp(‖v‖ / 15, 0, 1)` |
| `airspeed_body_frd_mps_mean` (Vec3, FRD) | Streak advection speed along the ribbons | Same 15 m/s full scale |
| `turbulence_intensity` (scalar) | Lateral jitter amplitude of streaks | 0 straight, 1 maximum jitter |
| `downwash_force_n` (scalar) | Downward column under the rotor disc | Normalized by per-motor maximum thrust |
| `ground_effect_gain` (scalar) | Ground-plane ring under the airframe | 1.0 renders as no ring |
| `propwash_disturbance_rad_s2` (Vec3, FRD) | Rotational shear arcs near the hub | Gated by `a6_operating_state` |
| `drag_body_n` (Vec3, FRD) | Body drag arrow opposing motion | Gated by `body_drag_operating_state` |
| `body_drag_force_body_frd_n_mean` (Vec3, nullable) | Mean drag arrow, distinct from instantaneous | Already null when non-finite; render unavailable |
| `a3_drag_force_body_frd_n_mean` (Vec3, FRD) | Rotor-drag arrow at the rotor plane | Gated by `a3_operating_state` |
| `air_density_kg_m3` (scalar) | Numeric label only | No geometry |

Availability gates use the exact values emitted by `aerosim_flight_control.cpp`:

- `body_drag_operating_state`: `active` renders; `disabled`, `out_of_domain`, and `unavailable` each render their own labelled state, and are not collapsed together.
- `body_drag_evidence_state`: `provisional` renders with a provisional marker; `unavailable` suppresses the channel.
- `a3_operating_state` / `a6_operating_state`: `active` renders, `disabled` renders as disabled.
- `body_drag_reason_code` supplies the tooltip text for a suppressed channel.

Every vector channel carries an FRD axis label and SI unit, and a legend states the full-scale value used for length so magnitudes are not read as absolute.

## Motor Card Data Contract

Per-motor telemetry contains exactly four fields (`motor_telemetry_dict` in `aerosim_native.cpp`): `thrust_newtons`, `speed_rad_s`, `current_a`, `saturated`. RPM is not among them — `flight_runtime.gd` derives it as `speed_rad_s * 60 / TAU` and publishes a top-level `rpm` array parallel to `motors`.

| Card field | Source | Unit |
| --- | --- | --- |
| Motor name | `motor_order[i]`, translated | — |
| RPM | top-level `rpm[i]`, falling back to `motors[i].speed_rad_s * 60 / TAU` | rpm |
| Thrust | `motors[i].thrust_newtons` | N |
| Current | `motors[i].current_a` | A |
| Saturation | `motors[i].saturated` | boolean |
| Health state | derived, see thresholds | — |

- Motor names get Traditional Chinese and English entries in the panel's `translations` table: `rear_right` 右後, `front_right` 右前, `rear_left` 左後, `front_left` 左前. The card also shows the Betaflight index `M1`–`M4`.
- Motor count is the length of the `motors` array, which is authoritative; power-model totals are divided by it.
- `current_a` is shown, not dropped: for a pre-flight health verdict it is the most direct indicator of an abnormal motor.

## Health Thresholds

Thresholds are derived, never invented in the view layer. `hardware_power_model` (from `hardware_config.gd`'s `derive_power_model`) supplies `max_total_thrust_newtons` and `max_total_current_a`.

- Per-motor maxima: `max_total_thrust_newtons / motor_count` and `max_total_current_a / motor_count`.
- Load ratio per motor is the larger of the thrust ratio and the current ratio.
- `normal` below 0.85; `warning` at 0.85 or above; `critical` at 0.98 or above, or whenever `saturated` is true.
- When `hardware_power_model` is missing, or either maximum is zero or non-finite, the health state is `unavailable`, never `normal`. Absence of evidence is not a pass.
- Non-color cues carry each state independently of hue: `normal` a plain ring, `warning` a dashed ring with a triangle glyph, `critical` a hatched ring with a filled octagon glyph, `unavailable` a dotted ring with an em dash. Every state also appears as translated text.

## Trend Panel

The compact live trend replaces the existing `#sparkline` canvas rather than sitting beside it. It keeps the element id and the existing rolling-buffer feed so the panel-behavior test's canvas stubs keep working, and extends the rendering to four per-motor traces plus the health band. No second trend surface is introduced.

## States and Safety

- Disconnected, authenticating, waiting for fresh telemetry, live, unavailable telemetry field, normal, warning, critical, and visualization-unavailable states are legible without color alone.
- The scene remains readable while disconnected; it does not pretend stale values are live.
- Tuning controls retain their current disabled state until a fresh, authenticated snapshot exists.
- `prefers-reduced-motion` handling: rotor spin is the primary carrier of motor state, so it is not simply switched off. Under reduced motion the scene stops all continuous animation — rotor rotation, streak advection, jitter — and substitutes static encodings: the rotor renders as a swept disc whose fill fraction and opacity encode normalized rpm, and flow becomes static arrows sized by magnitude. Every value readable while animating stays readable while still. Reduced motion never changes which data is shown, only whether it moves.

## Validation

`tests/test_gsp_panel_behavior.js` is a hand-written DOM stub — a fake `Element` class whose `getContext()` returns no-op methods — running under `node:vm`. It has no WebGL, no real layout, and no `requestAnimationFrame` semantics. It cannot assert anything about a Three.js scene, and calling it a browser test overstates it. The validation split follows that limit:

- **Pure mapping tests, in the existing harness.** `mapTelemetryToViewState` is tested directly: four motor readouts and their derived health states; threshold boundaries at 0.85 and 0.98; `saturated` forcing `critical`; missing `hardware_power_model` yielding `unavailable` rather than `normal`; every airflow channel's gate value from `body_drag_operating_state`, `body_drag_evidence_state`, `a3_operating_state`, and `a6_operating_state`; non-finite and null fields; rotor render-rate capping; and the `motor_order`-to-position mapping. This is where the flow-visualization data path is actually covered.
- **DOM tests, in the existing harness.** Motor card population and ordering, translated labels under both languages, retained control-readiness behavior, and graceful behavior when the `THREE` global is absent.
- **Scene smoke test, new.** A headless Chromium run loading the installed bundle over `file://` that asserts the vendored classic script defines `THREE`, that a WebGL context is created, and that `window.__AEROSIM_GSP_VISUAL__` reports four positioned rotors. This is the only new test infrastructure, and it exists specifically because the stub harness cannot cover it.
- **Launcher test.** Assert the vendored Three.js artifact is present in `PANEL_ASSET_PATHS` and lands in the installed bundle directory, and that changing it changes the bundle hash.
- Run the focused GSP tests and the existing GSP headed acceptance path after implementation.
- Perform Codex visual verification at desktop and narrow viewport sizes; human visual review remains deferred until CAP-006 passes.

## Acceptance Criteria

- On first view, users can identify each of the four motors and its current operating state without opening a detail panel.
- Motor rotational behavior and available airflow data are visible in the Three.js scene during live telemetry, with no rotor appearing stopped or reversed at high rpm.
- The panel loads and renders the scene from a `file://` URL with no network access and no console errors.
- Motor positions match the FRD body-axis contract in every view preset, with no left/right mirroring.
- Every airflow channel is either bound to its specified telemetry field or explicitly marked unavailable; none is left as a decorative default.
- Health states derive from `hardware_power_model`, and absent power-model data reads as unavailable rather than normal.
- All existing tuning, quick-adjust, preset, telemetry, and localization behavior remains functional.
- Missing or stale data, control readiness, and warning/critical states remain unambiguous, in both languages and under `prefers-reduced-motion`.
