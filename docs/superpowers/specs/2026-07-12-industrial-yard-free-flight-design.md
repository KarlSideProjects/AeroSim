# Industrial Yard Free Flight 設計

## 目標

交付第一張可玩的 Free Flight 地圖：工業練習場提供短技術路線、可靠 spawn/reset、碰撞、方向地標及可供 #43 消費的地圖描述資料。

## 場景

新增 `levels/free_flight/industrial_yard.tscn`，Forward+ 與 Mobile Renderer 共用此單一場景。首版只使用 Godot 基礎 Mesh、Material、StaticBody3D 與光照，不引入外部資產或第二份行動場景。

場景包含起飛平台與 `SpawnNorth`、貨櫃穿越、低門、90 度轉角、高塔、地面、靜態碰撞體及明確方向標示。短技術路線可在小場地驗證 spawn、碰撞、reset 和飛行方向。

## 地圖資料與整合

新增純描述資料，包含 map id、名稱、類型、建議機體、風況 preset、spawn 數和模式。#35 交付 descriptor 完整性與欄位自動斷言；地圖卡 UI 呈現屬 #43。#35 不修改主選單或選圖流程。

runtime 僅以 `load_map(map_id)` 載入場景、以 `reset_to_spawn()` 回到 `SpawnNorth`。Quick Fly 的既有預設場景改為 Industrial Yard。場景或 descriptor 缺失時顯示明確錯誤，禁止靜默回退 smoke 場景。

Reset 會清除線速度與角速度並回到 spawn，保留既有 arm 與 throttle 安全語意。Exit 會停止飛行、清理已載入地圖並回到主選單 stub；#43 未來可用既有主選單流程替換該 stub。風況資料只在既有 runtime wind path 可用時套用，不為本 slice 重做 #31。

## 驗證

headless 驗證 descriptor 欄位、spawn、地標、障礙物、碰撞體、reset 和 exit。headed 驗證 active Camera3D、非單色畫面、方向標示、reset-to-spawn 和離開後主選單。同一場景須以兩個 renderer 設定成功載入，並以 CI 掃描禁止 `*_mobile.tscn` 分支資產，確保資產同源。G0.1 performance harness 與 headless smoke 的量測場景必須保持釘死，不受 Quick Fly 預設地圖改動影響。

Linux 自動化後執行本機真實 display headed 驗收；你完成遊玩確認後才關閉 #35。

## 排除

不做第二張地圖、行動版資產複本、外部美術資產、#43 選圖 UI 或 #31 風場重作。

## 衝突與整合

`flight_runtime.gd` 只修改 load_map、reset_to_spawn、exit、預設場景與地圖生命週期區段。不得修改 PR #106 的 ACRO 讀取與物理呼叫、#40 的 profile/setup/quick_fly 控制器流程。若活躍 PR 觸及此範圍，依 #56 停止並讓行，改選不重疊工作。
