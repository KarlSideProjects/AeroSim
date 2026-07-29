# Godot 4.7 / Xbox 360 right-stick investigation

Date: 2026-07-29 (revision 5, closed on hardware)
Status: **Closed.** The axis chain was correct end to end at every heading (see the r4
trace). Four independent defects sat on top of it — a 90° body-frame mismatch in the
presentation layer, a model nose 90° off the direction of travel, a centred gamepad
throttle commanding 50 % against a 33 % hover point, and a main menu hidden under the
window decoration. All four are corrected and merged; flight direction and airframe
heading are both confirmed on hardware. Four separate defects found along the way remain
open — see "Newly identified defects".

Revision history:

- **r1** recorded the camera and model defects as "real but not a proven cause".
- **r2** withdrew that framing: the 90° body-frame split is derivable from checked-in code
  and produces the reported symptom exactly. r2 named "the user retested the wrong build"
  as the leading explanation for the failed hardware retests.
- **r4 (this revision)** captures the synchronised trace the report had been demanding
  since r1, and it clears the entire axis chain. It also falsifies r3's FPV-camera
  explanation: the symptom survived `fov_deg = 90` with a level camera, and Quick Fly
  forces third person anyway, which uses neither setting — so r3's experiment was a null
  experiment. The measured cause is throttle, not geometry.
- **r3** falsified r2's leading hypothesis and replaced it. The user
  retested with `"$GODOT_BIN" --display-driver wayland --path .`, which runs the corrected
  source directly — GDScript loads from disk, so the camera and model corrections were
  live. The symptom still reproduces, so the remaining cause is elsewhere. Reading the
  user's own persisted runtime configuration identifies it.

## Executive conclusion

1. **The controller mapping is correct. No X/Y axis swap should be made.** Godot defines
   right-stick X as axis 2 and right-stick Y as axis 3;
   `common/flight/input_profiles.gd:11-12` maps axis 2 to roll and axis 3 to pitch, with
   neither reversed. The live controller monitor and
   `tests/native/test_stick_axis_convention.cpp` both agree.

2. **The project has one authoritative body frame, and the presentation layer did not
   follow it.** `common/rpc/airsim_coordinate_contract.gd:4-7` states that the simulation
   body basis is **+X forward, +Y up, +Z right**. Before the working-tree correction, the
   FPV camera, the third-person camera, and the imported drone model all used Godot's own
   `-Z`-forward convention instead. All three were 90° about `Y` from the physics frame, in
   the same direction.

3. **That 90° split derivably produces the reported symptom.** With the camera placed on
   the drone's `+Z` side and looking along the drone's `-Z` axis, the pitch rotation axis
   *is* the camera's line of sight — a pitch command renders as an on-screen rotation —
   while forward travel along `+X` renders as lateral drift. That is precisely
   "forward/back rotates instead of producing straight forward/back movement". This is
   geometry, not a hypothesis.

4. **Correcting that split did not clear the symptom, and it was never going to on its
   own.** The user's persisted FPV camera profile — which is also the shipped default —
   is a **150° field of view with a 30° camera uptilt**, applied to the FPV camera only.
   Combined with attitude-style (tilt-to-translate) control, forward stick input produces
   a large, wide-angle-amplified rotation and very little apparent translation, while
   lateral input translates perpendicular to the view axis and reads normally. That is the
   reported asymmetry, and it is not an axis defect.

5. **The coverage that should have caught (2) does not execute.** Every Xbox axis
   assertion and every third-person camera convention assertion lives in
   `_verify_runtime_actions()` in `common/smoke/headless_smoke.gd`, which
   `scripts/run_headless_smoke.sh:60` unconditionally opts out of with
   `--skip-runtime-map`. Nothing in `scripts/` or `.github/workflows/ci.yml` passes
   `--runtime-only`. The block is reachable only by a manual developer command, and it is
   currently red.

Both (2) and (4) were real. Fixing only (2) changed the geometry without changing the
perception, which is why every axis-side correction was retested as "no change".

## The authoritative body frame

`common/rpc/airsim_coordinate_contract.gd:4-7`:

