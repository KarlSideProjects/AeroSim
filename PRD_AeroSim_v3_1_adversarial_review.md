# PRD_AeroSim v3.1 對抗式審查報告

審查對象：`PRD_AeroSim.md` v3.1  
審查日期：2026-07-08  
方法：2 位 subagent 分別做工程/Gate 與產品/UIUX 對抗式審查，第二輪互相反駁後收斂。本報告另補充現有 FPV drone sim 競品 UIUX 查詢結果。  
範圍前提：依使用者要求，本輪不建議加入玩家存檔、訓練課程、自動更新、回滾、簽章驗證；但系統設定持久化、控制器校準與人機操作 UIUX 仍是可執行遊戲的 Must。

## 1. 總結判定

v3.1 比 v3.0 明顯前進：已補上第一層主選單、Controller Setup、Pause Overlay、OSD preset、Channel Monitor、機體狀態圖，以及「不做玩家存檔但保留系統設定」的界線。

但就「一個完整、可執行的無人機模擬 game」來看，仍不建議直接核准。最大問題不是物理模型寫得不夠多，而是可玩垂直切片、輸入契約、平台 Gate 分流、錯誤狀態與診斷支援還不夠硬。現在 PRD 可能先通過大量物理/平台 Gate，最後才發現玩家無法順利從 Quick Fly 起飛、重生、暫停、回到選單，或 macOS/Linux 裝得起來但控制器不能飛。

## 2. 競品 UIUX 對照

競品共同訊號很一致：FPV sim 的核心 UI 不是華麗主選單，而是「控制器可用、快速進場、墜機後立即重飛、飛行中可調整、問題可診斷」。

| 競品 / 來源 | 觀察 | 對 AeroSim 的含義 |
|---|---|---|
| VelociDrone manual | 明確把 USB joystick / radio 作為起飛前提，主選單包含模型、場景/賽道、控制器、設定等核心區域；設定內有 gamepad mode、gate navigation、reset database、VTX noise 等可飛體驗相關項。 | Quick Fly 前必須處理 controller / fallback；設定不能只做視覺選項，要支撐輸入、導航、性能與 reset。 |
| VelociDrone mobile manual | 有 input setup、display all inputs；飛行中可 reset、切 FPV/LOS、開 PID/rates、quad settings、gate indicators、racing line、race start/abort、system menu、stick display。 | AeroSim 的 Pause Overlay 方向正確，但還缺 action contract 與狀態機，否則只是「項目存在」。 |
| Liftoff support | 支援偵測已知控制器並套預設；未知控制器用遊戲內工具設定；文件也引導使用者找 log 與排查 Steam/controller override。 | 私下發行更需要 `Settings > Diagnostics` support bundle，否則客戶端問題不可重現。 |
| TRYP FPV Steam/SteamDB 2026 update | 近期更新包含 Betaflight-style switch management、OSD editor、LiPo battery simulation、propwash/prop grip、minimap arrow/spawn 等。 | AeroSim 的 switch / arm / reset 要像真實 radio 一樣可映射；OSD editor 應從 Pause 可達，但不可把完整狀態圖做成 GA 阻塞大功能。 |
| Uncrashed Steam discussion | 使用者明確抱怨 gamepad throttle 回中語意與 radio 不同，也有人因 radio 按鈕不足無法 bind reset/restart，被迫離開控制器去按滑鼠/鍵盤。 | PRD 必須拆 radio/gamepad/keyboard profile，且 reset/pause/restart 等動作要有預設與重綁驗收。 |

參考連結：
- VelociDrone manual: https://www.velocidrone.com/downloads/VelociDroneManual.pdf
- VelociDrone mobile manual: https://www.velocidrone.com/mobile_manual
- Liftoff support: https://www.liftoff-game.com/support
- TRYP FPV announcements: https://steamcommunity.com/app/1881200/allnews/
- TRYP FPV SteamDB patch notes: https://steamdb.info/patchnotes/23437616/
- Uncrashed controller discussion: https://steamcommunity.com/app/1682970/discussions/0/842880822501567617/

## 3. 第二輪共識與歧見

共識：
- Gate/Lane 必須拆乾淨。iOS 凍結待決策，不能透過 G0.6「五平台建置」或 mobile fidelity Gate 污染 Desktop/Android 主線。
- 必須提前驗「可執行、可操作、可飛」的最小垂直切片，而不是等 Phase 4B。
- Controller Setup 需要數值化 pass/fail contract，不能只列流程。
- Pause / Reset / Spawn / Exit 需要狀態機與 input action contract。
- Status Diagram 不能以未建模資料與完整 A1-A10 可視化阻塞 GA。

