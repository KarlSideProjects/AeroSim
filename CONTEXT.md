# AeroSim

A drone simulation platform for interactive flight and autonomous-system development. Its default experience is game-like, but the product is not defined solely as a game.

## Language

**Simulation Platform**:
The whole AeroSim product: a shared, testable simulated world available to both people and software.
_Avoid_: Game, FPV game

**Player Mode**:
The default human-facing experience for selecting a drone and environment, then flying interactively.
_Avoid_: The game

**Lab Mode**:
The software-facing experience for controlling simulations and observing vehicles, sensors, and the world programmatically.
_Avoid_: Debug mode, developer mode

**AirSim Compatibility Surface**:
The versioned subset of AirSim 1.8.1 Python client operations and `settings.json` fields for which existing clients work unchanged. Operations and settings outside the published subset are unsupported rather than approximately emulated.
_Avoid_: AirSim-like API, Full AirSim compatibility

**AirSim-class Minimum**:
The minimum externally observable multirotor capability set required for AeroSim to be considered a credible alternative to Microsoft AirSim; visual resemblance alone does not satisfy it. Cars and road-vehicle simulation are outside this boundary.
_Avoid_: AirSim UI parity, AirSim clone

**Baseline Sensor Suite**:
The observations guaranteed by every AirSim-class release: RGB, depth, segmentation, IMU, GPS, magnetometer, barometer, and LiDAR. Optical flow, distance sensors, and object detection are extensions rather than baseline requirements.
_Avoid_: Full sensor parity

**AI Visual Verification**:
The required Codex review of deterministic scene screenshots for visual coherence, readable lighting, plausible scale, intact assets, and gameplay legibility. It uses a versioned rubric for visual changes and releases, complements deterministic checks that run on every pull request, and emits machine-readable evidence.
_Avoid_: Screenshot exists, Non-monochrome check

**Approved Visual Reference**:
The human-approved screenshots and render manifest that define the intended appearance after the Playable Game Milestone. Before that milestone, Codex uses provisional references without requesting human approval. Later renders are evaluated automatically against the approved reference by deterministic image checks and AI Visual Verification.
_Avoid_: Example screenshot, Latest screenshot

**Playable Game Milestone**:
The first complete production-facing Ubuntu Player Mode loop: cold start, seven-entry navigation, controller/drone/map selection, Quick Fly, production scene and vehicle, flight, collision, pause, respawn, Time Trial completion, and quit. Human visual and usability review begins only after this loop passes automated and headed verification.
_Avoid_: Smoke scene, Feature-complete backend, Graybox review

**AirSim Reference Checkout**:
The external, read-only checkout of Microsoft AirSim `v1.8.1` at commit `96235148a332fe7cb3d3525a0720e26faaca99e0`, used only for compatibility and implementation research after relevant open and closed upstream issues are audited.
_Avoid_: AirSim dependency, Vendored AirSim, AirSim scene source

**Reference Environment**:
The single shippable Industrial Test Range required by the AirSim-class minimum. Its coherent industrial site contains a launch area, warehouse and street geometry, an obstacle corridor, and a short time-trial route serving Player Mode, Lab Mode, the Baseline Sensor Suite, and visual acceptance.
_Avoid_: Demo map, Three-map set

**Map Catalog**:
The Player Mode selection surface and its data source for shippable environments. It contains only the Industrial Test Range in the AirSim-class minimum but remains visible so later environments can be added without replacing the navigation flow.
_Avoid_: Hidden single map, Coming Soon maps

**Vehicle Instance**:
A uniquely named multirotor in a simulation session, with its own physical state, control authority, and sensor observations. The AirSim-class minimum supports two simultaneous Vehicle Instances while Player Mode controls one.
_Avoid_: Drone object, Visual drone, NPC drone

**Operations Dashboard**:
The human interface for selecting a Vehicle Instance and observing telemetry, sensor previews, flight-controller and API status, recording, and weather. Player Mode presents a compact view while Lab Mode exposes the full dashboard.
_Avoid_: Web dashboard, Debug panel

