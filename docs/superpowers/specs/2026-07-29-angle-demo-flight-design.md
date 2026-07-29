# ANGLE Demo Flight Design

## Goal

Run the Terrain Range Demo Flight through actual native ANGLE stick controls. The game remains in third-person Quick Fly view, with the original HUD showing materially changing left and right sticks. The demo must not directly overwrite drone position, rotation, or velocity.

## Scope

`FlightRuntime` receives a demo-only closed-loop controller. Each physics frame it converts the route target, native position, native velocity, and heading error into bounded `throttle`, `roll`, `pitch`, and `yaw_rate` values. The existing `step_collision_angle_mode` remains the native step and publication contract, so normal FlightCore/Jolt collision authority handoff continues to work.

The Demo Flight synchronizes Godot body state into native once after the reset/arm commit. Native FlightCore then remains authoritative on normal frames; body-to-native synchronization resumes only when the existing Jolt collision handoff owns a resolved state. Manual Quick Fly and all non-demo modes retain their current paths.

## Control and Safety

- Keep `flight_mode` as `ANGLE`.
- Bound roll and pitch to a demo-specific safe limit below the normal ANGLE maximum; map those values directly to the right-stick HUD.
- Rotate horizontal velocity error into the drone yaw/body frame before mapping it to roll and pitch. Use heading error for yaw rate and target-height/vertical-velocity feedback around the configured hover throttle for the left stick.
- Detect excessive altitude, speed, or target divergence; disarm, stop the demo, and return to the existing safe exit flow instead of continuing an unsafe recording.
- Start the approximately 60-second route only after reset/arm commit, advance it from simulation delta, and retain its low pass, orbit, climb, return, and land phases.

## Verification

- Unit coverage proves the route produces non-neutral left and right stick values in distinct phases, and that HUD normalization mirrors the exact native step arguments.
- Native integration coverage proves that after the initial hover, the drone has nonzero physical velocity, moves horizontally, stays within the low-pass height bound, follows native ANGLE mode, has non-level travel attitude, and is not being pose-overridden.
- Collision coverage proves Demo Flight retains the existing FlightCore/Jolt authority handoff.
- Existing demo, GSP, Quick Fly camera, and hardcoded-airframe checks continue to pass.
- X11 visual verification confirms the 3:2 game/GSP split, `MODE: ANGLE`, a Quick Fly-sized drone, and visibly different stick positions during multiple route phases.