收斂後的歧見：
- Status Diagram 不必整個刪掉；可以保留 Debug Must 的最小真值版，例如馬達推力/RPM、電壓 sag、armed/mode、風向量、PID 飽和。但馬達溫度與完整 A1-A10 動態圖應降為 Should/Later。
- Time Trial 不應放進 Phase 0 可玩切片；Phase 0/1 只要驗證能啟動、進場、起飛、暫停、重生、退出。若 PRD 繼續宣稱競速/闖關遊戲性，最小 Time Trial route 應在 GA 前驗收，但這不是訓練課程，也不需要玩家進度存檔。
- Blackbox capture/replay protocol 很重要，但優先級低於 Quick Fly、輸入可用、Gate 分流；列 High，不列 Critical。

## 4. Critical Findings

### C1. Release Lane 與 SC Gate 混線

位置：`1.4 Release Lanes`、`G0.2`、`G0.6`、`G0.9`、`G0.10`

問題：PRD 說 iOS 凍結、Phase 0 後 Go/No-Go，但 G0.6 寫「五平台建置」且列 SC，G0.9 又把 Mobile Base vs Desktop Full fidelity 列 SC。這會讓 iOS 或行動 profile 問題阻塞 Desktop/Android，即使它們不是同一 release lane。

影響：Desktop/Android 主線可能被 iOS 發行限制或 Mobile Base fidelity 卡死，違反 v3.1 自己定義的 Lane 分流。

最小修正：
- 新增 Gate scope matrix：SC 僅限 shared physics/control core。
- `G0.6` 拆成 `G0.6a shared core determinism` 與 `G0.6b per-lane build smoke`。
- `G0.9` 拆成 shared deterministic replay contract 與 `AND/IOS` mobile fidelity Gate。
- iOS build/perf Gate 必須標示為 `G0.10 Go 後才啟用`。

### C2. 缺早期最小可玩垂直切片 Gate

位置：`Phase 0`、`Phase 4B`

問題：目前可操作 game loop 幾乎等到 Phase 4B 才驗收。這對遊戲是錯的；能不能啟動、選預設機/圖、arm、起飛、暫停、重生、退出，應該比大多數進階物理 Gate 更早暴露。

影響：可能已投入大量物理/平台工作，最後才發現 Quick Fly 卡在授權、控制器、地圖載入或 reset state。

最小修正：新增 `G0.Playable` 或 `G1.Playable`：
- 冷啟動 -> 主選單 -> Quick Fly -> 預設機/預設圖 -> spawn -> throttle low -> arm -> takeoff -> pause -> reset -> exit。
- 通過證據：錄影、輸入 log、build hash、錯誤 log。
- 驗收範圍：至少 Desktop 主線與 Android 主線；iOS 依 G0.10 決策。

### C3. Controller Setup 缺數值化 pass/fail contract

位置：`3.5.4 Controller Setup Flow`、`G4B.UI2`、`G5.6`

問題：PRD 有「偵測 -> live monitor -> 指派 -> 校準 -> 反向偵測 -> switch mapping -> throttle low」流程，但沒有端點、中心、deadzone、抖動、卡軸、低解析度、反向、switch 穩定狀態與保存條件。

影響：UI 可以顯示「完成」，但映射結果仍可能不可飛或危險；也無法寫可靠自動測試。

最小修正：新增 `Calibration Acceptance Contract`：
- 四軸唯一映射，不可重複。
- endpoint min/max 達標，中心容忍、deadzone、jitter RMS 有固定門檻。
- throttle low 必須通過才允許 arm。
- arm / mode switch 至少有穩定狀態數與去抖時間。
- reverse detection 必須可注入測試。
- 未通過不得寫入 calibrated profile。

### C4. Desktop GA 與控制器平台覆蓋不一致

位置：`Desktop GA`、`G0.5`、`G5.1`

問題：Desktop GA 包含 Win/macOS/Linux，但控制器實機 Gate 幾乎只明寫 Windows；Android OTG 有獨立 Gate，macOS/Linux 沒有同級保證。

影響：macOS/Linux 可能 build 成功、安裝成功，但 radio/gamepad 無法飛，仍被視為 Desktop GA。

最小修正：
- 對 Win/macOS/Linux 各定義至少一組 radio 與一組 generic gamepad setup/calibration/disconnect Gate。
- 若資源不足，先把 macOS/Linux 從 GA 改為 Later，不要讓「Desktop」隱含三平台。