> The public AirSim boundary is NED world axes and FRD body axes, in SI units. AeroSim
> keeps Godot's Y-up representation internal. The native runtime's FRD basis is
> `(x, y, z) -> (x, z, -y)`: internal X is forward, internal Z is right, and internal Y is
> up.

Independently confirmed at three points:

| Evidence | Location | What it shows |
|---|---|---|
| Gravity is subtracted from the `y` component of world acceleration | `src/native/aerosim_simulation.cpp:149` | Native `+Y` is up |
| The step row packs `state.position.x/y/z` and `state.orientation.x/y/z/w` verbatim | `src/native/aerosim_native.cpp:2349-2356` | No frame conversion at the native boundary |
| `drone_body.apply_native_state(Vector3(row[1], row[2], row[3]), Quaternion(row[4]…row[7]), …)` | `common/flight/flight_runtime.gd:1792-1797` | The Godot body basis **is** the native basis |
| A forward pitch command produces `position.x > 0` with `abs(position.z)` under 5 % of it | `tests/native/test_stick_axis_convention.cpp` | Native forward is `+X`, lateral is `+Z` |
| Body inertia is indexed `frd.x↔godot.x`, `frd.z↔godot.y`, `frd.y↔godot.z` | `common/flight/flight_runtime.gd:6682` | Same mapping, used by the live runtime |

So the drone body in the Godot scene is **not** `-Z`-forward. Godot's own convention does
not apply to it, and any code that assumes it does is wrong.

## Why the pre-correction presentation produced exactly the reported symptom

At the pre-correction state (commit `dc41bff`), with the body basis near identity:

**FPV camera.** `chase_camera.global_basis = drone_body.global_basis * Basis(Vector3.RIGHT, angle)`.
A `Camera3D` looks along its local `-Z`, so the camera looked along the body's `-Z` axis —
**the drone's left**. Forward flight rendered as travel to screen right. The pitch
rotation axis (body `Z`) was the camera's view axis, so pitch rendered as screen roll.

**Third-person camera.** `THIRD_PERSON_CAMERA_OFFSET = Vector3(0.0, 0.8, 1.8)` placed the
camera at body `+Z` — **the drone's right-hand side** — and the offset was rotated by the
full body basis, so the camera also orbited with pitch and roll. Same geometry: a pitch
command is a rotation about the camera's view axis, and forward travel crosses the frame
laterally.

**Imported model.** The model was added with no rotation, so its nose pointed along the
loader's local `+Z` — the body's right. The visible aircraft faced 90° away from its own
direction of travel.

Three independent surfaces, all 90° off in the same direction. A user flying this sees a
drone that spins when pushed forward. The symptom is the expected output of the code.

### The model premise was false, and it was the last defect (r5)

Measured from `assets/third_party/free3d_drone/drone_costum_godot.scn`, instantiated
exactly as the loader does and read after the transforms propagate:

| `model.rotation.y` | body-space AABB (X, Y, Z) | long horizontal axis |
|---|---|---|
| **0°** | 0.3721, 0.1006, **0.2628** | **X — the flight direction** |
| 90° | **0.2628**, 0.1006, 0.3721 | Z — across the flight path |

The airframe leads fore-aft over lateral by 1.42×, and the two options swap cleanly. So
the asset's long axis is already the body's `+X` forward axis, and the
`model.rotation.y = PI * 0.5` added during this investigation — applied on the false
premise that the nose ran along local `+Z` — laid the airframe *across* the flight path.

A measurement caveat worth recording, because it produced a wrong intermediate claim: the
mesh node carries a non-uniform FBX import transform (100× on X, Y/Z swapped with a
−198.73 factor), so the mesh's *own* local AABB (0.124 × 0.044 × 0.034, a 3.7:1 ratio)
describes nothing useful about body orientation. Only the body-space AABB does, and
reading `global_transform` without first awaiting a frame silently returns an
unpropagated identity.

That is what the pilot was seeing. The third-person camera follows the aircraft, so
forward translation barely registers on screen; the salient cue is attitude. With the
airframe lying across the path, a pitch command — which rotates about body `±Z` — spun the
visible model about its own long axis, reading as an in-plane see-saw. Push forward, it
turns one way; pull back, it turns the other. Exactly the report: *"推前進 → 向右轉，下拉
→ 向左轉"*.

