# ANGLE Demo Flight Design

## Goal

Run the Terrain Range Demo Flight through actual native ANGLE stick controls. The game remains in third-person Quick Fly view, with the original HUD showing materially changing left and right sticks. The demo must not directly overwrite drone position, rotation, or velocity.

## Scope

`FlightRuntime` receives a demo-only closed-loop controller. Each physics frame it converts the route target, native position, native velocity, and heading error into bounded `throttle`, `roll`, `pitch`, and `yaw_rate` values. The existing native `step_angle_mode` advances the authoritative flight state and the usual state publication renders that result.

The Demo Flight bypasses the collision stepping path after one initial native/body synchronization. This avoids feeding Godot rigid-body state back into the native simulator every frame. Manual Quick Fly, normal collisions, and all non-demo modes continue using their current paths.

## Control and Safety

- Keep `flight_mode` as `ANGLE`.
- Bound roll and pitch to a demo-specific safe limit below the normal ANGLE maximum; map those values directly to the right-stick HUD.
- Use heading error for yaw rate and target-height/vertical-velocity feedback around the configured hover throttle for the left stick.
- Detect excessive altitude, speed, or target divergence; disarm, stop the demo, and return to the existing safe exit flow instead of continuing an unsafe recording.
- The existing route remains approximately 60 seconds and retains its low pass, orbit, climb, return, and land phases.

## Verification

- Unit coverage proves the route produces non-neutral left and right stick values in distinct phases.
- Native integration coverage proves that after the initial hover, the drone has nonzero physical velocity, moves horizontally, stays within the low-pass height bound, and is not being pose-overridden.
- Existing demo, GSP, Quick Fly camera, and hardcoded-airframe checks continue to pass.
- X11 visual verification confirms the 3:2 game/GSP split, `MODE: ANGLE`, a Quick Fly-sized drone, and visibly different stick positions during multiple route phases.
