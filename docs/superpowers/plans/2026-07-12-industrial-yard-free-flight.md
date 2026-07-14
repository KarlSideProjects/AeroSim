# Industrial Yard Free Flight Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver one renderer-shared Industrial Yard Free Flight scene with descriptor, spawn/reset/exit behavior, and headed evidence for #35.

**Architecture:** A map descriptor owns map metadata; the scene owns geometry and collision; runtime owns the load/reset/exit lifecycle. #43 consumes the descriptor later and owns map-card UI.

**Tech Stack:** Godot 4.7, GDScript, Jolt, Forward+/Mobile renderer, existing smoke and headed harnesses.

## Global Constraints

- One `industrial_yard.tscn` for Forward+ and Mobile; no `*_mobile.tscn` or asset branch.
- Descriptor must expose map id, name, type, recommended aircraft, wind preset, spawn count, and mode.
- Exit stops flight, frees map, and returns to the main-menu stub.
- Do not modify #106 ACRO physics/helpers, #40 profile/Quick Fly controls, #43 map UI, or #31 wind implementation.
- Map load failure is explicit; no fallback to smoke scene.
- Keep G0.1 benchmark and headless measurement scenes unchanged.
- PR body uses `Refs #35`; Linux real-display headed plus maintainer play confirmation is required before closing #35.

---

### Task 1: Add Descriptor and Shared Industrial Yard Scene

**Files:**
- Create: `common/maps/free_flight_map.gd`
- Create: `config/maps/industrial_yard.json`
- Create: `levels/free_flight/industrial_yard.tscn`
- Modify: `common/smoke/headless_smoke.gd`

- [ ] Write failing smoke assertions for descriptor fields, `SpawnNorth`, a ground, cargo containers, low gate, turn marker, tower, and StaticBody3D collision.
- [ ] Implement a descriptor loader that rejects missing required fields and loads `industrial_yard`; construct the scene from primitive meshes/materials and matching collision bodies.
- [ ] Run fixed Godot runtime smoke; expect descriptor and scene assertions to pass.
- [ ] Commit: `git commit -m "feat: add industrial yard scene"`.

### Task 2: Integrate Map Lifecycle Without Touching Controls

**Files:**
- Modify: `common/flight/flight_runtime.gd`
- Modify: `common/smoke/headless_smoke.gd`
- Modify: `tests/headed/headed_acceptance.gd`

- [ ] Write failing tests for `load_map("industrial_yard")`, reset to `SpawnNorth` with cleared velocities, explicit missing-map error, and exit returning to `main_menu` with map freed.
- [ ] Implement `load_map`, `reset_to_spawn`, and exit lifecycle only outside profile/Quick Fly and ACRO helper sections; point the Free Flight default at Industrial Yard.
- [ ] Run runtime/full smoke and headed acceptance; expect active Camera3D, non-monochrome Industrial Yard, reset and exit assertions to pass.
- [ ] Commit: `git commit -m "feat: load industrial yard free flight"`.

### Task 3: Enforce Renderer Sharing and Evidence

**Files:**
- Create: `scripts/check_shared_map_assets.sh`
- Modify: `docs/reports/industrial-yard-validation-<commit>.md`

- [ ] Write a failing shell check that rejects `levels/free_flight/*_mobile.tscn` and descriptors pointing to distinct desktop/mobile scenes.
- [ ] Implement the check, run it plus Forward+ and Mobile scene-load smoke; verify G0.1 benchmark inputs remain unchanged.
- [ ] Run native tests, full smoke, real-display headed acceptance, and record commands, artifacts, and the unverified maintainer playthrough.
- [ ] Commit: `git commit -m "docs: validate industrial yard free flight"`.

## Plan Self-Review

- Task 1 covers map content and descriptor completeness; Task 2 covers spawn/reset/exit and runtime boundary; Task 3 covers dual-renderer no-branch proof, G0.1 isolation, and evidence.
- No task introduces #43 UI, #31 wind mechanics, a second map, external assets, or control-loop changes.
