# Industrial Yard Demo Flight Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a repeatable, physically simulated 60-second Industrial Yard demo flight that can be launched from the normal player menu and externally recorded.

**Architecture:** Keep player navigation, map loading, native flight stepping, third-person camera, and HUD in `FlightRuntime`. Add one small pure route controller that maps elapsed time plus observed vehicle state to bounded Angle-mode commands; `FlightRuntime` applies those commands through the existing native control step and passes their normalized equivalents to the existing gamepad HUD. The demo has no video, GSP, replay-schema, or direct-transform path.

**Tech Stack:** Godot 4.7 GDScript, existing GUT coverage, C++ GDExtension flight control, X11 headed Godot run.

## Global Constraints

- Use the existing Player Mode, `FlightRuntime`, native flight-control, collision, third-person camera, and gamepad HUD paths.
- Fixed map is Industrial Yard; do not persist it as the player’s normal map selection or alter Quick Fly.
- The route lasts 60 seconds including its initial hover and ends by landing near SpawnNorth; Esc/back returns to the main menu and no ordinary flight input takes over.
- Keep all airframe values in the existing hardware configuration path; no new airframe constants or dependencies.
- Flight Replay and Dataset Recording remain separate from this feature; GSP remains an external development panel.
- Before CAP-006, headed X11 inspection is provisional Codex AI visual evidence, not a formal human visual review.

---

### Task 1: Define a testable Industrial Yard demo route

**Files:**
- Create: `common/flight/demo_flight_route.gd`
- Create: `tests/gut/test_demo_flight_route.gd`

**Interfaces:**
- Produces: `DemoFlightRoute.start(spawn: Vector3)`, `DemoFlightRoute.advance(delta: float, position: Vector3, velocity: Vector3, yaw_radians: float) -> Dictionary`, `DemoFlightRoute.cancel()`, and read-only lifecycle state through `snapshot() -> Dictionary`.
- Consumes: observed Godot-world body position/velocity and elapsed physics delta only.
- Returns: `{ phase, active, complete, target_position, target_speed_mps, yaw_rate_dps }`, with all route phases and control targets bounded.

- [ ] **Step 1: Write the failing route tests**

```gdscript
func test_route_starts_with_a_three_second_hover_and_reaches_all_recording_phases() -> void:
    var route := DemoFlightRoute.new()
    route.start(Vector3(0.0, 0.6, -24.0))
    var first := route.advance(0.0, Vector3(0.0, 3.0, -24.0), Vector3.ZERO, 0.0)
    assert_eq(first.phase, "hover")
    assert_eq(first.target_position, Vector3(0.0, 3.0, -24.0))
```

Also advance literal 1-second intervals and assert phase order `hover`, `low_pass`, `orbit`, `climb`, `return`, `land`, `complete`, a 60-second terminal time, finite targets, and a landing target at SpawnNorth.

- [ ] **Step 2: Run test to verify it fails**

Run: `GODOT_BIN=/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 scripts/run_gut_tests.sh tests/gut/test_demo_flight_route.gd`

Expected: FAIL because `demo_flight_route.gd` does not exist.

- [ ] **Step 3: Implement the smallest pure route controller**

Use one explicit elapsed-time phase table: 0–3 hover at 3 m above SpawnNorth; 3–15 low pass toward the central gate; 15–29 orbit the existing Tower with safe horizontal clearance; 29–38 climb; 38–52 return; 52–60 descend to SpawnNorth; complete afterward. Interpolate between literal world-space targets, cap target speed and yaw rate, and make `cancel()` immediately inactive. Do not move a body or call `Input` from this controller.

- [ ] **Step 4: Run test to verify it passes**

Run: `GODOT_BIN=/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 scripts/run_gut_tests.sh tests/gut/test_demo_flight_route.gd`

Expected: PASS, including phase progression and bounded-control assertions.

- [ ] **Step 5: Commit the route slice**

```bash
git add common/flight/demo_flight_route.gd tests/gut/test_demo_flight_route.gd
git commit -m "feat: add Industrial Yard demo route"
```

### Task 2: Connect the demo to Player Mode, native controls, and HUD

**Files:**
- Modify: `common/flight/flight_runtime.gd`
- Modify: `locales/ui.csv`
- Modify: `tests/gut/test_flight_runtime_load.gd`

**Interfaces:**
- Consumes: `DemoFlightRoute` snapshots while a demo is active.
- Produces: `start_demo_flight() -> void`, `cancel_demo_flight() -> void`, and a per-physics-frame command override used before normal player controls.
- Preserves: `quick_fly()`, normal map choice, controller confirmation, GSP, replay, and normal input behavior outside a demo.

- [ ] **Step 1: Write failing Player Mode behavior tests**

```gdscript
func test_demo_flight_menu_starts_industrial_yard_in_third_person_with_live_hud_controls() -> void:
    var runtime := _quick_fly_runtime()
    runtime.start_demo_flight()
    assert_eq(runtime.loaded_map_id, "industrial_yard")
    assert_true(runtime.third_person_view)
    assert_true(runtime.demo_flight_active())
```

