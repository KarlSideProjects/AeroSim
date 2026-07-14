# AirSim reference audit for #140

AirSim reference: `v1.8.1` at `96235148a332fe7cb3d3525a0720e26faaca99e0` in the read-only sibling checkout.

## Paths and symbols

- `PythonClient/airsim/client.py`: `VehicleClient.enableApiControl`, `isApiControlEnabled`, `armDisarm`, `getHomeGeoPoint`, `simGetVehiclePose`, `simGetCollisionInfo`, `cancelLastTask`; `MultirotorClient.takeoffAsync`, `landAsync`, `goHomeAsync`, `hoverAsync`, `moveToPositionAsync`, `moveOnPathAsync`, `moveByVelocityAsync`, `moveByVelocityZAsync`, `moveByVelocityBodyFrameAsync`, `moveByVelocityZBodyFrameAsync`, `rotateToYawAsync`, `rotateByYawRateAsync`, `moveByAngleRatesThrottleAsync`, and `getMultirotorState`.
- `PythonClient/airsim/types.py`: `Vector3r`, `Quaternionr`, `YawMode`, `KinematicsState`, `MultirotorState`, `CollisionInfo`, and `GeoPoint` MessagePack field names.
- `AirLib/include/vehicles/multirotor/api/MultirotorCommon.hpp`: `YawMode`, `LandedState`, and `MultirotorState` fields.
- `AirLib/include/vehicles/multirotor/api/MultirotorRpcLibClient.hpp`: positional RPC signatures and asynchronous task entry points.
- `docs/apis.md`: NED world axes, SI units, body-frame angular quantities, and the `getMultirotorState` payload contract.

The native runtime's `y_up_to_frd`/`frd_to_y_up` basis in
`src/native/aerosim_simulation.cpp` is the single implementation reference for
the public conversion: `(x, y, z) -> (x, z, -y)`. The RPC adapter reuses that
basis through `common/rpc/airsim_coordinate_contract.gd`; it does not maintain
a second simulation or coordinate authority. Runtime state is sourced from
`FlightRuntime`, `DroneBody`, and the native controller. This slice exposes one
physical vehicle; configured multi-vehicle RPC startup is rejected explicitly.

## Issue searches and disposition

The following searches were run against all Microsoft AirSim issues with `gh issue list --state all --search`:

| Query | Relevant issue | Disposition |
|---|---|---|
| `NED coordinate` | [#3577](https://github.com/microsoft/AirSim/issues/3577), [#4303](https://github.com/microsoft/AirSim/issues/4303), [#2027](https://github.com/microsoft/AirSim/issues/2027) | Keep NED/SI public payloads, reject non-finite vectors, and keep same-position behavior deterministic rather than copying an upstream assumption. |
| `getMultirotorState` | [#4134](https://github.com/microsoft/AirSim/issues/4134), [#2914](https://github.com/microsoft/AirSim/issues/2914), [#1776](https://github.com/microsoft/AirSim/issues/1776) | Treat state payload shape and landed-state values as compatibility requirements; estimator timing and convergence are not silently inferred from a single query. |
| `SteppableClock` | [#600](https://github.com/microsoft/AirSim/issues/600) | Complete async responses only after AeroSim session frames; paused time does not advance tasks. Task timeout/cancel resolves the AirSim future with `false`; a successful command resolves with `true`. |
| `takeoffAsync` | [#1776](https://github.com/microsoft/AirSim/issues/1776), [#2852](https://github.com/microsoft/AirSim/issues/2852) | Preserve explicit preconditions and deterministic completion/error behavior. |
| `moveByMotorPWMs` | [#3089](https://github.com/microsoft/AirSim/issues/3089) | Direct PWM remains explicitly unsupported at AeroSim's flight-controller boundary. |

The issue results include known upstream inconsistencies and open reports. AeroSim does not copy those behaviors as hidden assumptions; its public contract is the checked-in NED/FRD/SI conversion and explicit unsupported/error policy.

## License and attribution

No AirSim source code was copied or adapted. The implementation uses the repository's MIT-compatible reference for names, wire signatures, and observable field contracts; no runtime or build dependency on the checkout is introduced.

## AeroSim tests derived from the audit

- `tests/gut/test_airsim_coordinate_contract.gd` fixes world/body vector, orientation, angular-rate, acceleration, force, and yaw round-trips.
- `tests/gut/test_airsim_rpc_server.gd` exercises API-control and arm preconditions, NED payload fields, all implemented command families, paused-frame async completion, timeout, cancellation, reset, and explicit per-motor PWM rejection.
- `scripts/airsim_rpc_client_smoke.py` exercises the same surface through the unmodified `airsim==1.8.1` client.

`simGetLandedState` is intentionally not advertised: AirSim 1.8.1 exposes
`landed_state` as part of `MultirotorState`, not as a separate pinned RPC
method.
