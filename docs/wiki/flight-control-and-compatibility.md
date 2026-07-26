---
title: AeroSim 飛控與相容性
aliases:
  - AeroSim flight control compatibility
status: maintained
sources:
  - docs/product_capabilities.md
  - config/airsim_compatibility_manifest.json
  - docs/adr/0002-air-sim-client-compatibility-surface.md
last_verified: 2026-07-26
---

# AeroSim 飛控與相容性

飛控與外部整合的說明必須明確區分內建 flight controller、PX4 SITL 與版本化的
AirSim Compatibility Surface。AeroSim 不宣稱完整 AirSim 相容性；未列入已發佈 subset
的操作與設定應明確視為 unsupported。
