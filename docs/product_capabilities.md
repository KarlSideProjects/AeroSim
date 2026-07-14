# AeroSim Product Capabilities

This document is the canonical list of AeroSim product capabilities and boundaries. It turns confirmed product decisions into observable features and acceptance evidence. A confirmed capability is a delivery contract, not a claim that the current branch already implements it.

## Status meanings

| Status | Meaning |
|---|---|
| Available | The current branch exposes the stated behavior and has direct test evidence. |
| Foundation | Part of the behavior exists, but the complete user capability or acceptance gate does not. |
| Confirmed target | The behavior is part of the AirSim-class minimum but is not implemented on the current branch. |

Status reflects the repository at the time this document was introduced. It must be updated in the same change that adds or removes a capability.

## Product boundary

### CAP-001: Simulation platform with two entry modes

**Status:** Foundation

AeroSim is a multirotor simulation platform. Player Mode is the default, game-like entry for a person who wants to fly. Lab Mode exposes the same world, vehicles, sensors, and environment to software. Cars and road-vehicle simulation are outside the minimum.

**Minimum acceptance:** A release starts in Player Mode, can enter Lab Mode without launching a separate product, and both modes observe the same simulation state.

**Current evidence:** The current Godot scene exposes a basic Quick Fly flow and flight runtime. It does not yet expose Lab Mode.

### CAP-002: Player Mode flight loop

**Status:** Foundation

Player Mode lets a person enter the reference environment, control the primary multirotor, pause, respawn, and change supported flight modes. Its normal path is selection or Quick Fly, preflight state, flight, collision or landing, and immediate retry.

**Minimum acceptance:** A first-time user can reach a flyable scene, identify the active mode and vehicle state, fly, collide, respawn, pause, and exit without developer tools.

**Current evidence:** Quick Fly, pause, respawn, Angle, Acro, and Altitude Hold paths exist in `common/flight/flight_runtime.gd` and are exercised by the headless smoke suite. Selection, preflight presentation, and a production scene remain incomplete.

### CAP-003: Lab Mode automation surface

**Status:** Confirmed target

Lab Mode lets software reset and control the simulation, address named vehicles, read sensors, change supported environment state, manage approved scene objects, and start or stop recording.

**Minimum acceptance:** All published Lab Mode operations work without UI input and return explicit errors for unsupported operations or invalid names.

### CAP-004: Persistent map selection

**Status:** Foundation

The main menu retains a `Map` entry and a catalog-backed selection screen. The AirSim-class minimum exposes only one selectable environment, the Industrial Test Range, and does not show fake or Coming Soon maps. Later environments can be added to the catalog without replacing the Player Mode navigation flow.

**Minimum acceptance:** The Map screen lists exactly the environments present in the checked-in catalog, selects and persists the active entry, launches the selected scene through Quick Fly, handles a missing or invalid catalog entry explicitly, and remains usable with exactly one entry.

### CAP-005: Seven-entry primary navigation

**Status:** Foundation

The main menu exposes exactly `Quick Fly`, `Lab Mode`, `Controller`, `Drone`, `Map`, `Settings`, and `Quit` as first-level entries. These routes separate immediate flight, simulator operations, controller setup, vehicle selection, environment selection, configuration, and desktop exit.

**Minimum acceptance:** Keyboard, gamepad, and mouse can reach and activate every entry; focus order and back navigation are deterministic; unavailable prerequisites route to an actionable setup state; `Quit` requires no developer shortcut; the menu remains readable at the qualified resolution.

**Current evidence:** The current runtime builds `Quick Fly`, `Controller`, `Drone`, `Map`, and `Settings` buttons. `Lab Mode`, `Quit`, production navigation states, and complete accessibility behavior are not present.

### CAP-006: Playable Game Milestone

**Status:** Confirmed target

The first formal visual and usability review begins only after an Ubuntu package provides one complete, production-facing Player Mode game loop. Before that review, the required milestone sequence is automated checks, a headed run on the maintainer's real display that the maintainer visibly observes, and maintainer play acceptance recorded on the issue. From a cold start, the maintainer can use the seven-entry menu, select the controller, drone, and sole Map Catalog entry, Quick Fly into the Industrial Test Range, fly the production vehicle, collide, pause, respawn, complete the short Time Trial, and quit without developer tools, placeholder UI, or missing production assets.

Before this milestone, deterministic checks and Codex AI Visual Verification produce provisional evidence without requesting human approval. After the automated and headed milestone gate passes, a person performs the first formal visual and usability review and approves or rejects the initial four-view reference.