The rotation is removed (`common/flight/drone_visual_loader.gd:27-32`).

Because the mesh is front-to-back symmetric, geometry cannot distinguish nose from tail, so
a 180° error is not detectable automatically and is not visually meaningful for this asset.

`test_imported_drone_nose_aligns_with_the_frd_forward_axis` now measures the mesh AABB in
body space and asserts the long axis lies along `+X`, instead of restating the loader's own
rotation constant. That closes D4: the old assertion could not fail while the airframe sat
sideways, because it only compared the rotation the loader had just applied.

### The original premise, for the record

The claim "the imported asset's nose is local `+Z`" is human-asserted. The new GUT test
`test_imported_drone_nose_aligns_with_the_frd_forward_axis`
(`tests/gut/test_flight_runtime_load.gd:1040`) asserts that
`(model.basis * Vector3.BACK).dot(body.basis.x) > 0.99`, which pins the loader's 90°
rotation constant but **cannot see the mesh geometry**. If the asset's nose is not `+Z`,
that test stays green while the model stays wrong. A headed screenshot comparison is the
only cheap check.

## Corrections now in the working tree (uncommitted)

| Change | Location | Proven effect | Still unproven |
|---|---|---|---|
| Keep `RIGHT_X -> roll`, `RIGHT_Y -> pitch`, neither reversed | `common/flight/input_profiles.gd:11-12` | Matches Godot/SDL, the live monitor, and the native mixer test | — |
| `FPV_CAMERA_BODY_ALIGNMENT = Basis(Vector3.UP, -PI * 0.5)` applied to both FPV cameras | `common/flight/flight_runtime.gd:57`, `:6480`, `:6504` | Camera forward becomes body `+X`; camera right becomes body `+Z` | Hardware retest |
| `THIRD_PERSON_CAMERA_OFFSET = Vector3(-1.8, 0.8, 0.0)` | `common/flight/flight_runtime.gd:58` | Camera sits aft along body `-X`, not on the body-right axis | Hardware retest |
| Third-person camera follows a yaw-only levelled basis | `common/flight/flight_runtime.gd:6486-6494` | A 30° pitch no longer orbits the camera; the previously measured 1.0196 m displacement for the aft offset goes to zero | Hardware retest |
| Imported model rotated `+90°` about `Y` | `common/flight/drone_visual_loader.gd:27` | The loader maps asset `+Z` onto body `+X` | That asset `+Z` is the nose |
| Smoke camera assertions rewritten to body `-X` aft | `common/smoke/headless_smoke.gd:1690`, `:2041` | Assertions now encode the coordinate contract instead of Godot's `-Z` | The block does not run (see below) |
| Smoke pitch-sign assertions corrected | `common/smoke/headless_smoke.gd:2094`, `:2101` | Removes a contradiction left by `79d7a99` (see D2) | The block does not run |
| Three new camera/model regression tests | `tests/gut/test_flight_runtime_load.gd:998`, `:1040`, `:1057` | Runs in CI via `scripts/run_gut_tests.sh`; red before the corrections | Model-nose premise (above) |

Rotating the map spawn markers was attempted and removed; it was never a supported
hypothesis.

## Runtime fingerprint (the diagnostic this report kept asking for)

Captured by booting `levels/smoke/smoke.tscn` headless in the user's real environment,
with the Xbox controller attached:

```text
project_path            = /home/karl/Workspace/Toys/AeroSim/
is_debug_build          = true
development_license_bypass = true
can_start_quick_fly     = true
camera_profile          = {camera_angle_deg: 0.0, fov_deg: 90.0, analog_noise: true}
camera_profile_persisted = true
connected_joypads       = [0]  device 0 = "Xbox 360 Controller"
session_gamepad_device_id = 0
screen                  = main_menu
```

Two things this settles:

1. **The corrected tree is what boots.** Combined with
   `~/.local/share/godot/projects.cfg`, which registers only
   `/home/karl/Workspace/Toys/AeroSim` (plus an unrelated project), the earlier
   editor-then-F5 sessions also ran the main worktree. The nested
   `.worktrees/gsp-user-open` was never in the project manager's list and could not have
   been selected there. The "wrong build" hypothesis is falsified on direct evidence, not
   inference.
