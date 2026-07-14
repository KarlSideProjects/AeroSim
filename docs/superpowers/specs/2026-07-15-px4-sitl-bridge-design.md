# PX4 SITL bridge design

## Decision

Use one small Godot-native bridge with two transport endpoints: a TCP simulator
channel for HIL sensor/time messages and a UDP control channel for PX4
actuator/status messages. The bridge owns connection state and diagnostics but
does not own simulation time or physics. `AirSimSession` supplies timestamps,
`FlightRuntime` supplies the vehicle snapshot, and the existing native
per-motor integrator consumes PX4 actuator outputs.

The bridge has a deterministic fake transport for GUT/headless tests and a real
`PacketPeerStream`/`PacketPeerUDP` transport for Ubuntu PX4 SITL. A checked-in
launcher pins the PX4 source revision and starts `none_iris`; environments
without PX4 fail explicitly instead of silently falling back to SimpleFlight.

## State and failure semantics

States are `starting`, `connected`, `armed`, `failed`, `disconnected`, and
`stale`. A heartbeat and actuator heartbeat timeout move the bridge to
`stale`/`failed`; `FlightRuntime` pauses and removes PX4 authority on failure.
Reconnect is explicit and never changes the configured vehicle type. Arm,
takeoff, waypoint, hover, land, and disarm use the existing AirSim command
surface and shared NED/FRD conversion.

## Verification

Tests cover settings validation, state transitions, timeout/fail-loud behavior,
NED/FRD fixture reuse, deterministic fake-PX4 mission completion, and the
launcher’s pinned revision/clean-environment checks. The real launcher remains
an Ubuntu qualification gate and is not required for fast unit tests.