**Minimum acceptance:** A clean Ubuntu install passes the automated or agent-operated end-to-end run, then a real-display headed run is visibly observed and the maintainer personally completes the same loop and records issue acceptance. Store screenshots and machine-readable results, require zero Critical or High Codex visual findings, and contain no placeholder or developer-only state in the path. Only then may formal human visual or usability review be requested.

## Compatibility and flight control

### CAP-010: Frozen AirSim client compatibility surface

**Status:** Confirmed target

The official `airsim==1.8.1` Python client works unchanged for a published subset of its operations and `settings.json` fields. The compatibility manifest is frozen per AeroSim release. Unsupported calls and settings fail explicitly instead of returning approximate success, and AeroSim does not claim compatibility with a floating latest version.

The first manifest covers connection and deterministic time control, two named multirotors, flight commands and state, the complete Baseline Sensor Suite, Environment Controls, catalog-managed Scene Objects, and recording. Car APIs, runtime material replacement, debug plotting, and arbitrary vehicle-type creation are explicitly unsupported.

The first `settings.json` subset accepts `SettingsVersion`, multirotor-only `SimMode`, RPC and simulation-clock fields, `OriginGeopoint`, at most two named `Vehicles` with per-vehicle `Cameras` and `Sensors`, `SubWindows`, and `Recording`. `VehicleType` accepts only `SimpleFlight` for AeroSim's built-in flight controller and `PX4Multirotor` for PX4 SITL. Unsupported root fields, nested fields, modes, and vehicle types produce explicit startup diagnostics instead of being silently ignored.

**Minimum acceptance:** A checked-in manifest names every supported API and setting by its AirSim 1.8.1 identifier. A compatibility suite installs the pinned client, runs its calls without client patches, exercises every supported category with both vehicle names where applicable, and verifies explicit errors for unsupported calls and settings.

### CAP-011: PX4 software-in-the-loop

**Status:** Confirmed target

PX4 SITL can control an AeroSim multirotor through the supported Lab Mode path. ArduPilot SITL and hardware-in-the-loop are outside the first AirSim-class minimum.

**Minimum acceptance:** A pinned PX4 version arms, takes off, flies a deterministic mission, lands, and reports actionable connection state in the Operations Dashboard and automated tests.

### CAP-012: Deterministic multirotor flight core

**Status:** Foundation

The native C++ core provides multirotor state integration, Angle, Acro, and Altitude Hold control, airframe configuration, IMU-driven attitude estimation, and collision authority handoff between native integration and Godot physics.

**Minimum acceptance:** Native behavior tests pass with warnings as errors; identical seeds and inputs reproduce identical same-platform results; cross-platform terminal state stays inside the frozen tolerance.

**Current evidence:** Native tests cover flight control, collision, aerodynamics, IMU, hardware configuration, telemetry, and replay. The Godot smoke path exercises the C++ binding. The complete product session and cross-platform replay tolerance are not yet evidenced.

### CAP-013: Two simultaneous named vehicles

**Status:** Confirmed target

Lab Mode supports two simultaneous, uniquely named multirotors with isolated command, state, and sensor streams. Player Mode controls one primary vehicle. The minimum does not promise arbitrary fleet scale.

**Minimum acceptance:** A test commands both vehicles independently, proves sensor and state isolation, observes both in the same world, and records both in one synchronized dataset.

### CAP-014: Stable external coordinate contract

**Status:** Confirmed target

The AirSim Compatibility Surface, PX4 bridge, Flight Replay, and Dataset Recording use NED world axes, FRD vehicle-body axes, and SI units. Godot's Y-up coordinates remain internal and cross one shared conversion boundary.

**Minimum acceptance:** Known position, direction, velocity, orientation, angular-rate, and force fixtures round-trip through the boundary within frozen tolerances; public payloads contain no undocumented Godot-axis values; API, PX4, replay, and dataset tests use the same fixtures.

### CAP-015: Local-only RPC access boundary

**Status:** Confirmed target

The AirSim-compatible RPC server binds only to loopback in the first release. It defaults to `127.0.0.1:41451`; the port is configurable, but non-loopback addresses are rejected. LAN and Internet access remain unavailable until authentication and transport security are specified.

**Minimum acceptance:** Default and custom-port loopback connections pass the compatibility suite; startup rejects wildcard, LAN, and public bind addresses with an actionable diagnostic; no RPC listener is reachable through a non-loopback interface.

### CAP-016: AirSim-compatible flight command surface

**Status:** Confirmed target

