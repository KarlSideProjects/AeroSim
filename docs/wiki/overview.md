---
title: AeroSim 開發者總覽
aliases:
  - AeroSim overview
status: maintained
sources:
  - CONTEXT.md
  - PRD_AeroSim.md
  - docs/product_capabilities.md
last_verified: 2026-07-26
---

# AeroSim 開發者總覽

AeroSim 是一個讓人與軟體共用同一模擬世界的 **Simulation Platform**，不是只供
第一人稱飛行的 game。它把「玩家飛行」和「自動化實驗」放在同一個可測試世界裡：

| 入口 | 誰使用 | 白話用途 | 目前產品狀態 |
| --- | --- | --- | --- |
| Player Mode | 人 | 選擇控制器、機體與地圖後飛行，處理碰撞、暫停與重試。 | Foundation |
| Lab Mode | 軟體與自動化測試 | 用 AirSim Compatibility Surface 控制 Vehicle Instance、讀取感測器與觀測世界。 | Confirmed target |

兩個入口的目標是共用同一份模擬狀態，而不是做兩套不同產品。第一個可視化、人機互動
基準是 **Playable Game Milestone**；在它完成前，視覺驗證仍是 deterministic checks 加上
AI Visual Verification 的 provisional evidence，而非正式人工可用性批准。

## 目前可從哪裡著手

1. 想飛：以 Quick Fly 與目前的 Player Mode flight loop 為起點。
2. 想改飛行核心：先讀[運行時架構](architecture.md)，再依其測試路徑選擇 native 或 Godot
   headless 驗證。
3. 想寫自動化：先讀[飛控與相容性](flight-control-and-compatibility.md)，只依賴已發佈的
   AirSim Compatibility Surface，不假設完整 AirSim support。
4. 看不懂名詞或狀態：查[術語表](glossary.md)與[能力與狀態](capabilities.md)。

## 產品邊界

- 最小產品是 multirotor Simulation Platform；cars 與 road-vehicle simulation 不在範圍內。
- **Reference Environment** 是單一可交付的 Industrial Test Range，不是多張 demo map。
- 最小 Lab Mode promise 是兩台具名 **Vehicle Instance**，不是任意規模機隊。
- 產品對外座標是 NED world、FRD body、SI units；Godot Y-up 只在內部使用。
- RPC 初版只允許 loopback，不是可公開部署的 remote API。

所有產品主張以 [PRD](../../PRD_AeroSim.md) 與
[Product Capabilities](../product_capabilities.md) 為準；本頁只提供閱讀順序。
