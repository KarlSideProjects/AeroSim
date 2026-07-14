# Freeze the external coordinate contract

All public APIs, the PX4 bridge, Flight Replay, and Dataset Recording will use NED world axes, FRD vehicle-body axes, and SI units. Godot's Y-up representation remains internal and crosses one tested conversion boundary; exposing engine coordinates would make AirSim compatibility, PX4 integration, and recorded data ambiguous.