**Flight Replay**:
A reproducible flight reconstructed from recorded control inputs and simulation conditions.
_Avoid_: Dataset, Video replay

**Dataset Recording**:
Time-aligned vehicle commands, state, collision, weather, camera, and sensor observations captured for analysis and AI workflows. It records both Vehicle Instances independently of whether the flight will be replayed.
_Avoid_: Replay, Debug log

**Scene Object**:
A named spawnable item from the approved asset catalog, with a transform, collision shape, and segmentation label. External or arbitrary runtime-imported files are not Scene Objects.
_Avoid_: Arbitrary model, Unreal asset

**Environment Controls**:
The session-level controls for wind, rain, fog, and time of day including sun position. Snow, dust, and wet-road material simulation are extensions rather than AirSim-class minimum requirements.
_Avoid_: Full weather simulation, Weather preset only

**External Coordinate Contract**:
The public spatial convention shared by the AirSim Compatibility Surface, PX4 bridge, Flight Replay, and Dataset Recording: NED world axes, FRD vehicle-body axes, and SI units. Godot's Y-up coordinates remain an internal representation behind one tested conversion boundary.
_Avoid_: Godot coordinates, Mixed coordinate systems

**RPC Access Boundary**:
The network exposure allowed for the AirSim Compatibility Surface: loopback only, defaulting to `127.0.0.1:41451`, with a configurable port. LAN and Internet binding are outside the first release until authentication and transport security are designed.
_Avoid_: Public API endpoint, Remote Lab Mode

**Flight Command Surface**:
The AirSim-compatible commands available to each named Vehicle Instance: takeoff, land, hover, return home, position, path, velocity, yaw, and attitude or body-rate plus throttle control. Direct per-motor PWM control is outside the first release.
_Avoid_: Full motor control, Player input API

**Camera Output Surface**:
The AirSim-compatible image outputs guaranteed by the first release: `Scene`, `DepthPlanar`, and `Segmentation`, using the pinned client's PNG, raw-byte, and floating-point depth behaviors. Other AirSim image types are extensions.
_Avoid_: All AirSim ImageTypes, Dashboard preview

**Sensor Timebase**:
The single simulation-time clock used to timestamp and schedule every sensor observation. Pausing freezes it, deterministic stepping advances it, and each sensor samples at its configured rate; wall-clock time is not sensor truth.
_Avoid_: Wall-clock timestamp, Render-frame timestamp

**Qualification Platform**:
The platform on which every AirSim-class minimum capability must pass together: Ubuntu x86_64. Windows and Android may ship Player Mode lanes, but their Lab Mode parity does not block the first qualified platform release.
_Avoid_: All-platform minimum, Linux-only product

**Reference Performance Profile**:
The designated Ubuntu performance runner with a 6-core CPU, 16 GB RAM, and RTX 3060 12 GB-class GPU. Only this profile can pass or fail the 1080p Player Mode and Lab Mode real-time performance gates.
_Avoid_: Minimum developer hardware, Required local machine

**Local Development Profile**:
Any developer machine running functional and deterministic verification, optionally with reduced visual quality or sensor rates. Hardware below the Reference Performance Profile is reported as not performance-qualified, never as a functional failure solely because of its specification.
_Avoid_: Unsupported hardware, Performance runner

**Reference Asset Set**:
The checked-in visual supply for the Industrial Test Range: Kenney City Kit (Industrial) under CC0, supplemented only by Godot primitives or project-created assets where necessary. Unity and Unreal scenes are not dependencies of the shippable environment.
_Avoid_: Converted AirSim map, Marketplace asset mix

**Dataset Package**:
A versioned recording directory containing `manifest.json`, `samples.jsonl`, PNG RGB and segmentation images, PFM planar-depth images, and little-endian float32 LiDAR points. An interrupted package remains explicitly incomplete until final validation succeeds.
_Avoid_: Database, Replay file, ROS bag

**Reference Vehicle Visual**:
The project-created, low-poly industrial quadrotor appearance shared by both Vehicle Instances, with a distinct accent color for each name. Its visual nodes are separate from physics, collision, and sensor mounts.
_Avoid_: AirSim drone asset, Physics mesh