Each named multirotor supports takeoff, land, hover, return home, position, path, velocity, yaw, and attitude or body-rate plus throttle commands through the pinned AirSim client. The same command families work with `SimpleFlight` and `PX4Multirotor`. AirSim asynchronous completion and cancellation behavior is preserved. Direct per-motor PWM is explicitly unsupported in the first release.

**Minimum acceptance:** The compatibility suite runs every command family against both vehicle names and both flight-controller types, verifies NED/FRD units and limits, joins and cancels asynchronous tasks, reports precondition failures, and proves that commands never cross vehicle boundaries.

### CAP-017: Audited AirSim source reference

**Status:** Confirmed target

AirSim `v1.8.1` at commit `96235148a332fe7cb3d3525a0720e26faaca99e0` is available in a read-only checkout outside the AeroSim repository for compatibility and implementation research. It is not a runtime, build, or scene dependency. Every adaptation of AirSim code or behavior is preceded by a search of relevant open and closed Microsoft AirSim issues so known upstream defects and compatibility quirks are assessed rather than copied silently.

**Minimum acceptance:** Each implementing issue or pull request that adapts AirSim records the exact upstream paths or symbols and commit, issue queries, relevant issue URLs and disposition, license or attribution decision, and AeroSim tests derived from the findings. CI and clean builds do not require the external checkout.

## Sensors and observability

### CAP-020: Baseline sensor suite

**Status:** Foundation

Every AirSim-class release provides RGB, depth, segmentation, IMU, GPS, magnetometer, barometer, and LiDAR observations. Optical flow, distance sensors, and object detection are extensions.

**Minimum acceptance:** Each sensor has a published coordinate frame, units, timing model, configuration boundary, deterministic test fixture, and Lab Mode retrieval path. Camera, depth, segmentation, and LiDAR outputs must be geometrically consistent with the same scene.

**Current evidence:** The native core simulates gyro, acceleration, attitude estimate, delay, configurable noise, drift, random walk, and barometric altitude. Issue #141 adds deterministic Lab Mode IMU, GPS, magnetometer, barometer, and LiDAR retrieval for one named vehicle, with the published NED/FRD/SI payload fields and configuration boundary. RGB, depth, and segmentation product interfaces remain future work.

### CAP-021: In-app Operations Dashboard

**Status:** Foundation

The Operations Dashboard is a native Godot Control interface. It provides vehicle selection, telemetry, sensor previews, PX4 and API status, recording state, and weather state. Player Mode shows a compact form; Lab Mode exposes the full panel. No separate web dashboard is required.

**Minimum acceptance:** All required information is readable at the target desktop resolution, vehicle selection changes every vehicle-scoped panel, and stale or disconnected data is visibly distinct from valid live data.

**Current evidence:** A basic runtime-built debug panel shows flight mode, arm state, motor values, battery values, wind placeholders, and PID saturation. It is not the required dashboard.

### CAP-022: AirSim-compatible camera outputs

**Status:** Confirmed target

The camera API supports AirSim `Scene`, `DepthPlanar`, and `Segmentation` image types. Requests preserve the pinned client's `pixels_as_float` and `compress` behavior, including PNG, raw-byte, and floating-point planar-depth outputs. `DepthVis`, disparity, surface normals, infrared, and other image types are explicitly unsupported in the first release.

**Minimum acceptance:** Fixed-scene fixtures verify image dimensions, timestamps, camera pose, encoding, planar-depth values, segmentation IDs, multi-request ordering, and per-vehicle camera isolation for compressed, uncompressed, and floating-point requests.

### CAP-023: Deterministic sensor timebase

**Status:** Confirmed target

Every camera and sensor observation uses one simulation-time clock. Pausing freezes sensor time, deterministic frame or duration stepping advances it, and each configured sensor rate schedules observations independently of render rate and wall-clock speed. Dataset Recording identifies missing and dropped samples rather than hiding gaps.

**Minimum acceptance:** Repeating the same seed, settings, commands, pause sequence, and step sequence produces identical sensor timestamps and sample counts; rate and alignment tests cover both vehicles; the dataset validator rejects non-monotonic timestamps and unreported gaps.

**Current evidence:** `AirSimSession` is the shared simulation clock. Issue #141 schedules each non-camera sensor against that clock, keeps paused reads stable, validates configured rates and latency/startup values, and exposes sample/drop counters for deterministic gap checks. Multi-vehicle alignment and dataset validation remain future work.

## World and scene system

### CAP-030: One reference environment

**Status:** Confirmed target

