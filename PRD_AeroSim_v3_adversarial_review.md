# PRD_AeroSim v3.0 Adversarial Review Report

審查對象：`PRD_AeroSim.md` v3.0  
本次修訂：依使用者新約束調整 review 結論。  
新約束：**不用存檔功能、不做課程、不要求更新/回滾/簽章；以可執行、可操作、可飛為主；必須補足 game 人機操作 UI/UX 設計。**

## Executive Summary

v3.0 的物理、Gate 分類、Release Lanes、碰撞權威切換與硬體參數系統已比前版完整。依目前新 scope，不應再把「玩家存檔、課程、線上 ghost、更新回滾、簽章驗證」列為 Must。

真正缺的是 **操作 UI/UX 規格**：玩家如何接上遙控器、確認通道、校準、選機、選場、調 rates、起飛、墜機重飛、暫停、快速改設定、看 OSD、切換鏡頭、處理輸入失效。這些才是「能執行」的核心。

最小有效修正：新增一章 `Human-Drone Operation UI/UX`，並在 Phase 4B / Phase 5 加 Gate；不做大型遊戲循環，不做課程，不做存檔。

## Competitor UI/UX Research

### VelociDrone

VelociDrone 的主選單把操作入口直接攤開：Quick Start 會用最近一次 quad + track 直接進場；Single Player、Nemesis ghost、Multiplayer、Track Editor、Options、Controller、Leaderboard、Tutorial 都在第一層。Controller 入口直接進 RC assignment/calibration。Model selection 可加 quad、選 quad、改 prop/drag/battery/camera angle；Track selection 有 scenery / quad class / search / favourite / new filters，也有 wind settings 與 race mode options。飛行中有 FPV / LOS / spectator camera 切換。

可借鑑：

- 第一層必須有 `Quick Fly`、`Controller`、`Drone`、`Map`、`Settings`。
- Controller calibration 不應藏在系統設定深處。
- 選場不只列地圖，要同畫面提供 wind / mode / start。
- FPV、LOS、spectator 是操作模式，不是 debug 功能。

來源：VelociDrone 官方手冊與官網。  
https://www.velocidrone.com/downloads/VelociDroneManual.pdf  
https://www.velocidrone.com/

### Liftoff

Liftoff 把 Replay、Workbench、Track Builder 等放在 main menu 的 Tools 區；支援大量輸入裝置，只要能連到電腦且至少有兩個 stick inputs，通常可用。官方 support 把 replay、input devices、log files、Pro account 等操作問題集中在支援文件。Liftoff 更新紀錄也顯示它重視 Quick Play、pause menu 直接開 quick play setup、Workbench、Track Builder、game options 即時切換、drone selection 預設目前機體。

可借鑑：

- `Workbench` 心智模型適合 AeroSim 的硬體參數系統，但 v1 只需最小版：機體 preset + camera angle + rates。
- Pause menu 應可直接換地圖/重生/改 rates，不要回主選單。
- Logs / diagnostics 入口要可見，因為遙控器和 GDExtension 失敗時需要支援。

來源：Liftoff 官方 support、Steam/news 更新。  
https://www.liftoff-game.com/support  
https://www.liftoff-game.com/news/milestone-050-released  
https://store.steampowered.com/news/posts/?appids=410340&enddate=1561492776&feed=steam_community_announcements

### Uncrashed

Uncrashed 的 Steam 頁把定位說得很清楚：從無真機經驗到熟練飛手都能練；可用真實值設定模擬自己的 drone；有 big maps、multiplayer、environment/track editor、simple settings 與 advanced physics settings。它也明確要求 game controller 或 radio，且推薦 radio-controller。

可借鑑：

- 即使 v1 不做課程，也要讓新手知道「接控制器後如何起飛」。
- Simple settings 與 Advanced settings 要分層：先能飛，再給專家調 gravity/air friction/prop efficiency 類參數。
- 若沒有鍵鼠飛行，就要在 UI 明確說「需要 gamepad/radio」。

來源：Uncrashed Steam 頁。  
https://store.steampowered.com/app/1682970/Uncrashed__FPV_Drone_Simul

### TRYP FPV

TRYP 近版更新重點包含 OSD editor、Betaflight-style switch management、battery simulation、propeller damage、analog/digital video effects、optional input delay、activity/challenge doors always visible、ghost trail 調整、minimap spawn VFX、keyboard throttle binding、UI overhaul、readability/performance improvement。這些不是純內容功能，而是飛行操作可讀性與沉浸感。

可借鑑：

- OSD editor / OSD preset 至少要有簡化版。
- Betaflight-style switch management 對 FPV 玩家重要：arm、mode、turtle / reset 類功能要可映射且可視化。
- 地圖內活動門、spawn、方向提示要能被看懂；不能只靠選單文字。
- 類比/數位畫面效果、input delay 應是可開關設定，不能影響基本可飛性。

