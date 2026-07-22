# FPV Camera and OSD Presets Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task with review checkpoints.

**Goal:** Deliver Ubuntu FPV camera controls and Minimal/Race/Debug OSD presets using the existing `SettingsStore`, localization, and `TimeTrial` truth.

**Architecture:** Add small versioned validators for the existing `camera` and `osd` settings slots. `FlightRuntime` owns one live FPV `Camera3D`, one HUD `CanvasLayer`, and applies persisted values through the existing store; Race text reads `TimeTrial` state directly.

**Tech Stack:** Godot 4.7 GDScript, existing `SettingsStore`, `Localization`, `TimeTrial`, GUT/headless/headed acceptance scripts.

## Global Constraints

- Ubuntu desktop scope; mobile landscape/touch remains deferred per issue #36.
- Use only the existing `SettingsStore`; no second persistence path or placeholder Race data.
- Keep camera hardware defaults in the existing drone JSON/config path.
- Use localized `en` and `zh_TW` keys for every visible new string.
- Keep the OSD within the existing HUD `CanvasLayer`; no font/skin editor.

### Task 1: Settings contracts

**Files:**
- Create: `common/flight/camera_profile.gd`
- Create: `common/flight/osd_profile.gd`
- Modify: `common/flight/settings_store.gd`
- Test: `tests/gut/test_settings_store.gd`

- [x] Validate the existing camera and OSD slots, with explicit defaults and bounded values.
- [x] Ensure save/load/factory-reset preserve one complete versioned envelope and reject malformed nested data.

### Task 2: Runtime camera and OSD

**Files:**
- Modify: `common/flight/flight_runtime.gd`
- Modify: `locales/ui.csv`

- [x] Apply persisted camera settings to the live FPV camera and expose Camera/OSD controls from the pause overlay.
- [x] Render Minimal, Race, and Debug using telemetry/time-trial truth; keep center-third warning placement clear.
- [x] Persist changes through the existing store and restore them at startup/factory reset.

### Task 3: Automated evidence

**Files:**
- Modify: `tests/gut/test_settings_store.gd`
- Modify: `tests/gut/test_flight_runtime_load.gd`
- Modify: `tests/headless/industrial_yard_renderer_smoke.gd`
- Modify: `tests/headed/headed_acceptance.gd`

- [x] Assert preset contents, camera application, persistence, reset, localization, and ordered checkpoint truth.
- [x] Add deterministic geometry checks for OSD bounding boxes and center-third warning exclusion.
- [x] Run available native/GUT/headless/headed commands; report missing Godot-dependent gates explicitly.