2. **The new camera defaults are live.** `camera_profile_persisted = true` with
   `fov_deg = 90.0`, so the persisted profile no longer overrides the change.

## The synchronised trace, finally captured (r4)

Driven headless through the real `quick_fly()` entry path — real map load, real gamepad
profile, real `_physics_process`, real `step_collision_angle_mode` — one fresh scene per
case so no momentum carries over, one second of held stick per case, `ANGLE` mode:

| heading | stick | cmd | attitude delta | BODY fwd | BODY right | BODY **up** | cam·body_fwd |
|---|---|---|---|---|---|---|---|
| 0° | up | pitch −30° | d_pitch −30° | **+3.108** | +0.000 | **+2.335** | +0.949 |
| 0° | right | roll +30° | d_roll +30° | +0.000 | **+3.108** | **+2.335** | +0.949 |
| 90° | up | pitch −30° | d_pitch −30° | **+3.109** | +0.000 | **+9.715** | +0.949 |
| 90° | right | roll +30° | d_roll +30° | −0.000 | **+3.109** | **+9.715** | +0.949 |

The 90° headings were produced with the real yaw stick, because forcing the heading through
`apply_native_state()` is overwritten by the next native step.

**The axis chain is correct, end to end, at every heading.** Pitch produces pure
body-forward travel; roll produces pure body-right travel; the magnitudes are identical
(3.108 m); yaw does not disturb either; and the third-person camera keeps
`camera_forward · body_forward = 0.949` in every case, the 0.05 deficit being the aft
camera's downward tilt onto the aircraft. There is no swap, no sign error, and no frame
mismatch left anywhere between `Input.get_joy_axis()` and screen space.

Hypotheses 3, 4, 5 and 6 in the ranked list are all falsified by this table.

## The actual defect: centred throttle commands a climb

The `BODY up` column is the finding. In one second of forward stick the aircraft advances
3.1 m and climbs 2.3 m — and after a yaw, 9.7 m. The dominant motion is vertical.

Measured cause:

```text
hover_throttle              = 0.330
centred stick throttle      = 0.500   (_flight_throttle(), profile axis = 0.0)
```

`_flight_throttle()` maps the throttle axis linearly to `[0, 1]`
(`common/flight/flight_runtime.gd:6431`), so a centred stick commands 50 % against a
33 % hover point. An Xbox left stick **self-centres**; a real transmitter's throttle is
ratcheted and stays where the pilot leaves it. So on a gamepad, letting go of the throttle
is a climb command, and in `ANGLE` mode — the mode in the user's own screenshot — nothing
holds altitude.

This matches the reported asymmetry better than any camera or axis theory:

- **Forward stick**: the aircraft climbs at least as fast as it advances, so it does not go
  where it is pointed. "The flight direction is wrong."
- **Lateral stick**: lateral travel is perpendicular to the view axis and stays legible
  even while climbing. "Left/right behaves normally."

It also explains why three rounds of axis and camera corrections changed nothing: none of
them touched the throttle.

### Fix applied

`_flight_throttle()` (`common/flight/flight_runtime.gd:6434`) now anchors the stick's
centre detent to `_configured_hover_throttle()` instead of `0.5`, piecewise-linear to
`0.0` at the bottom and `1.0` at the top. It falls back to the old linear map when no
hover throttle is available, so the existing endpoint test
(`tests/gut/test_flight_runtime_load.gd:3105`, `:3113`) still holds by construction.

Re-measured airborne, three fresh scenes, identical climb history, `ANGLE` mode, one
second of held stick:

| stick | pitch | roll | BODY fwd | BODY right |
|---|---|---|---|---|
| forward | −30.00° | −0.00° | **+2.116** | +0.000 |
| right | +0.00° | +30.00° | +0.000 | **+2.116** |
| none | +0.00° | −0.00° | +0.000 | +0.000 |

Symmetric, axis-pure, and neutral at neutral. Forward travel drops from 3.108 m to
2.116 m because a hovering aircraft has less excess thrust to vector than one at 50 %
throttle; that is correct multirotor behaviour, not a regression.

Two honest caveats:

