# Product

<!-- impeccable:product-schema 1 -->

## Platform

web

## Users

Primary users are drone pilots preparing real-world flights and instructors presenting drone operation. They use the Ground Station Panel (GSP) before flight to understand the simulated airframe, inspect its response, and make informed tuning decisions without risking a physical aircraft.

## Product Purpose

AeroSim provides high-fidelity drone simulation and live data so users can safely preview the effect of tuning before a real flight. The GSP makes that evidence legible during pre-flight tuning and teaching.

## Positioning

The GSP combines AeroSim's high-fidelity simulation with live motor and flight data to show the expected impact of tuning before it is applied to a physical drone.

## Operating Context

GSP is a browser-based local ground-station panel connected to an active AeroSim session. Users inspect live telemetry, tune parameters, configure in-flight quick adjustments, and work with presets while preparing a quad-X drone or explaining its behavior.

## Capabilities and Constraints

- Present live telemetry, flight-control diagnostics, hardware configuration, presets, and tuning controls.
- Retain the canonical coordinate and unit conventions: NED, FRD, and SI.
- Preserve the readiness boundary: tuning controls remain unavailable until the panel has an authenticated, fresh telemetry snapshot.
- Clearly present data for all four motors, including their behavior while the drone is flying and rotating.
- Provide graphical representations of flight data, including fluid-dynamics-related visualization where simulation data supports it.

## Brand Commitments

- Product name: AeroSim.
- GSP is available in Traditional Chinese and English.

## Evidence on Hand

- Current GSP implementation: `common/gsp/gsp_panel.html`.
- Procedural Quad-X telemetry visualization: `common/gsp/assets/gsp_visual.js`.
- Live telemetry, tuning, quick-adjust, and preset protocol support: `common/gsp/gsp_server.gd`.
- No approved visual reference, user research, or external brand assets have been provided. Future UI work must not fabricate them.

## Product Principles

- Make simulated evidence actionable before real-world flight.
- Show the state and behavior of all four motors clearly.
- Prefer graphical, interpretable telemetry over raw data alone.
- Preserve safe, explicit control readiness and deterministic simulation facts.
- Support both practical pilot tuning and instructional explanation.

## Accessibility & Inclusion

- Keep the GSP usable in Traditional Chinese and English.
- Do not rely on color alone to communicate motor, flight, or control state.