## 5. High Findings

### H1. Quick Fly 狀態機不完整

位置：`3.5.4 Quick Fly`、`G4B.UI1`、`G6.6`

缺口：未校準、無控制器、授權伺服器失敗、離線寬限過期、地圖載入失敗、Setup 完成/取消/失敗後回流路徑都未定義。

最小修正：補 Quick Fly state table。每個狀態只允許明確出口：`Fly`、`Setup`、`Fallback`、`Retry`、`Diagnostics`、`Exit`。

### H2. 缺遊戲操作 action contract

位置：`Pause Overlay`、`OSD reset 提示`、`G4B.UI3`

缺口：pause、reset、change spawn、exit、arm、mode、選單確認/返回如何從 keyboard、gamepad、radio switch 觸發未定義。

最小修正：
- 定義 default input map、rebinding、衝突偵測、on-screen glyph。
- 所有飛行中救援動作都要驗「手不離主要控制器」可達；radio 按鈕不足時要有替代 chord 或清楚提示。

### H3. Pause / Reset / Spawn 缺狀態機

位置：`3.5.4 Pause Overlay`、`G4B.UI3`

缺口：pause 是否 freeze physics/timer、reset 是否清 PID integrator、armed state、速度/角速度、blackbox segment；change spawn 是否重置本局計時與 checkpoint 都未定義。

最小修正：
- Pause：凍結 physics 與 timer，保留輸入監控。
- Reset：清速度、角速度、PID integrator、碰撞狀態、當段 telemetry；是否 disarm 需固定。
- Change Spawn：明定是否結束本局並清 timer/checkpoint。

### H4. Channel Monitor 混用 radio / gamepad / keyboard

位置：`3.5.4 Channel Monitor`、`G5.6`

缺口：16ch 是 radio 的合理要求，但對 gamepad/keyboard/MFi fallback 不合理。現在同一規格會讓 fallback 難以驗收，也會稀釋 radio 的真實需求。

最小修正：
- `RadioInputProfile`：16ch live bar、raw、normalized、deadzone、center、endpoint、switch states。
- `GamepadFallbackProfile`：axes/buttons、sticky throttle 模式、deadzone、button binding、非擬真提示。
- `KeyboardFallbackProfile`：離散輸入、限用途提示、可起飛/暫停/重生/退出。

### H5. Map / Spawn / Route loop 還不夠 game

位置：`3.5.4 Map 選擇`、`G4.3`

缺口：目前有地圖卡與方向指示，但沒有 current spawn、spawn selector、route arrow、finish/retry/exit panel 的最小規格。這不是訓練課程，也不是玩家進度；它是「競速/闖關遊戲性」的基本 loop。

最小修正：
- 最小可執行版：1 張地圖可 Free Flight、reset-to-spawn、exit。
- 若保留競速定位：至少 1 條 Time Trial route，含 checkpoint arrow、finish panel：`Retry / Change Map / Exit`。
- 現有 `G4.3 >=3 張地圖` 對極簡可執行版本偏重；可改成 GA Should 或分階段。

### H6. Status Diagram Gate 過重且 telemetry schema 不足

位置：`3.5.5 Drone Status Diagram`、`G4B.UI6`

缺口：要求「真值」是正確方向，但 `TelemetrySnapshot` schema 尚未定義；馬達溫度趨勢沒有熱模型來源；完整 A1-A10 視覺化加上 0.5 ms/frame 預算會把 Debug UI 變成 GA blocker。

最小修正：
- 先定 `TelemetrySnapshot` schema：timestamp、units、coordinate frame、motor order、per-effect fields、latency。
- GA Must 只保留已有真值欄位的 Debug 版。
- 馬達溫度、完整 A1-A10 圖、分割畫面完整版改 Should/Later。
- 0.5 ms/frame 改為固定場景 on/off diff，報 P95/P99，分 CPU/GPU。

### H7. 硬體 JSON schema 不足以支撐可重現物理

位置：`3.6.1`、`G1.7`

缺口：schema 欄位多，但缺 units、座標系、motor order、spin direction、槳表插值/外插規則、schema version、migration/factory default。

最小修正：補版本化 JSON schema 與驗證器；所有表格資料需定義單位、範圍、插值規則與越界處理。

### H8. Blackbox truth 缺 capture/replay protocol

位置：`G1.10`、`G2.8`、`G3.6`

缺口：blackbox 不是自動等於物理真值。需要韌體版本、濾波、電壓、motor output、時間對齊、resampling、初始條件與 calibration/holdout 分離。

