---
title: AeroSim 能力與狀態
aliases:
  - AeroSim capability status
status: maintained
sources:
  - docs/product_capabilities.md
  - PRD_AeroSim.md
  - config/airsim_compatibility_manifest.json
last_verified: 2026-07-26
---

# AeroSim 能力與狀態

能力狀態沿用 Product Capabilities：**Available** 表示目前分支有直接測試證據，
**Foundation** 表示部分行為已存在，**Confirmed target** 表示已確認但尚未完成的產品合約。
本頁不會把目標或 issue 討論表述成已可用功能。

## 主要能力地圖

| 範圍 | 能力 | 狀態 | 白話說明 |
| --- | --- | --- | --- |
| 產品入口 | CAP-001 Simulation Platform | Foundation | Player Mode 已有基本飛行入口；Lab Mode 尚未成為完整產品入口。 |
| 玩家飛行 | CAP-002 Player Mode flight loop | Foundation | Quick Fly、暫停、重設、兩個 spawn 與 Angle／Acro／Altitude Hold 已有證據；完整可玩迴圈未完成。 |
| 導航與地圖 | CAP-004 Map Catalog、CAP-005 primary navigation | Foundation | 一張 Industrial Test Range 與部分主選單路徑存在；七入口與完整可用性仍是目標。 |
| 可玩基準 | CAP-006 Playable Game Milestone | Confirmed target | 第一個從冷啟動到完成 Time Trial 的正式 Player Mode 驗收。 |
| 原生飛行 | CAP-012 deterministic multirotor flight core | Foundation | C++ 提供飛行、控制、IMU、空氣動力、碰撞交接與 replay 的測試核心。 |
| 多機 | CAP-013 two named vehicles | Confirmed target | Lab Mode 承諾兩台互相隔離的具名多旋翼，不承諾任意 fleet scale。 |
| 感測器 | CAP-020 Baseline Sensor Suite | Foundation | 原生 IMU 與部分非相機 sensor retrieval 有證據；完整 RGB、depth、segmentation 產品表面仍未完成。 |
| Dashboard | CAP-021 Operations Dashboard | Foundation | 目前是 basic debug panel，不是完整 Player/Lab dashboard。 |
| 世界 | CAP-030 Industrial Test Range | Confirmed target | 場景與 spawn、route landmark、collision geometry 已存在；正式視覺驗收未完成。 |
| 視覺 | CAP-031 asset pipeline、CAP-032 AI visual verification | Confirmed target | 目標是可重建場景、固定視圖與結構化 AI visual evidence。 |
| 重播與資料 | CAP-040 Flight Replay、CAP-041 Dataset Recording | Foundation / Confirmed target | 原生 replay 可重現部分 Angle Mode trajectory；完整 product session 與 dataset contract 尚未完整交付。 |

## 相容性與對外行為

| 能力 | 狀態 | 不可誤解的邊界 |
| --- | --- | --- |
| CAP-010 AirSim Compatibility Surface | Confirmed target | 只支援 release-frozen manifest 列出的 AirSim 1.8.1 client operations 與 settings fields。 |
| CAP-011 PX4 SITL | Confirmed target | PX4 SITL 是支援目標；ArduPilot SITL、hardware-in-the-loop 不在第一個 minimum。 |
| CAP-014 External Coordinate Contract | Confirmed target | 對外永遠是 NED／FRD／SI；不可把 Godot Y-up payload 當 public contract。 |
| CAP-015 RPC Access Boundary | Confirmed target | 只綁 loopback；LAN 與 Internet binding 尚未設計 authentication／transport security。 |
| CAP-016 Flight Command Surface | Confirmed target | 預定支援具名 vehicle 的 takeoff、land、hover、position、path、velocity、yaw 與 attitude/body-rate；direct motor PWM 不在範圍。 |

詳細 acceptance 和 current evidence 必須回到
[Product Capabilities](../product_capabilities.md)。狀態不是完成百分比，也不是 issue priority。