The minimum ships one coherent Industrial Test Range. It contains a launch area, warehouse and street geometry, an obstacle corridor, and a short Time Trial route in one Godot scene. The same environment supports Player Mode, Lab Mode, sensor tests, object placement, and visual acceptance.

**Minimum acceptance:** A person can recognize and navigate every zone; the route is flyable; scale, collision, lighting, and sensor outputs are plausible; all required screenshots pass the visual gates.

**Current evidence:** The current branch contains only a non-rendered smoke scene with a collision wall and no production visual assets.

### CAP-031: Automated Godot-native scene asset pipeline

**Status:** Confirmed target

Production scene assets enter the repository as license-approved Godot-compatible glTF or GLB files and are imported by Godot without hand-editing generated resources. The first reference environment uses a checked-in, license-approved asset set. Engine-specific Unity UI, Unreal UMG, Blueprint, C++, physics, navigation, and complex shaders are not treated as automatically convertible assets; production UI is built with Godot Control nodes.

Before CAP-006, the pipeline accepts only sources already covered by the checked-in license allowlist and provenance rules; it does not pause for human asset review. Codex creates provisional visual evidence during development. After the Playable Game Milestone, a person approves or rejects the initial visual reference; subsequent routine import and validation run without manual intervention. Packaged Unreal environments and extracted `.pak` content are not production inputs.

**Minimum acceptance:** A clean checkout imports the approved assets, builds the scene, validates dependencies, materials, transforms, collision, and licenses, then produces deterministic screenshots without editor repair steps.

### CAP-032: AI visual scene verification

**Status:** Confirmed target

Every shippable scene is targeted to render from four fixed GPU camera views. Before CAP-006, Codex reviews provisional references while deterministic structure, collision, render, and image checks continue to block regressions. Once the complete playable loop passes, a person performs the first formal review and approves the initial reference set. Later builds run the same deterministic checks plus AI review for coherent composition, readable lighting, plausible scale, intact assets, and flight legibility.

The target pipeline runs deterministic scene structure, dependency, collision, rendering, and basic image checks on every relevant pull request. Codex performs AI review when scene, asset, material, lighting, or UI inputs change and for every release. The target headed acceptance workflow will generate four screenshots and a manifest; current CI does not yet provide the complete visual-review pipeline or call a separate vision API. The required Codex review compares those inputs with the current provisional or Approved Visual Reference using a versioned rubric and emits strict JSON evidence containing the commit, input hashes, rubric version, reviewer model identity, reference status, severity, findings, and verdict.

**Minimum acceptance:** Path-trigger tests prove visual changes cannot skip Codex review, release validation always requires current evidence, the gate rejects any Critical or High visual finding, absent or stale review evidence blocks the required workflow, no human review is requested before CAP-006, and the initial approval or any later reference replacement requires explicit human approval. This is a triggered agent review, not an unattended GitHub-only job.

### CAP-033: Catalog-managed scene objects

**Status:** Confirmed target

Lab Mode can spawn, move, query, and destroy named Scene Objects from a checked-in approved catalog. Each item defines its visual asset, transform rules, collision, and segmentation label. Arbitrary external paths and runtime model import are outside the minimum.

**Minimum acceptance:** API tests create and remove catalog objects, reject unknown asset IDs and duplicate object names, verify collision and segmentation, and reproduce the same object state during replay.

### CAP-034: Environment controls

**Status:** Confirmed target

Player Mode and Lab Mode can set wind, rain, fog, and time of day including sun position. The state is visible in the dashboard and captured by replay and dataset recording. Snow, dust, and wet-road material response are extensions.

**Minimum acceptance:** UI and API changes produce the same bounded environment state, sensor outputs and screenshots react consistently, and replay restores the recorded state.

**Current evidence:** Telemetry reserves wind vectors but the smoke tests require them to remain zero until a wind model exists. Rain, fog, and time-of-day controls are not implemented on the current branch.

### CAP-035: Reproducible reference asset set

**Status:** Confirmed target

The Industrial Test Range uses Kenney City Kit (Industrial), licensed CC0, as its primary visual source. Missing pieces may use Godot primitives or project-created assets. The shippable environment has no Unity or Unreal scene-conversion dependency.

**Minimum acceptance:** The repository records the source URL, CC0 license, upstream version, archive hash, imported-file manifest, and any project-created additions; a clean checkout builds the approved environment without downloading Unity or Unreal projects; the license scan and all scene gates pass.

### CAP-036: Distinct reference vehicle visuals

**Status:** Confirmed target

