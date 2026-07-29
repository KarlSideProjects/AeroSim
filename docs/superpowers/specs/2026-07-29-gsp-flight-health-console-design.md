# GSP Flight Health Console Design

## Goal

Make the first GSP view answer one pre-flight question immediately: are the quad-X airframe's four motors and surrounding airflow behaving normally? The panel remains a single live simulation view for flight preparation and teaching.

## Scope

- Replace the current procedural 2D airframe canvas with a Three.js live Quad-X scene.
- Show all four motors in their physical positions, with live rotational motion and clear per-motor status/data.
- Visualize available body-frame airflow and wind data with animated, labelled flow vectors.
- Reorganize the existing panel so the flight-health view leads; retain telemetry, tuning, quick adjust, and preset capabilities below it.
- Preserve Traditional Chinese and English support, local-session behavior, NED/FRD/SI labels, and the existing authenticated-fresh-snapshot readiness boundary for controls.

## Non-goals

- No new simulator protocol, aerodynamic model, or motor telemetry fields.
- No comparison mode or split-screen before/after tuning workflow.
- No change to tuning, quick-adjust, preset, or WebSocket authority semantics.

## Experience

The first viewport is an operational flight-health console:

1. The connection and freshness state remain continuously visible.
2. A large Three.js Quad-X view occupies the visual center.
3. Four persistent motor cards surround or align with the model in the same physical order. Each presents motor name, RPM, thrust, saturation/state, and a non-color state cue.
4. Animated airflow vectors in the model communicate the available wind/body-flow direction and magnitude; labels retain FRD and SI context.
5. A compact live trend below the scene gives recent motor/flight context without displacing the health verdict.
6. Existing detailed telemetry and configuration appear as progressive disclosure, followed by adjustment and preset tools.

## Architecture

- `common/gsp/gsp_panel.html` remains the static panel, WebSocket client, localization owner, and DOM host for controls.
- `common/gsp/assets/gsp_visual.js` becomes the isolated Three.js scene owner. It consumes the existing `aerosim-gsp-telemetry` event and exports only testable view controls/state.
- Existing telemetry payloads drive the visualization. Missing data is rendered explicitly as unavailable rather than inferred.
- CSS stays colocated with the panel and supplies the responsive layout, readable state hierarchy, and reduced-motion behavior.

## States and Safety

- Disconnected, authenticating, waiting for fresh telemetry, live, unavailable telemetry field, normal, warning, and critical motor states are legible without color alone.
- The scene remains readable while disconnected; it does not pretend stale values are live.
- `prefers-reduced-motion` disables non-essential rotation and animated flow while preserving the latest state.
- Tuning controls retain their current disabled state until a fresh, authenticated snapshot exists.

## Validation

- Extend the GSP browser test to assert the four motor readouts, flow visualization data path, and retained control readiness behavior.
- Run the focused GSP browser test and the existing GSP headed acceptance path after implementation.
- Perform Codex visual verification at desktop and narrow viewport sizes; human visual review remains deferred until CAP-006 passes.

## Acceptance Criteria

- On first view, users can identify each of the four motors and its current operating state without opening a detail panel.
- Motor rotational behavior and available airflow data are visible in the Three.js scene during live telemetry.
- All existing tuning, quick-adjust, preset, telemetry, and localization behavior remains functional.
- Missing or stale data, control readiness, and warning/critical states remain unambiguous.
