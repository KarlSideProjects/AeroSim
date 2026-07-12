# Industrial Yard Free Flight 設計

## 目標

交付第一張可玩的 Free Flight 地圖：工業練習場提供短技術路線、可靠 spawn/reset、碰撞、方向地標及可供 #43 消費的地圖描述資料。

## 場景

新增 `levels/free_flight/industrial_yard.tscn`，Forward+ 與 Mobile Renderer 共用此單一場景。首版只使用 Godot 基礎 Mesh、Material、StaticBody3D 與光照，不引入外部資產或第二份行動場景。

場景包含起飛平台與 `SpawnNorth`、貨櫃穿越、低門、90 度轉角、高塔、地面、靜態碰撞體及明確方向標示。短技術路線可在小場地驗證 spawn、碰撞、reset 和飛行方向。

## 地圖資料與整合

新增純描述資料，包含 map id、名稱、類型、建議機體、風況 preset、spawn 數和模式。#43 未來只消費此資料建立選圖 UI；#35 不修改主選單或選圖流程。

runtime 僅以 `load_map(map_id)` 載入場景、以 `reset_to_spawn()` 回到 `SpawnNorth`。Quick Fly 的既有預設場景改為 Industrial Yard。場景或 descriptor 缺失時顯示明確錯誤，禁止靜默回退 smoke 場景。

Reset 會清除線速度與角速度並回到 spawn，保留既有 arm 與 throttle 安全語意。風況資料只在既有 runtime wind path 可用時套用，不為本 slice 重做 #31。

## 驗證

headless 驗證 descriptor 欄位、spawn、地標、障礙物與碰撞體。headed 驗證 active Camera3D、非單色畫面、方向標示與 reset-to-spawn。同一場景須以兩個 renderer 設定成功載入，確保資產同源。

Linux 自動化後執行本機真實 display headed 驗收；你完成遊玩確認後才關閉 #35。

## 排除

不做第二張地圖、行動版資產複本、外部美術資產、#43 選圖 UI 或 #31 風場重作。