Both Vehicle Instances use one project-created, low-poly industrial quadrotor visual consistent with the Kenney environment. Each named vehicle has a stable, distinct accent color and readable front direction. Visual nodes are separate from physics, collision, and sensor mounts. No external drone asset or engine conversion is required.

**Minimum acceptance:** Both vehicles are identifiable in the world, dashboard, screenshots, and datasets; accent identity remains stable across respawn and replay; replacing or hiding the visual mesh does not change mass, collision, control, or sensor transforms; the four-view Codex visual review finds the model coherent and correctly scaled.

## Recording and evidence

### CAP-040: Deterministic Flight Replay

**Status:** Foundation

Flight Replay reconstructs a flight from recorded commands and all simulation conditions needed for reproducibility. It is separate from video playback and Dataset Recording.

**Minimum acceptance:** A recorded two-vehicle session, including environment and scene-object changes, replays inside the frozen same-platform and cross-platform tolerances and reports divergence with the first failing timestamp.

**Current evidence:** The native replay core records `FlightCommand` frames and proves deterministic Angle Mode trajectories. It does not yet record a complete product session or expose replay through Player Mode or Lab Mode.

### CAP-041: Synchronized Dataset Recording

**Status:** Confirmed target

Dataset Recording captures time-aligned commands, vehicle state, collision events, environment state, enabled camera frames, and sensor observations for both vehicles. It serves analysis and AI workflows and does not substitute for Flight Replay.

**Minimum acceptance:** The recorder publishes a versioned schema, stable timestamps, per-vehicle and per-sensor identity, dropped-sample accounting, and a validator that checks alignment and completeness.

### CAP-042: Portable dataset package

**Status:** Confirmed target

Each recording is one versioned directory containing `manifest.json`, `samples.jsonl`, PNG RGB and segmentation images, PFM planar-depth images, and little-endian float32 LiDAR points. The first release does not require a database, Parquet, or ROS bag. An interrupted recording remains explicitly incomplete until atomic finalization and validation succeed.

**Minimum acceptance:** A published schema defines every manifest and sample field, units, coordinate frame, byte order, relative path, and version rule; the validator detects missing files, malformed records, timestamp gaps, inconsistent identities, size mismatches, and incomplete sessions; a reference Python reader uses only the standard library plus image or array libraries already required by the pinned AirSim client workflow.

## Release-level acceptance

### CAP-050: Ubuntu AirSim-class qualification

**Status:** Foundation

Ubuntu x86_64 is the Qualification Platform on which every AirSim-class minimum capability must pass together, including PX4 SITL, RPC, the Baseline Sensor Suite, Dataset Recording, the reference environment, and visual gates. Windows and Android may retain Player Mode release lanes, but full Lab Mode parity on those platforms does not block the first qualified release.

**Minimum acceptance:** One pinned Ubuntu x86_64 release environment passes the full build, native, Godot, AirSim compatibility, PX4 mission, two-vehicle, sensor, dataset, scene, visual, packaging, installation, and headed smoke gates from a clean checkout.

### CAP-051: Profiled performance qualification

**Status:** Confirmed target

The Reference Performance Profile is a designated Ubuntu 26.04 LTS runner with AMD Ryzen 9 7945HX, NVIDIA GeForce RTX 4060 Ti, and NVIDIA driver 580.159.03. On that profile, Player Mode targets stable 60 FPS at 1080p default quality, and the documented two-vehicle Lab Mode sensor workload targets real-time factor at least 1.0.

Lower-spec developer machines use the Local Development Profile. They still run functional and deterministic verification and may reduce visual quality or sensor rates. Missing the reference hardware reports performance as not qualified; it does not fail local development solely because of hardware specification.

**Minimum acceptance:** Performance gates execute and block only on an explicitly identified reference runner; local commands select non-blocking defaults; reports distinguish pass, fail, and not-qualified; functional failures remain blocking on every supported development machine.

The AirSim-class minimum is reached only when every confirmed target above is either Available or explicitly removed through a reviewed product decision. Passing native tests alone, displaying an AirSim-like UI, or importing a visually similar scene does not satisfy the minimum.

For the scene acquisition and validation rationale, see [Godot scene acquisition and validation](research/godot_scene_acquisition_and_validation.md). AirSim reference use follows the [AirSim Reference Policy](airsim_reference_policy.md). Architecture decisions are recorded in [architecture decision records](adr/); acceptance and product-scope decisions are recorded in [`docs/decisions/`](decisions/) and synchronized into the PRD and capability status in the same publication change.