Use the real runtime map/reset seam and assert that a route control packet contains non-neutral left and right stick values after the hover. Add a separate Esc test asserting it clears demo state, unloads the map through normal exit cleanup, and returns to `main_menu` without setting application quit.

- [ ] **Step 2: Run focused FlightRuntime test to verify it fails**

Run: `GODOT_BIN=/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 scripts/run_gut_tests.sh tests/gut/test_flight_runtime_load.gd`

Expected: FAIL because the demo menu entry and public lifecycle methods do not exist.

- [ ] **Step 3: Implement the menu/lifecycle/control override**

Add the localized `Demo Flight` menu entry and route it to `start_demo_flight()`. That method must verify the existing license gate, load/reset Industrial Yard without persisting it into `flight_setup`, force third person, arm/take off through the existing reset path, and start the pure route controller.

During native physics stepping, derive bounded roll, pitch, yaw-rate, and throttle from the route target and measured vehicle state, then replace the same control values passed to the existing native step. In `_refresh_gamepad_hud`, show the normalized values from that exact packet while the demo is active. Do not synthesize `InputEvent`s, set body transforms, add an autopilot label, or let GSP/player controls replace the demo packet.

Handle `flight_exit` first when a demo is active: call `cancel_demo_flight()`, perform normal map cleanup without quitting the application, and restore the main menu. On complete, use the same cleanup and main-menu return path.

- [ ] **Step 4: Run focused FlightRuntime tests to verify they pass**

Run: `GODOT_BIN=/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 scripts/run_gut_tests.sh tests/gut/test_flight_runtime_load.gd`

Expected: PASS, including existing Quick Fly and controller-route behavior.

- [ ] **Step 5: Commit the Player Mode slice**

```bash
git add common/flight/flight_runtime.gd locales/ui.csv tests/gut/test_flight_runtime_load.gd
git commit -m "feat: add Industrial Yard demo flight"
```

### Task 3: Tune the complete route and verify all gates

**Files:**
- Modify: `common/flight/demo_flight_route.gd` only if actual Industrial Yard safety tuning requires it
- Modify: `tests/gut/test_demo_flight_route.gd` only for a changed externally observable phase/control contract

**Interfaces:**
- Consumes: completed Player Mode demo lifecycle and the existing `SmokeScene`/Industrial Yard scene.
- Produces: 60-second low pass, tower orbit, climb, return, and landing with no collision and visible HUD motion.

- [ ] **Step 1: Add a failing completion-control test if the full route is not already covered**

```gdscript
func test_route_completes_at_spawn_after_return_and_landing() -> void:
    var route := DemoFlightRoute.new()
    route.start(Vector3(0.0, 0.6, -24.0))
    var terminal := route.advance(60.0, Vector3(0.0, 0.6, -24.0), Vector3.ZERO, 0.0)
    assert_true(terminal.complete)
    assert_eq(terminal.target_position, Vector3(0.0, 0.6, -24.0))
```

- [ ] **Step 2: Verify the focused automated suite**

Run:

```bash
GODOT_BIN=/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 scripts/run_gut_tests.sh tests/gut/test_demo_flight_route.gd tests/gut/test_flight_runtime_load.gd
scripts/test_native.sh
scripts/check_hardcoded_airframe_constants.sh
GODOT_BIN=/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 scripts/run_headless_smoke.sh --output build/headless_smoke.json --frames 5
```

Expected: every command exits zero.

- [ ] **Step 3: Run the Linux native/build/headless gate**

Run: `GODOT_BIN=/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 RUNNER_TEMP=/tmp/aerosim-ci scripts/verify_issue_11.sh`

Expected: zero exit status and its generated verification artifacts.

- [ ] **Step 4: Perform headed X11 visual verification**

Launch the debug scene using the supplied Godot binary, open `Demo Flight`, and inspect the actual game window through computer-use. Confirm: third-person framing; the unmodified HUD; both virtual sticks moving during control; low pass; safe tower orbit; high climb; smooth return/landing; Esc returns to menu; no collision or auto-navigation label. Record the observations in the issue/implementation handoff as provisional Codex AI visual verification.

- [ ] **Step 5: Commit any tuned route and evidence**

```bash
git add common/flight/demo_flight_route.gd tests/gut/test_demo_flight_route.gd
git commit -m "test: verify Industrial Yard demo flight"
```

## Plan Self-Review

- Spec coverage: Tasks 1–2 cover the menu, fixed map, 3-second hover, shared native/HUD controls, third-person, input suppression, cancellation, completion, and out-of-scope boundaries. Task 3 covers the full 60-second route, automated gates, and required provisional X11 evidence.
- No-placeholder check: every task names the files, public interfaces, behavior, commands, and success condition it requires.
- Type consistency: `DemoFlightRoute` is the sole route producer; `FlightRuntime` is its sole integration owner and consumes only its dictionary snapshot.