最小修正：
- 定義 fixture capture protocol。
- calibration logs 與 holdout logs 分開。
- open-loop / closed-loop replay 分開驗收，避免調參過擬合。

### H9. 設定持久化邊界仍需工程化

位置：範圍排除界線、`Drone preset`、`G5.5`

缺口：PRD 已正確說明玩家進度不存，但 rates、camera angle、FOV、OSD preset/position、drone preset edits、touch layout、controller mapping 是否持久化仍需表格化。

最小修正：新增 `Persistent vs Volatile Settings` 表：
- Persistent：controller calibration、mapping、rates、OSD preset/position、camera/FOV、touch layout、language、quality。
- Volatile：本局 spawn、臨時風況、當場 timer、當場 telemetry。
- 必須有 settings schema version、factory reset、匯入失敗策略。

### H10. 私下發行缺 Diagnostics support bundle

位置：`Phase 6`

缺口：私下發行沒有商店通路與公開 crash pipeline，反而更需要玩家可匯出的支援包。

最小修正：新增 `G6.Diagnostics`：
- `Settings > Diagnostics > Export Support Bundle`
- 包含 build hash、OS/GPU/device info、license 狀態、最近 log、controller raw sample、input mapping、calibration、last error。
- 明定不得包含 secrets / JWT / 個資，或需遮罩。

## 6. 完整但極簡 Drone Sim Game 缺漏清單

Must：
- 冷啟動到可飛：主選單 -> Quick Fly -> 預設 drone/map -> spawn -> arm -> takeoff。
- 1 台預設可飛 drone、1 張可飛 map、Free Flight、reset-to-spawn、pause、exit。
- Quick Fly 狀態機：已校準、未校準、無控制器、授權失敗、離線過期、缺資產、低效能都有出口。
- Radio/gamepad/keyboard 三種 input profile，各自有 UI、預設映射、可重綁與錯誤提示。
- Controller calibration acceptance contract；未通過不得保存 calibrated profile。
- Preflight 面板：throttle low、arm、mode、reset 四狀態不只顯示，也要能阻止高油門誤起飛。
- Pause/reset/spawn 狀態機與飛行中 action contract。
- Minimal OSD：電壓/sag、armed、mode、timer、warning、reset prompt。
- 系統設定持久化、schema version、factory reset；不做玩家進度存檔。
- Fail loud：控制器斷線、授權不可達、地圖/機體 JSON 錯誤、GPU feature 不足都要明確顯示。
- Diagnostics support bundle。
- Gate/Lane 分流，避免 iOS/Mobile 阻塞 Desktop/Android。

Should：
- 3 台 preset drone、3 張 map。
- 若競速定位保留：1 條 Time Trial/checkpoint route、finish panel、retry/change map/exit。
- Minimap 或方向指示、spawn selector。
- Debug Status Diagram，只顯示已有真值 telemetry。
- Rates/import/export、OSD layout safe area、更多 radio matrix。
- UI performance instrumentation 與截圖遮擋稽核。

Out of Scope：
- 玩家進度/成就存檔。
- 訓練課程系統。
- 自動更新、回滾、簽章驗證。
- 線上 ghost、排行榜、UGC 分享、多人大廳。
- 完整 Workbench、內容商店、皮膚/字型系統。
- 未建模馬達溫度、完整熱模型、持久化 replay/ghost。

## 7. 建議 PRD 修改順序

1. 先修 Gate scope matrix：拆 SC / DESK / WIN / MAC / LIN / AND / IOS，不讓 iOS 與 Mobile Base 污染主線。
2. 加 `G0.Playable` 或 `G1.Playable`，用最小 game loop 先驗「能執行、能操作、能飛」。
3. 補 Controller calibration contract 與三種 input profile。
4. 補 Quick Fly、Pause、Reset、Spawn 狀態機。
5. 把 Status Diagram 收斂成 Debug 真值版，完整版與未建模欄位降級。
6. 補 persistent/volatile settings schema、factory reset、diagnostics support bundle。
7. 再處理 3 maps、Time Trial route、進階 OSD、更多內容。

## 8. 核准建議

不建議核准 v3.1 作為可執行開發基線。建議先出 v3.2，把 Critical 1-4 與 High 1-4 修完；High 5-10 至少要在 Gate 表中明確排期或降級，避免工程團隊把 Debug/競品啟發功能誤當 GA blocker。

若目標是「先跑起來」，最小方向是：保留硬核物理主軸，但先把 `Quick Fly + Controller + Reset + Diagnostics` 變成第一級驗收；其餘內容功能往後排。