來源：TRYP FPV Steam Community updates。  
https://steamcommunity.com/app/1881200/allnews/

## Revised Top Findings

### Critical 1. PRD 缺「接控制器到起飛」的操作 UI/UX Gate

位置：`PRD_AeroSim.md:123-145`, `PRD_AeroSim.md:279-303`

問題：PRD 有 UI/UX 原則與輸入 Gate，但沒有定義玩家從首次啟動到可飛的操作流：裝置偵測、通道 assignment、校準、端點/反向、arm switch、模式 switch、throttle safety、起飛前檢查。

影響：物理核心可以全過，玩家仍可能卡在「控制器有訊號但不知道哪個 channel 是 throttle」。

最小修正：

- 新增 `Controller Setup Flow`：Detect → Channel monitor → Assign sticks → Calibrate endpoints → Reverse check → Switch mapping → Safety check → Test hover pad。
- Gate：未看說明書的 FPV 玩家可在 90 秒內完成接收器/遙控器校準並進入可控飛行。

### Critical 2. 主選單沒有明確 Quick Fly 操作模型

位置：`PRD_AeroSim.md:141-145`, `PRD_AeroSim.md:283-291`

問題：競品把 Quick Start / Single Player / Controller / Model / Track 放第一層。AeroSim 目前只寫常用功能 ≤3 層，仍太鬆；「能執行」應要求玩家進 app 後一眼知道怎麼飛。

影響：產品會像工程 demo，使用者每次都要找路。

最小修正：

- 第一層固定五個入口：`Quick Fly`、`Controller`、`Drone`、`Map`、`Settings`。
- `Quick Fly` 使用預設 drone + 預設 map + 無風，直接進場。
- 若控制器未校準，`Quick Fly` 先導到 Controller Setup，而不是進場後失控。

### Critical 3. 飛行中缺 Pause / Reset / Tuning 操作面

位置：`PRD_AeroSim.md:273-291`

問題：PRD 有墜機→重飛 ≤1.5 秒，但沒有飛行中 pause menu：重生、換 spawn、換地圖、調 rates、調相機角度、切 FPV/LOS、回 controller monitor。

影響：每次改一個手感參數都要退出，stick-time 會被破壞。

最小修正：

- Pause overlay 固定項：`Resume`、`Reset`、`Change Spawn`、`Rates`、`Camera`、`OSD`、`Controller Monitor`、`Exit`。
- Rates / camera / OSD 修改即時生效，不重載場景。

### High 4. Controller Monitor / Channel Diagnostics 必須是一等 UI

位置：`PRD_AeroSim.md:299-303`

問題：PRD 只驗 16 通道映射與斷線重連，但沒有要求 channel monitor。FPV 遙控器常見問題是軸反向、端點不到位、中心偏移、switch channel 不明、USB mode 錯。

影響：支援成本高，使用者會以為物理或飛控壞了。

最小修正：

- Controller UI 顯示 16 channel live bars、raw value、normalized value、deadzone、center、endpoint。
- 顯示 `Throttle low?`、`Arm switch mapped?`、`Mode switch mapped?`、`No duplicate axis?`。
- 斷線時飛行畫面 fail loud，顯示 reconnect 狀態。

### High 5. OSD / HUD 仍太抽象，缺可操作規格

位置：`PRD_AeroSim.md:276`, `PRD_AeroSim.md:288-291`

問題：PRD 只列 FPV 攝影機 OSD 與本地化截圖稽核，沒有指定 OSD 元件與操作狀態。FPV 模擬器的 HUD 是操控回饋核心，不是裝飾。

最小修正：

- v1 內建 3 個 OSD preset：`Minimal`、`Race`、`Debug`。
- 元件：電壓/電量、armed 狀態、flight mode、timer、lap/checkpoint、RSSI/訊號效果、警告訊息、reset prompt。
- OSD editor 只做開關與位置拖曳；不做完整字型/皮膚系統。

### High 6. Drone / Workbench 需要簡化版，不是完整零件編輯器

位置：`PRD_AeroSim.md:147-173`, `PRD_AeroSim.md:230-233`

問題：硬體參數系統很深，但人機 UI 若直接暴露 JSON/物理參數，玩家無法操作。競品通常提供 Workbench / model selection。

最小修正：

- v1 UI 只顯示 preset：`5 inch Freestyle`、`5 inch Race`、`Iris Trainer`。
- 每個 preset 只允許改：camera angle、FOV、rates、prop profile（若已支援）。
- Advanced tab 才顯示原始參數與 JSON import/export。

### High 7. Map Selection 需含「起飛前可讀資訊」

