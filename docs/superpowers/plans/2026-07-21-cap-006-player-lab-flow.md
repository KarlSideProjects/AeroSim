# CAP-006 Player/Lab Flow Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox syntax for tracking.

**Goal:** Make issue #43's seven-entry Player/Lab menu a safe, testable cold-start-to-preflight flow.

**Architecture:** Extend the existing FlightRuntime state machine. It owns one LicenseProvider instance and one session-only Flight Setup dictionary, reuses existing map/wind/hardware/dashboard/exit methods, and does not create persistence, a second scene, a second native runtime, or a second RPC session.

**Tech Stack:** Godot 4.7, GDScript, GUT, existing headless smoke harness.

## Global Constraints

- Target Ubuntu Linux x86_64; preserve deterministic/headless checks.
- Read only sanitized license snapshots; never persist or display JWTs, license keys, claims, customer IDs, or device IDs.
- Do not alter PRD unless an approved product decision changes.
- On each resolved issue problem, post the root cause, solution, and validation to #43.
- No human visual/usability review before CAP-006 passes.

---

### Task 1: Wire the existing license provider

**Files:**
- Modify: common/flight/flight_runtime.gd
- Modify: tests/gut/test_flight_runtime_load.gd

**Consumes:** LicenseProvider public configure, activate, refresh_online, and get_snapshot methods.

**Produces:** one runtime-owned provider, a named license_blocked screen, and public route methods for the UI.

- [ ] **Step 1: Write the failing behavior tests**

~~~
func test_quick_fly_fails_loudly_when_license_provider_configuration_fails() -> void:
    var runtime := _runtime_with_missing_license_config()
    assert_eq(runtime.screen, "license_blocked")
    runtime.quick_fly()
    assert_false(runtime.takeoff_requested)

func test_only_online_and_offline_grace_license_snapshots_can_start_quick_fly() -> void:
    var runtime := _runtime_with_license_snapshot("offline_grace_valid")
    assert_true(runtime.can_start_quick_fly())
    runtime = _runtime_with_license_snapshot("revoked")
    assert_false(runtime.can_start_quick_fly())
~~~

- [ ] **Step 2: Verify RED**

Run: GODOT_BIN=/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 scripts/run_gut_tests.sh --recovery-mode

Expected: new tests fail because FlightRuntime has no provider.

- [ ] **Step 3: Implement the minimum provider boundary**

Preload LicenseProvider, create/configure it once during startup, and store no copied state. Configure failure calls a named license-blocked screen. Quick Fly proceeds only for online_valid and offline_grace_valid. not_activated exposes non-persistent activation; expired/revoked/invalid expose only the provider-appropriate retry, Diagnostics, and Exit actions. Clear the entered key after its awaited activation request.

- [ ] **Step 4: Verify GREEN and commit**

Run the same GUT command. Expected: new tests pass with no Godot ERROR output.

~~~
git add common/flight/flight_runtime.gd tests/gut/test_flight_runtime_load.gd
git commit -m "feat: gate Quick Fly on license status"
~~~

### Task 2: Replace the five-entry menu with one setup flow

**Files:**
- Modify: common/flight/flight_runtime.gd
- Modify: tests/gut/test_flight_runtime_load.gd

**Consumes:** DEFAULT_HARDWARE_PRESET, DEFAULT_FREE_FLIGHT_MAP_ID, WIND_PRESETS, select_map, load_map, and enter_preflight.

**Produces:** seven ordered buttons, one flight_setup screen, and one session-only setup dictionary.

- [ ] **Step 1: Write the failing behavior tests**

~~~
func test_drone_and_map_open_the_same_flight_setup_with_different_focus() -> void:
    var runtime := _licensed_runtime()
    runtime.open_flight_setup("drone")
    assert_eq(runtime.screen, "flight_setup")
    assert_eq(runtime.flight_setup_focus, "drone")
    runtime.open_flight_setup("map")
    assert_eq(runtime.flight_setup_focus, "map")