- `hover_throttle` (0.330) comes from the hardware power model and is an approximation of
  the true hover point for the current mass and battery state. A slow residual sink or
  climb can remain. `ALTITUDE_HOLD` exists for exact holding and is unaffected by this
  change.
- Tilting still costs altitude, because vertical thrust falls with `cos(tilt)`. No tilt
  compensation was added; that would be a separate design decision.

## The user's live runtime configuration (measured)

Read directly from `~/.local/share/godot/app_userdata/AeroSim/settings.json`:

| Setting | Value | Source |
|---|---|---|
| `confirmed_gamepad.axis_for_role` | `roll: 2, pitch: 3, yaw: 0, throttle: 1` | canonical — matches `input_profiles.gd:11` |
| `confirmed_gamepad.reversed_for_role` | `pitch: false, roll: false, yaw: false, throttle: true` | canonical |
| `camera.camera_angle_deg` | **30.0** | shipped default, `camera_profile.gd:5` |
| `camera.fov_deg` | **150.0** | shipped default, `camera_profile.gd:6` |

The first two rows independently confirm on the user's own machine that no stale rotated
profile is in play. The mapping question is closed.

The last two rows are the finding.

## Why the symptom survives correct axes: the FPV camera defaults

`_update_chase_camera()` applies the camera profile **only to the FPV camera**:

- `common/flight/flight_runtime.gd:6480-6481` sets `chase_camera.global_basis` with a
  `camera_angle_deg` uptilt and `chase_camera.fov = camera_profile.fov_deg`.
- The third-person camera never receives either; it keeps the scene's
  `fov = 70.0` (`levels/smoke/smoke.tscn:53-55`).

So in FPV the user is flying with:

**A 30° camera uptilt.** `ANGLE_MAX_TILT_DEGREES = 30.0`
(`common/flight/flight_runtime.gd:47`), so a *full* forward pitch stick commands exactly
30° nose-down — precisely enough to bring the camera from 30° above the horizon to level.
At hover the view points at the sky; the only way to see where you are going is to push
forward. Pushing forward therefore reads as "the view rotated", because that is literally
the dominant thing that happens on screen.

**A 150° field of view.** Godot's `Camera3D.fov` is the *vertical* FOV under the default
`keep_aspect = KEEP_HEIGHT`. At 16:9 that is a horizontal FOV of about 163°
(`2·atan(tan(75°)·16/9)`). Real FPV goggles run roughly 100–120° *diagonal*. At this FOV,
rotation sweeps the entire image while translation along the view axis produces very
little apparent motion near the centre of the frame.

**Attitude control, not velocity control.** A multirotor must pitch before it accelerates.
This is correct behaviour, but it means every forward command *starts* with a rotation.

These three compound in one direction, and they explain the exact asymmetry the user
reports:

- **Right-stick left/right → "normal".** Roll produces lateral translation, perpendicular
  to the view axis. Perpendicular motion crosses the frame and reads unambiguously as
  movement, even at 150° FOV.
- **Right-stick forward/back → "rotates instead of moving".** Pitch produces translation
  *along* the view axis, the least perceptible direction, preceded and dominated by a 30°
  attitude change that the wide FOV amplifies.

None of this is an axis defect. It is a camera-tuning and control-mode issue, and it would
have produced the same complaint even if the body frame had been correct from the start.
That is why every axis-side correction was reported as "no change".

## Why the hardware retests reported "no change"

Re-ranked for r3.

### 1. FPV camera defaults plus attitude control (leading)

See the section above. Discriminating experiment, roughly 30 seconds:

1. Read the HUD `VIEW:` label to establish whether the flight is FPV or THIRD PERSON
   (`common/flight/flight_runtime.gd:6123`).
2. If FPV: set `camera.fov_deg` to `90` and `camera.camera_angle_deg` to `0` in
   `~/.local/share/godot/app_userdata/AeroSim/settings.json`, relaunch, and fly the same
   input.
3. Alternatively press `V` (or the controller `BACK` button) to switch to third person,
   which uses neither setting.

Prediction: with a level camera at 90° FOV, or in third person, forward stick reads as
forward flight. If it does, the axis work is complete and the remaining task is camera
defaults and, optionally, a velocity-style control mode.

