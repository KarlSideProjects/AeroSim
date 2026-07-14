# AirSim camera surface audit

Issue #142 implements the frozen `simGetImages` subset against Microsoft AirSim
v1.8.1 at commit `96235148a332fe7cb3d3525a0720e26faaca99e0`.

## Reference paths and symbols

- `AirLib/src/api/RpcLibServerBase.cpp`: `RpcLibServerBase::initialize` binds
  `simGetImages` with an `ImageRequest` vector, `vehicle_name`, and `external`.
- `AirLib/src/api/RpcLibClientBase.cpp`: `RpcLibClientBase::simGetImages`
  preserves the response vector order.
- `AirLib/include/api/RpcLibAdaptorsBase.hpp`: `ImageRequest` fields are
  `camera_name`, `image_type`, `pixels_as_float`, and `compress`; the response
  carries byte/float image data, camera pose, timestamp, dimensions, and type.
- `PythonClient/airsim/types.py`: `ImageType.Scene = 0`, `DepthPlanar = 1`,
  and `Segmentation = 5`; `ImageRequest` defaults to compressed byte images and
  `ImageResponse` exposes the binary and float arrays separately.
- `PythonClient/airsim/client.py`: `simGetImages` calls the three-argument RPC
  and maps each response through `ImageResponse.from_msgpack`.

## Issue searches and decisions

Queries were run against both open and closed Microsoft AirSim issues:

- `simGetImages`: [open/closed result set](https://github.com/microsoft/AirSim/issues?q=is%3Aissue+simGetImages)
- `DepthPlanar pixels_as_float`: [result set](https://github.com/microsoft/AirSim/issues?q=is%3Aissue+DepthPlanar+pixels_as_float)
- `segmentation image orientation`: [result set](https://github.com/microsoft/AirSim/issues?q=is%3Aissue+segmentation+image+orientation)
- `camera pose timestamp`: [result set](https://github.com/microsoft/AirSim/issues?q=is%3Aissue+camera+pose+timestamp)

Relevant findings:

- [#800](https://github.com/microsoft/AirSim/issues/800) reports that stereo
  requests need one synchronized simulation tick. AeroSim captures one session
  timestamp and pose for every response in a request batch, and tests preserve
  request order and shared timestamps.
- [#1309](https://github.com/microsoft/AirSim/issues/1309) reports image/pose
  synchronization problems. AeroSim derives both from the same camera transform
  and simulation clock snapshot rather than sampling them independently.
- [#1724](https://github.com/microsoft/AirSim/issues/1724) documents unreliable
  segmentation/depth output in AirSim NoDisplay mode. AeroSim uses a Godot
  render target for Scene and Godot physics rays for depth/segmentation, so the
  supported ground-truth types remain deterministic in headed and headless
  checks; unsupported types fail explicitly.
- [#3423](https://github.com/microsoft/AirSim/issues/3423) shows that AirSim's
  segmentation RGB palette has varied across engine versions. AeroSim therefore
  freezes an explicit little-endian 24-bit ID encoding and stores the stable IDs
  in `config/maps/industrial_yard.json` and matching scene metadata, rather than
  importing a version-sensitive palette.
- [#5014](https://github.com/microsoft/AirSim/issues/5014) records resolution
  behavior around the 256x144 default. AeroSim uses that pinned default and
  honors per-camera/per-image `CaptureSettings` dimensions.

The frozen compatibility choice is to support Scene, DepthPlanar, and
Segmentation only. DepthPlanar requires `pixels_as_float=true`; Scene and
Segmentation return PNG bytes when compressed and 3-channel RGB bytes when
uncompressed, with the pinned vertical orientation.
DepthVis, perspective depth, disparity, normals, infrared, optical flow, and
external cameras are unsupported and produce actionable RPC errors.

## License and tests

The AirSim reference is MIT licensed. AeroSim adapts the observable RPC field
and image-type contract only; no AirSim source, Unreal asset, or runtime
dependency is copied. Tests derived from the audit cover binary MessagePack,
request ordering, dimensions, raw/PNG/float encodings, shared timestamps,
stable segmentation catalog IDs, pause repeatability, unsupported types, and
the Industrial Yard headed/headless camera harnesses. The segmentation catalog
is limited to scene objects with matching collision proxies so geometry and IDs
cannot drift between render and ground-truth paths.