位置：`PRD_AeroSim.md:273-276`

問題：PRD 只說 3 張地圖與檢查點，沒有地圖選擇 UI。VelociDrone 顯示 track filters、best lap、wind settings、race mode；TRYP 強調活動門、spawn/minimap 可讀性。

最小修正：

- Map card 顯示：map type、recommended drone、wind、spawn count、race/free flight、estimated FPS cost。
- 起飛前可選：Free Flight / Time Trial、wind preset、spawn point。
- 地圖內提供 minimap / direction marker / reset-to-spawn。

### Medium 8. 不做課程可以，但仍需要「零教學文字的起飛輔助」

位置：`PRD_AeroSim.md:283-286`

問題：使用者明確不需要課程；但完全沒有引導會讓第一飛失敗。這不必是課程，可以是操作狀態 UI。

最小修正：

- 首次進場顯示小型 preflight panel：`Throttle low`、`Arm`、`Mode`、`Reset`。
- 起飛後自動消失；可在設定關閉。
- 不保存進度，不做 lesson。

### Medium 9. 存檔/進度/更新/回滾/簽章不列 Must

位置：舊報告結論修正

依新 scope，以下不列 Must：

- 玩家存檔 / 進度系統
- 訓練課程
- 更新 / 回滾 / 簽章驗證
- 線上 ghost / leaderboard / UGC

但仍建議保留 **本次執行階段的 volatile state**：目前控制器校準、當場 rates、當場 OSD 設定。這不是存檔，是讓 session 內可操作。

## Revised UI/UX Gate Proposal

### G4B.UI1 — First Fly Flow

未看說明書的 FPV 玩家，從啟動到可控起飛：

- 已校準控制器：≤ 30 秒
- 未校準控制器：≤ 90 秒
- 若無控制器：UI 明確提示需要 gamepad/radio 或進入 keyboard/gamepad fallback

### G4B.UI2 — Controller Setup

Controller setup 必須顯示：

- 16 channel live monitor
- stick assignment
- endpoint calibration
- reverse detection
- arm / mode switch mapping
- throttle-low safety check

通過條件：RadioMaster / FrSky 實機各一可完成映射，且錯誤軸反向可被 UI 明確發現。

### G4B.UI3 — In-flight Operation Overlay

飛行中 pause overlay 提供：

- Resume
- Reset
- Change Spawn
- Rates
- Camera
- OSD
- Controller Monitor
- Exit

通過條件：改 rates / camera angle / OSD preset 不重載場景，Reset 到可輸入 ≤ 1.5 秒。

### G4B.UI4 — OSD Presets

內建 `Minimal`、`Race`、`Debug` 三個 OSD preset。  
通過條件：1080p、行動橫向畫面、zh-TW/en 皆無遮擋主要飛行視野，警告訊息不遮擋 gate 中央。

### G4B.UI5 — Map / Drone Selection

Map selection 和 Drone selection 各自一層可完成：

- 選 preset drone
- 選 map
- 選 free flight / time trial
- 選 wind preset
- 起飛

通過條件：常用流程不超過三次確認；Quick Fly 一鍵進預設場。

## Recommended PRD Patch Shape

最小補丁順序：

1. 刪除或降級 review 報告中「存檔、課程、更新/回滾/簽章」的 Must 要求。
2. 在 PRD 3.5 新增 `Human-Drone Operation UI/UX` 子章。
3. 在 Phase 4B 新增 `G4B.UI1` 到 `G4B.UI5`。
4. Phase 5 輸入裝置 Gate 補 Controller Monitor / diagnostics，不只驗能映射。
5. Phase 4 地圖 Gate 補 map selection card、spawn、wind preset、reset-to-spawn。

## Sources

- VelociDrone 官方手冊：主選單、Controller calibration、Model/Track selection、wind settings、FPV/LOS/spectator camera。https://www.velocidrone.com/downloads/VelociDroneManual.pdf
- VelociDrone 官網：single player、offline ghost/Nemesis、multiplayer、大量場景/賽道。https://www.velocidrone.com/
- Liftoff support：Replay menu、input device support、logs、Workbench/Pro account。https://www.liftoff-game.com/support
- Liftoff news：Replay、leaderboards、Quick Play、Tools / Workbench / Track Builder menu organization。https://www.liftoff-game.com/news/milestone-050-released
- Uncrashed Steam：real-value settings、large maps、multiplayer、environment/track editor、controller/radio requirement。https://store.steampowered.com/app/1682970/Uncrashed__FPV_Drone_Simul
- TRYP FPV Steam Community：OSD editor、Betaflight-style switch management、activity doors、ghost trail、minimap spawn VFX、UI/readability updates。https://steamcommunity.com/app/1881200/allnews/
