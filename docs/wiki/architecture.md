---
title: AeroSim 運行時架構
aliases:
  - AeroSim runtime architecture
status: maintained
sources:
  - project.godot
  - levels/smoke/smoke.tscn
  - src/native/register_types.cpp
last_verified: 2026-07-26
---

# AeroSim 運行時架構

Godot 擁有場景、Jolt 碰撞與呈現；原生 C++ 核心擁有確定性飛行、控制、感測器與重播。
兩者由 GDExtension 與 runtime coordinator 連接。跨界契約與開發者驗證路徑會在本頁補齊，
且不取代既有的實作與測試證據。