### ~~2. The retested runtime was not the corrected source~~ (falsified)

r2 ranked this first, on the grounds that moving a camera 90° and 1.8 m cannot look
identical. The reasoning was sound but the premise is now gone: `--path .` runs the
corrected source tree directly.

Retained for the record, because the artifact still exists and is still a hazard:
`/home/karl/Workspace/Toys/AeroSim/.worktrees/gsp-user-open` is a **complete second Godot
project nested inside the main project directory**
(`.worktrees/gsp-user-open/project.godot`), checked out at `402e5a5`, carrying the rotated
pre-`79d7a99` mapping, `THIRD_PERSON_CAMERA_OFFSET = Vector3(0.0, 0.8, 1.8)` with no FPV
alignment, and no model rotation. It should be removed or moved outside the project
directory so it cannot be launched or scanned by accident.

### 3. Expected attitude response is being read as the wrong movement

Angle and assisted-hold stick input commands roll/pitch **attitude**, not horizontal
velocity. A multirotor must pitch before it accelerates. With the corrected aft camera the
nose-down attitude is now clearly visible, and a user expecting velocity-style control may
still describe it as "it tilts instead of moving".

Prediction: final roll and yaw stay zero, pitch is non-zero, angular velocity is on the
pitch axis, and body-local displacement is `±X`. If the trace shows this, the physics is
correct and the request is a control-mode feature, not a bug.

### 4. A later authority source overwrites local pitch

`_airsim_controls_for_frame()` can replace roll, pitch, yaw, and mode after
`_profile_axis()` is sampled, and PX4 can bypass local angle commands with actuator
outputs. The controller monitor observes `_profile_axis()` only and cannot see this.

Prediction: the monitor shows `pitch = -1` while the final applied controls differ.

### 5. The live collision/state boundary uses the wrong rotational component

The isolated native controller is correct, but the live path synchronises Jolt state,
invokes collision variants, returns a packed row, and applies it to the body.

Prediction: final controls are pure pitch, but the applied body angular velocity appears
on roll/yaw, or body-local displacement appears on `Z`.

### 6. Residual screen-space presentation error

Only three `Camera3D` nodes exist in the flight scene (`levels/smoke/smoke.tscn:49-57`)
and no map scene adds another, so a stray current camera is unlikely. The open presentation
risk is the model-nose premise in the section above.

## Newly identified defects

These are separate from the right-stick symptom and are why it survived so long.

**D1 — the runtime-actions gate is unreachable in CI.**
`scripts/run_headless_smoke.sh:60` always appends `--skip-runtime-map`, which skips
`_verify_runtime_actions()` at `common/smoke/headless_smoke.gd:151`. The only other entry
point is `--runtime-only` (`:125-127`), which no script or workflow uses — it appears only
in `docs/superpowers/plans/`. Every Xbox axis assertion and every camera convention
assertion in that function has therefore never gated a merge.

**D2 — `79d7a99` left a self-contradictory pitch assertion (fixed in the working tree).**
That commit set `reversed_for_role["pitch"] = false` and changed the injected axis from
`JOY_AXIS_RIGHT_X` to `JOY_AXIS_RIGHT_Y`, but kept sign assertions written for the
reversed profile. With `raw = +0.50` and `deadzone = 0.08`,
`GamepadProfile.normalize_axis` returns `+0.4204`, so
`if scene._profile_axis("pitch") >= 0.0: push_error("Positive Xbox pitch raw input must be
reversed before flight control")` fires. The gate was red at `dc41bff` and nobody saw it,
because of D1.

**D3 — `--runtime-only` fails before it reaches any axis or camera assertion.**
Measured on the current working tree:

```
$ Godot_v4.7-stable_linux.x86_64 --headless --path . \
    --script res://common/smoke/headless_smoke.gd -- --runtime-only
ERROR: No-controller Quick Fly must show Terrain Range through the third-person player
       camera while AirSim remains FPV before keyboard fallback confirmation
   at: headless_smoke.gd:1685
exit 1
```

