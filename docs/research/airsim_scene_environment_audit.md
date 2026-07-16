# AirSim scene and environment audit for #144

Reference checkout: `../AirSim-reference`, tag `v1.8.1`, commit
`96235148a332fe7cb3d3525a0720e26faaca99e0`. AirSim is MIT licensed.

## Sources and disposition

The pinned source binds the object lifecycle methods in
[`AirLib/src/api/RpcLibServerBase.cpp`](https://github.com/microsoft/AirSim/blob/96235148a332fe7cb3d3525a0720e26faaca99e0/AirLib/src/api/RpcLibServerBase.cpp#L364-L400):
`simSpawnObject`, `simDestroyObject`, `simGetObjectPose`, and
`simSetObjectPose`. Client signatures are in
[`AirLib/include/api/RpcLibClientBase.hpp`](https://github.com/microsoft/AirSim/blob/96235148a332fe7cb3d3525a0720e26faaca99e0/AirLib/include/api/RpcLibClientBase.hpp#L56-L70).
The same server binds weather and time-of-day in
[`AirLib/src/api/RpcLibServerBase.cpp`](https://github.com/microsoft/AirSim/blob/96235148a332fe7cb3d3525a0720e26faaca99e0/AirLib/src/api/RpcLibServerBase.cpp#L119-L128),
with the weather enum in
[`AirLib/include/api/WorldSimApiBase.hpp`](https://github.com/microsoft/AirSim/blob/96235148a332fe7cb3d3525a0720e26faaca99e0/AirLib/include/api/WorldSimApiBase.hpp#L18-L29).

AirSim implementation behavior was checked at:

- [`Unreal/Plugins/AirSim/Source/WorldSimApi.cpp`](https://github.com/microsoft/AirSim/blob/96235148a332fe7cb3d3525a0720e26faaca99e0/Unreal/Plugins/AirSim/Source/WorldSimApi.cpp#L62-L147): arbitrary Unreal asset lookup, mutable actor requirements, and name handling are not safe as AeroSim input contracts.
- [`WorldSimApi.cpp`](https://github.com/microsoft/AirSim/blob/96235148a332fe7cb3d3525a0720e26faaca99e0/Unreal/Plugins/AirSim/Source/WorldSimApi.cpp#L305-L397): segmentation and pose behavior; AeroSim uses exact catalog metadata and explicit errors instead of regex scans or NaN missing poses.
- [`WorldSimApi.cpp`](https://github.com/microsoft/AirSim/blob/96235148a332fe7cb3d3525a0720e26faaca99e0/Unreal/Plugins/AirSim/Source/WorldSimApi.cpp#L416-L433) and [`WeatherLib.cpp`](https://github.com/microsoft/AirSim/blob/96235148a332fe7cb3d3525a0720e26faaca99e0/Unreal/Plugins/AirSim/Source/Weather/WeatherLib.cpp#L72-L163): rain/fog are visual controls; wind remains the physics-relevant control.
- [`SimModeBase.cpp`](https://github.com/microsoft/AirSim/blob/96235148a332fe7cb3d3525a0720e26faaca99e0/Unreal/Plugins/AirSim/Source/SimMode/SimModeBase.cpp#L242-L282): time-of-day uses explicit settings; AeroSim does not fall back to host wall-clock time.

Upstream findings considered: [PR #2651](https://github.com/microsoft/AirSim/pull/2651),
[issue #1265](https://github.com/microsoft/AirSim/issues/1265),
[issue #2695](https://github.com/microsoft/AirSim/issues/2695),
[issue #2901](https://github.com/microsoft/AirSim/issues/2901),
[issue #675](https://github.com/microsoft/AirSim/issues/675),
[issue #2003](https://github.com/microsoft/AirSim/issues/2003),
[issue #4483](https://github.com/microsoft/AirSim/issues/4483),
[issue #3103](https://github.com/microsoft/AirSim/issues/3103), and
[issue #4069](https://github.com/microsoft/AirSim/issues/4069).
They reinforce explicit movable/catalog ownership, creation-time segmentation,
complete reset, and wind-only physics coupling.

## AeroSim decision

The implementation adopts AirSim method names and MessagePack shapes but does
not copy AirSim source or add an AirSim runtime/build dependency. `simSpawnObject`
accepts only checked-in IDs from `config/scene_object_catalog.json`; duplicate
names, arbitrary paths, non-unit scale, unknown objects, static/manager ownership,
and regex segmentation requests fail explicitly. The catalog creates a
`StaticBody3D` collision proxy and applies stable `airsim_segmentation_id` metadata
to the body and mesh. Poses cross the existing NED/SI coordinate contract.

Rain and fog are bounded state (`0..1`), wind is routed to the existing native
wind configuration, and time-of-day settings remain deterministic session state.
`reset` restores catalog lifecycle and environment state before restoring the
selected map wind baseline. Replay/dataset consumers have mutation signals and
can subscribe to the same `EnvironmentState` and catalog callbacks used by RPC
and the status diagram; full recording/replay reconstruction remains out of
scope for this slice. `simSetEnvironment` and `simGetEnvironment` are explicitly
listed as AeroSim Lab extensions, not as pinned AirSim compatibility methods.

## Verification derived from the audit

- GUT covers schema rejection, deterministic lifecycle, collision construction,
  segmentation metadata, NED pose shape, bounded weather, unsupported weather,
  and regex rejection.
- Headless smoke covers runtime construction, map loading/reset, native wind
  preservation, and the catalog/environment initialization path.
- `config/airsim_compatibility_manifest.json` lists supported object and
  environment methods; unsupported inputs fail explicitly.
