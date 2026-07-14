# AirSim reference audit for #141

AirSim reference: `v1.8.1` at `96235148a332fe7cb3d3525a0720e26faaca99e0` in the read-only sibling checkout.

## Paths and symbols

- `AirLib/include/api/RpcLibClientBase.hpp`: `getImuData`, `getBarometerData`, `getMagnetometerData`, `getGpsData`, and `getLidarData` RPC method names and positional arguments.
- `AirLib/src/api/RpcLibServerBase.cpp`: server-side method names and MessagePack dispatch surface.
- `PythonClient/airsim/client.py`: `VehicleClient.getImuData`, `getBarometerData`, `getMagnetometerData`, `getGpsData`, and `getLidarData` client wrappers.
- `PythonClient/airsim/types.py`: `ImuData`, `BarometerData`, `MagnetometerData`, `GpsData`, `LidarData`, `GeoPoint`, `Vector3r`, and `Quaternionr` field names.
- `AirLib/include/sensors/SensorBase.hpp`: baseline sensor type IDs: barometer `1`, IMU `2`, GPS `3`, magnetometer `4`, and LiDAR `6`.
- `AirLib/include/sensors/gps/GpsSimpleParams.hpp`, `barometer/BarometerSimpleParams.hpp`, `magnetometer/MagnetometerSimpleParams.hpp`, and `lidar/LidarSimpleParams.hpp`: reference update rates, latency, and startup-delay settings.
- `AirLib/include/common/CommonStructs.hpp`: GPS, barometer, magnetometer, IMU, and LiDAR payload members.

AeroSim implements the frozen public payloads in `common/rpc/airsim_sensor_suite.gd`, dispatches them through `common/rpc/airsim_rpc_server.gd`, and uses `AirSimSession.simulation_time_seconds` as the only sampling clock. Native IMU and barometer samples cross the boundary through `AeroSimNative.imu_sample()` and retain the existing deterministic native simulator configuration. Drop counters are additive AeroSim metadata on the returned map; pinned AirSim client types ignore unknown map members.

## Issue searches and disposition

The following searches were run against all Microsoft AirSim issues with `gh issue list --repo microsoft/AirSim --state all --search` and the relevant issue summaries/comments were reviewed:

| Query | Relevant issue | Disposition |
|---|---|---|
| `getImuData` / `IMU timestamp units` | [#3116](https://github.com/microsoft/AirSim/issues/3116), [#4133](https://github.com/microsoft/AirSim/issues/4133), [#4303](https://github.com/microsoft/AirSim/issues/4303) | Preserve the pinned field names, SI units, and simulation-time nanosecond timestamps. Do not use wall-clock or render timestamps. |
| `getGpsData` / `GPS timestamp` | [#3116](https://github.com/microsoft/AirSim/issues/3116), [#2833](https://github.com/microsoft/AirSim/issues/2833), [#2078](https://github.com/microsoft/AirSim/issues/2078) | Keep GPS timestamps on the shared deterministic clock and expose explicit `is_valid`, `fix_type`, geodetic position, and velocity fields. |
| `getMagnetometerData` / `magnetometer declination` | [#4362](https://github.com/microsoft/AirSim/issues/4362), [#3160](https://github.com/microsoft/AirSim/issues/3160), [#3599](https://github.com/microsoft/AirSim/issues/3599) | Provide a deterministic body-frame field and covariance shape; do not claim map-specific ground-truth declination or silently import an upstream offset assumption. |
| `getBarometerData` | [#4793](https://github.com/microsoft/AirSim/issues/4793), [#3599](https://github.com/microsoft/AirSim/issues/3599) | Preserve altitude, pressure, and QNH semantics in SI-compatible units while retaining AeroSim's existing native barometer/noise path. |
| `getLidarData` / `LidarData point_cloud` | [#3188](https://github.com/microsoft/AirSim/issues/3188), [#3338](https://github.com/microsoft/AirSim/issues/3338), [#3758](https://github.com/microsoft/AirSim/issues/3758), [#2907](https://github.com/microsoft/AirSim/issues/2907), [#4418](https://github.com/microsoft/AirSim/issues/4418), [#3174](https://github.com/microsoft/AirSim/issues/3174) | Preserve the pinned flat XYZ point-cloud and segmentation arrays. Detailed mesh, RGB, and computer-vision-only behavior remain outside this slice and are not advertised. |
| `sensor frequency` | [#3599](https://github.com/microsoft/AirSim/issues/3599), [#4793](https://github.com/microsoft/AirSim/issues/4793) | Validate rates and non-negative timing settings; count skipped scheduled samples and expose `sample_count`/`dropped_count` for deterministic gap/drop verification. |

The upstream reports include known inconsistencies and feature requests. AeroSim preserves only the pinned client-visible shape, makes timing deterministic, and fails unsupported names, types, and rates explicitly.

## License and attribution

No AirSim source code was copied or adapted. The implementation uses the MIT-licensed repository as a compatibility reference for names, wire signatures, type IDs, and observable field contracts; the checkout is not a runtime or build dependency.

## AeroSim tests derived from the audit

- `tests/gut/test_airsim_sensor_suite.gd` verifies all five baseline types, simulation-time frequency, pause stability, GPS origin, native barometer altitude, invalid configuration, disabled sensors, drop metadata, and LiDAR payload shape.
- `tests/gut/test_airsim_rpc_server.gd` verifies all five pinned RPC method names, argument validation, and exact sensor-result dispatch.
- `tests/gut/test_msgpack_codec.gd` verifies LiDAR point arrays use MessagePack float32 values (`0xca`) rather than float64 values (`0xcb`).
- `scripts/airsim_rpc_client_smoke.py` retrieves every baseline payload through the unmodified AirSim 1.8.1 client and checks timestamps, nested GPS, covariance, pressure/QNH, and LiDAR array alignment.
- `scripts/test_native.sh` keeps the existing native IMU, noise, bias, delay, and deterministic replay tests green while exposing the latest native IMU sample to the Godot boundary.
