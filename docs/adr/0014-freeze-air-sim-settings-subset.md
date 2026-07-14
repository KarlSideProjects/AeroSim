# Freeze the first AirSim settings subset

The first AirSim `settings.json` subset will accept `SettingsVersion`, multirotor-only `SimMode`, RPC and simulation-clock fields, `OriginGeopoint`, at most two named `Vehicles` with per-vehicle `Cameras` and `Sensors`, `SubWindows`, and `Recording`. `VehicleType` is limited to the standard `SimpleFlight` and `PX4Multirotor` identifiers; unsupported root fields, nested fields, modes, and vehicle types must produce explicit startup diagnostics rather than being silently ignored.