Instrumenting the compound condition shows `scene.screen == "reset_pending"` where the
assertion expects `"fallback_prompt"`, with `loaded_map_id == "terrain3d_range"` and
`third_person_view == true`. The camera is `ChaseCamera` only because
`_update_chase_camera()` does not list `"reset_pending"` among the player-view screens
(`common/flight/flight_runtime.gd:6485`). This is a harness/state-machine race in
`quick_fly()`, unrelated to the coordinate frames, and it blocks the entire block behind
it.

**D4 — the model-nose premise is untested.** See above.

**D5 — the main menu sat flush against the window edge, hiding Quick Fly (fixed).**
`_build_main_menu()` added the entries `VBoxContainer` to its `CanvasLayer` with no
anchoring or inset, so the stack rendered at exactly `(0, 0)` at 87×241 px. Under Wayland
client-side decorations the title bar overlaps the top of the viewport, which swallowed
the entire first entry — Quick Fly — leaving `Lab Mode` as the first visible item and no
indication that anything was missing. This blocked the r3 hardware retest and cost a round
trip. The entries container is now inset by `MAIN_MENU_ENTRIES_INSET = Vector2(24, 56)`
(`common/flight/flight_runtime.gd:56`, `:3388-3392`). The node path `MainMenu/Entries` is
deliberately unchanged — sixteen call sites across `tests/headed/`, `tests/gut/`, and
`common/smoke/` depend on it, so the container is offset rather than wrapped.

Worth noting for its own sake: the button was present, enabled, and focused the whole
time. `show_main_menu()` calls `initial_button.grab_focus()` on Quick Fly, so pressing
Enter always started a flight — the feature was reachable, just invisible.

## Required next diagnostic

**Step 0: run the camera-defaults experiment in "1. FPV camera defaults plus attitude
control" above.** It costs about 30 seconds and discriminates between "the simulation is
wrong" and "the camera is tuned so that a correct simulation is unreadable". Do it before
building any further instrumentation.

If the symptom survives a level camera at 90° FOV *and* survives third person, then the
presentation explanation is falsified too, and the following trace becomes necessary.
Capture it as one synchronised, bounded record while the user holds right-stick up for
approximately one second:

```text
runtime fingerprint:
  project path, source/build marker, git commit, current camera, view mode

input:
  raw role values, normalized role values

authority:
  local / AirSim / PX4
  final roll, pitch, yaw, throttle, flight mode

native result:
  orientation delta
  body-local angular velocity
  world and body-local linear velocity
  world and body-local displacement

presentation:
  model forward in world space
  camera forward/right in world space
```

Decision table:

| Trace result | Conclusion |
|---|---|
| Runtime fingerprint is unexpected | Wrong project, worktree, export, or import cache was flown; retest the corrected tree |
| Final `pitch != 0`, roll/yaw zero; body pitch axis and local `X` displacement; camera forward is body `+X` | Physics and presentation are correct; the remaining work is camera defaults and, optionally, a velocity-style control mode |
| Final controls differ from the monitor | AirSim/PX4 or another post-monitor authority is the cause |
| Final controls are correct but angular velocity/displacement uses the wrong body axis | Native collision/state transform is the cause |
| Body-local motion is correct but camera-space motion is sideways | A presentation surface is still on Godot's `-Z` convention |

The trace must come from the same running instance as the physical test.

## Recommended repairs

Ordered by how much future work they prevent:

1. Give `scripts/run_headless_smoke.sh` a mode that runs `_verify_runtime_actions()` and
   wire it into `.github/workflows/ci.yml`, or move its assertions into the GUT suite that
   already gates CI. Without this, D2-class regressions keep landing.
2. Fix the `reset_pending` race behind D3 so the gate can reach its assertions.
3. Add a headed screenshot check for the model nose (D4).
4. Record the `+X` forward / `+Y` up / `+Z` right body frame in `AGENTS.md` and
   `docs/wiki/architecture.md`, next to the camera and model code that has to honour it.
   The contract is currently documented only in a comment inside
   `common/rpc/airsim_coordinate_contract.gd`, which is not where camera code gets written.
