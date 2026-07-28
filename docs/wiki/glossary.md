---
title: AeroSim 術語表
aliases:
  - AeroSim glossary
status: maintained
sources:
  - CONTEXT.md
last_verified: 2026-07-26
---

# AeroSim 術語表

專案詞彙以 [CONTEXT](../../CONTEXT.md) 為準。本頁保留英文別名並用白話中文說明，
避免將 Simulation Platform 寫成單純 game，或將 AirSim Compatibility Surface 寫成
完整 AirSim compatibility。

| 名詞 | 白話說明 |
| --- | --- |
| Simulation Platform | 整個 AeroSim：人與程式都能使用、可測試的模擬世界。 |
| Player Mode | 給人操作的飛行入口；不是整個產品的同義詞。 |
| Lab Mode | 給程式控制與觀測的入口；不是 debug mode。 |
| AirSim Compatibility Surface | 已版本化、明確列出的 AirSim 1.8.1 相容子集；清單以外就是 unsupported。 |
| AirSim-class Minimum | AeroSim 成為可信 AirSim alternative 所需的外部可觀察 multirotor 最小能力，不包含 cars。 |
| Baseline Sensor Suite | 每個 AirSim-class release 承諾的 RGB、depth、segmentation、IMU、GPS、magnetometer、barometer、LiDAR。 |
| Vehicle Instance | 一台具名稱、獨立 physics/control/sensor state 的多旋翼；不是單純 visual drone。 |
| Operations Dashboard | Godot 內的 vehicle 與 telemetry/sensor/recording/environment 狀態介面，不是 web dashboard。 |
| Ground Station Panel (GSP) | 明確啟用後開啟的自包含本機 `file://` panel bundle，作為開發調參 workstation；不取代 Operations Dashboard。 |
| Flight Replay | 從控制輸入與模擬條件重建的可重現飛行；不是影片。 |
| Dataset Recording | 時間對齊的 command、state、collision、weather、camera、sensor 資料；不是 replay。 |
| Dataset Package | 一個版本化錄製資料夾，含 manifest、samples 與影像／point data；不是 database 或 ROS bag。 |
| External Coordinate Contract | 所有 public integration 共用的 NED world、FRD body、SI units；Godot Y-up 不外洩。 |
| RPC Access Boundary | Lab Mode RPC 初版只允許 `127.0.0.1` loopback，不能當 Internet endpoint。 |
| Flight Command Surface | 每台具名 vehicle 可用的 AirSim-compatible high-level commands；不是 player input API。 |
| Camera Output Surface | 初版承諾的 Scene、DepthPlanar、Segmentation image output；不是所有 AirSim ImageTypes。 |
| Sensor Timebase | 唯一 simulation-time clock；pause 會停止它，wall clock 不是 sensor truth。 |
| Reference Environment | 唯一可交付的 Industrial Test Range，供 Player Mode、Lab Mode、sensors 與 visual acceptance 共用。 |
| Map Catalog | Player Mode 的可交付環境清單；minimum 只有一張 map，但仍保留 catalog 介面。 |
| Scene Object | 已核准 catalog 中有 transform、collision、segmentation label 的可生成物件；不是任意 runtime imported model。 |
| Environment Controls | session-level wind、rain、fog、time-of-day 控制；不等於完整 weather simulation。 |
| AI Visual Verification | Codex 對固定 scene screenshots 的結構化 visual review；不是只檢查截圖存在。 |
| Approved Visual Reference | CAP-006 之後由人核准的視覺參照；此前只有 provisional reference。 |
| Qualification Platform | AirSim-class minimum 必須全部通過的 Ubuntu x86_64 平台；不是所有 platform 的共同阻擋條件。 |
| Hardware configuration | airframe 的質量、慣量與硬體參數的權威資料路徑；runtime 不應硬編這些值。 |
