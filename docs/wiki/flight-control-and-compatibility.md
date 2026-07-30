---
title: AeroSim 飛控與相容性
aliases:
  - AeroSim flight control compatibility
status: maintained
sources:
  - docs/product_capabilities.md
  - config/airsim_compatibility_manifest.json
  - docs/adr/0002-air-sim-client-compatibility-surface.md
  - docs/adr/0003-px4-sitl-in-minimum.md
  - docs/adr/0011-freeze-external-coordinate-contract.md
  - common/rpc/airsim_settings.gd
  - common/rpc/airsim_rpc_server.gd
  - config/sitl/px4_iris_wind_qualification.json
  - config/drones/px4_iris.json
last_verified: 2026-07-31
---

# AeroSim 飛控與相容性

飛控與外部整合的說明必須明確區分內建 flight controller、PX4 SITL 與版本化的
AirSim Compatibility Surface。AeroSim 不宣稱完整 AirSim 相容性；未列入已發佈 subset
的操作與設定應明確視為 unsupported。

## 三條控制路徑

| 路徑 | 白話說明 | 目前狀態 |
| --- | --- | --- |
| Built-in flight controller | 原生 C++ 控制核心處理 Angle、Acro、Altitude Hold，並連同 aerodynamics、IMU、collision authority handoff 與 replay 一起測試。 | Foundation |
| PX4 SITL | PX4 透過 MAVLink/HIL bridge 傳 actuator output；AeroSim 回傳同一 simulation-time 下的 state 與 sensors。 | Confirmed target |
| AirSim command surface | AirSim client 對具名 Vehicle Instance 發高階飛行命令；server 只接受 manifest 允許的 subset。 | Confirmed target |

Player input 不是 public flight command API；direct per-motor PWM 也不在初版 command surface。

## Built-in controller

- **Angle**：以 attitude 為主的自穩定控制，適合一般 Player Mode 飛行。
- **Acro**：以 body-rate 為主，讓操作者直接控制旋轉速率。
- **Altitude Hold**：在 altitude target 附近維持高度；其 noise/deadband 與機體資料一起設定。

這些 mode 的 deterministic native behavior、collision handoff、telemetry 與 replay 都應由 native
tests 證明；不要把 Godot RigidBody3D contact 視為另一套飛控真相。

## AirSim Compatibility Surface

相容性以 pinned `airsim==1.8.1` client 和 release-frozen manifest 為準。第一個 surface 的
設定與操作目標包含 connection/time control、兩台 multirotor、flight commands/state、Baseline
Sensor Suite、Environment Controls、catalog-managed Scene Objects 與 recording。下列區分是硬邊界：

| 標記 | 意義 |
| --- | --- |
| verified | 已在目前 branch 有直接測試 evidence 的對外行為。 |
| target | 已承諾在 AirSim-class minimum，但尚未可宣稱支援。 |
| unsupported | 未列入 manifest 或明確排除的行為；必須回 explicit error，不能 approximate success。 |

Cars、arbitrary vehicle creation、runtime material replacement、debug plotting，以及未支援的
settings fields 都不是「可能可用」的 fallback。`VehicleType` 初版只容許 built-in `SimpleFlight`
與 PX4 SITL 的 `PX4Multirotor`。

### PX4 HIL 專用 vehicle settings 欄位

manifest 的 `vehicle` 允許欄位新增 `HilGpsIntervalSeconds`、`HilActuatorQuadXOrder` 與
`HardwarePreset`，供 PX4 HIL bridge 指定 GPS 發佈間隔、Quad-X actuator 對應順序與機體
preset 路徑。`airsim_settings.gd` 的 PX4 transport 驗證要求 `HardwarePreset` 指向
`res://config/drones/` 下的 preset、`HilGpsIntervalSeconds` 為有限且非負、
`HilActuatorQuadXOrder` 恰好列出四個相異 motor 名稱。這些是 AeroSim 對 PX4 SITL 的擴充
欄位，不代表上游 `airsim==1.8.1` 有相同設定。

### MultirotorState 的回傳邊界

`getMultirotorState` 只回傳 AirSim public MultirotorState schema 的欄位。內部 PX4 HIL bridge
需要的 `magnetometer` 與 `barometer` 樣本會在回應前移除，不會外洩成相容表面的一部分；
需要這些量測時走 Baseline Sensor Suite 的 sensor API，而不是 vehicle state。

## 座標與網路邊界

- 所有 public positions、velocities、orientations、angular rates 與 forces 使用 **NED world**、
  **FRD body**、**SI units**。
- Godot Y-up 到 NED／FRD 的轉換只應發生在 shared tested boundary；不要在 RPC、PX4、replay
  或 dataset 各自翻一次軸。
- RPC 只可 bind `127.0.0.1:41451`（port 可設定）。wildcard、LAN 與 public bind 都應拒絕，
  直到 authentication 與 transport security 有設計。

## PX4 SITL 的定位

PX4 SITL 的成功標準不是「能連上」，而是 pinned PX4 能 arm、take off、完成 deterministic
mission、land，並提供可操作的 connection state。ArduPilot SITL 與 hardware-in-the-loop 是
第一個 AirSim-class minimum 的 out of scope。

目前 repository 已有 `config/sitl/px4_iris_wind_qualification.json` 這組 PX4 風場
qualification settings，以及 `config/drones/px4_iris.json` 的 allocation preset（其
`allocation_source` 記錄取自 PX4 ROMFS `10016_none_iris`）。CAP-011 的狀態仍是 target，
不因為單一 qualification 場景而變成 verified。