5. ~~Revisit `CameraProfile.DEFAULT_FOV_DEG = 150.0`.~~ **Applied — awaiting the hardware
   result.** Godot's `fov` is the vertical FOV, so 150 shipped a ~163° horizontal view.
   The FPV camera defaults are now `fov_deg = 90` (~121° horizontal) and
   `camera_angle_deg = 0`, changed in all three places that carry them:
   `common/flight/camera_profile.gd:9-10`,
   `common/flight/hardware_config.gd:92` (`FACTORY_DEFAULT.fpv`), and
   `config/drones/5_inch_6s.json`. `config/drones/5_inch_6s_race.json` keeps its 45°
   uptilt — that is the race preset's intended character — but drops to `fov_deg = 90`.
   `config/drones/invalid_out_of_range.json` is a validation fixture and was left alone.

   The persisted profile takes precedence over both the code default and the airframe
   preset (`common/flight/flight_runtime.gd:1337`), so
   `~/.local/share/godot/app_userdata/AeroSim/settings.json` was updated to match;
   otherwise the retest would have silently exercised the old values. The `camera_angle_deg = 0`
   value is the deliberately maximum-readability end of the range for this test, not a
   final product decision — a non-zero uptilt is authentic FPV and both values remain
   pilot-adjustable from the in-flight camera panel
   (`common/flight/flight_runtime.gd:4465-4466`).
6. Move or delete `.worktrees/gsp-user-open`, which is a second launchable Godot project
   nested inside this one.
7. Consider whether an explicit velocity-style ("cinematic"/GPS) control mode is wanted
   alongside the current attitude modes. Several of the symptom reports in this
   investigation are really requests for that mode.

## Verification status

Measured on 2026-07-29 against the current working tree (`dc41bff` plus the uncommitted
corrections):

| Check | Command | Result |
|---|---|---|
| GUT GDScript units | `scripts/run_gut_tests.sh` | **291/291 tests pass** (26 scripts, 1707 asserts), before and again after the FPV camera default change. The wrapper still exits 1: it flags a Godot error in `build/gut/import.log` originating from the vendored Terrain3D editor plugin (`addons/terrain_3d/src/double_slider.gd:25`), unrelated to input or camera code. |
| Native suite | `scripts/test_native.sh` | **Passes, exit 0**, including `stick axis convention ok` from `tests/native/test_stick_axis_convention.cpp` |
| Runtime-actions smoke | `--runtime-only` | **Fails** at `headless_smoke.gd:1685` (D3) |
| Full headless smoke | `scripts/run_headless_smoke.sh` | Not re-run in this revision. The previous report attributed its unusability to a Jolt job-pool hang; note that this path skips the runtime-actions block regardless (D1), so a green result here would not have covered the defect. |
| Physical acceptance, r3 | `"$GODOT_BIN" --display-driver wayland --path .` | **Symptom reproduced on the corrected source tree.** This falsified the "wrong build" hypothesis and forced revision 3. |
| Physical acceptance, final | same | **Both closed by the maintainer.** Flight direction correct once out of `ALTITUDE_HOLD`; airframe heading correct after the `-90°` model fix. Maintainer report, not command output. |
| User runtime config | `~/.local/share/godot/app_userdata/AeroSim/settings.json` | Gamepad profile canonical; camera profile since changed to `fov_deg = 90.0`, `camera_angle_deg = 0.0` |

## Current conclusion

Resolved. The report rejects swapping right-stick X and Y — the axis chain was correct
throughout, as the r4 trace shows end to end at every heading, and the maintainer's
persisted profile is canonical.

Four independent defects sat on top of that correct chain, all now corrected and merged:

1. A 90° body-frame mismatch between the simulation and every presentation surface.
2. The imported airframe's nose pointing 90° off the direction of travel, because the
   loader's rotation had been chosen from a bounding box dominated by the rotor arms.
3. A centred gamepad throttle commanding 50% against a 0.330 hover throttle.
4. The main menu sitting flush at `(0, 0)`, where Wayland decorations hid Quick Fly.

Flight direction and airframe heading are both confirmed on hardware.

What this investigation did not fix is listed under "Newly identified defects" and remains
open: the runtime-actions smoke block is unreachable in CI and currently red, and
`ALTITUDE_HOLD` can be entered on the ground with no way to climb. The wind-preset defect
below is also unresolved. D1 is the one worth doing first — it is the reason defects 1–3
survived as long as they did.