func test_quick_fly_reapplies_default_setup_after_a_prior_setup_choice() -> void:
    var runtime := _licensed_runtime()
    runtime.apply_flight_setup({"wind_preset": "severe"})
    runtime.quick_fly()
    assert_eq(runtime.selected_wind_preset, "calm")
~~~

- [ ] **Step 2: Verify RED**

Run: GODOT_BIN=/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 scripts/run_gut_tests.sh --recovery-mode

Expected: the shared-panel and Quick Fly reset assertions fail.

- [ ] **Step 3: Implement the minimum setup contract**

Set menu order to Quick Fly, Lab Mode, Controller, Drone, Map, Settings, Quit. Add default_flight_setup and apply_flight_setup with exact allowed values: existing hardware preset, industrial_yard, ANGLE, and an existing WIND_PRESETS value. Drone and Map route to one panel, with initial focus only differing. Display Industrial Test Range while retaining industrial_yard internally. Remove the Map-only rain/fog/time controls from this flow. Quick Fly calls apply_flight_setup(default_flight_setup()) before controller/preflight routing.

- [ ] **Step 4: Verify GREEN and commit**

Run the same GUT command. Expected: shared-panel and default-reset tests pass.

~~~
git add common/flight/flight_runtime.gd tests/gut/test_flight_runtime_load.gd
git commit -m "feat: add CAP-006 flight setup flow"
~~~

### Task 3: Complete remaining routes and cold-start evidence

**Files:**
- Modify: common/flight/flight_runtime.gd
- Modify: tests/gut/test_flight_runtime_load.gd
- Modify: common/smoke/headless_smoke.gd

**Consumes:** controller confirmation/fallback, set_dashboard_layout_mode, show_settings, request_exit, and completed Task 1-2 routes.

**Produces:** caller-aware Controller behavior, same-session Lab layout, cleanup-safe Quit, and seven-entry smoke evidence.

- [ ] **Step 1: Write failing GUT and smoke assertions**

~~~
func test_controller_confirmation_returns_to_menu_when_opened_from_controller() -> void:
    var runtime := _licensed_runtime()
    runtime.open_controller_from_menu()
    runtime.accept_controller_confirmation()
    assert_eq(runtime.screen, "main_menu")

func test_lab_mode_reuses_the_existing_runtime_and_dashboard() -> void:
    var runtime := _licensed_runtime()
    var native_before := runtime.native
    runtime.open_lab_mode()
    assert_eq(runtime.dashboard_layout_mode, "full")
    assert_same(runtime.native, native_before)
~~~

In headless smoke, require the exact seven entries and assert that Drone/Map share setup, Quick Fly resets defaults, Lab retains the same native object, and missing provider configuration fails loudly without secret output.

- [ ] **Step 2: Verify RED**

Run: GODOT_BIN=/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 scripts/run_headless_smoke.sh --output build/headless_smoke.json --frames 5

Expected: it fails on obsolete five-entry expectations before the smoke update.

- [ ] **Step 3: Implement only route state**

Store controller return target; only Quick Fly's target calls preflight. Lab calls set_dashboard_layout_mode("full"); its return restores compact and main menu. Route Settings through show_settings and Quit through request_exit.

- [ ] **Step 4: Verify GREEN**

Run:
- GODOT_BIN=/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 scripts/run_gut_tests.sh --recovery-mode
- GODOT_BIN=/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 scripts/run_headless_smoke.sh --output build/headless_smoke.json --frames 5
- GODOT_BIN=/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 RUNNER_TEMP=/tmp/aerosim-ci-43 scripts/verify_issue_11.sh

Expected: all checks pass; the final command covers native, GUT, smoke, extension build, and Linux verification.

- [ ] **Step 5: Commit and record evidence**

~~~
git add common/flight/flight_runtime.gd tests/gut/test_flight_runtime_load.gd common/smoke/headless_smoke.gd
git commit -m "test: cover CAP-006 cold start flow"
~~~

Comment on #43 with each resolved provider/setup/controller/Lab problem, commands, outcomes, and the explicit statement that human visual review remains deferred.

