# 產品需求文件 (PRD) — Project AeroSim
## 3D 擬真四軸無人機模擬遊戲與虛擬飛控系統

| 文件屬性 | 內容 |
|---|---|
| 版本 | v3.2（回應 v3.1 對抗式審查：Lane/SC 分流修正、G0.P 可玩垂直切片、校準驗收合約、三種輸入 Profile、Quick Fly/Pause/Reset 狀態機、blackbox holdout 協定、診斷支援包；狀態圖改分期交付並移除無真值之溫度欄位） |
| 文件狀態 | 待核准 |
| 發行模式 | **私下提供（Private Distribution）**，不上架 Google Play / App Store / Steam |
| 開發模式 | 階段閘門制（Phase-Gate）：**門檻數值為剛性要求，核准後凍結、不得下修；未達標即退回修改，循環直到通過** |

### 變更紀錄
- v3.2 修訂（2026-07-11）：**Linux 實測主車道**——Linux 為唯一實測平台，實測序列固定「自動化 → Godot headed 測試 → 維護者遊玩驗收」；Windows/macOS/Android/iOS 降為 build＋CI 自動測試車道，平台實測 gate 標 N/A 凍結（非通過）。門檻數值不變，屬驗收平台範圍調整（PRD 1.4 Lane 獨立結構）。詳 `docs/decisions/2026-07-11-linux-primary-acceptance.md`。
- v3.2：接受 v3.1 審查 C1–C4、H1–H4、H7–H10；H5 改分期不降級（3 張地圖仍為 GA Must）；H6 分期交付並移除溫度欄位（無熱模型即無真值）；新增已知物理近似邊界聲明。
- v3.1：接受 v3.0 對抗式審查之操作 UI/UX 發現；新增機體狀態圖需求；明文界定「不做存檔」之範圍。
- v3.0：接受對抗式審查報告之 Critical 1–4、High 5–8 及多數附加發現；新增第 3.6 章硬體參數系統；發行模式改為私下提供；修正 G2.3（Angle Mode ≠ 位置保持）、G0.6（跨平台浮點容忍）。
- v2.2：新增 UI/UX 章節與 Phase 4B。
- v2.1：Godot 4.7、C++ GDExtension、Linux headless CI。

### 範圍排除（Must-Not，避免範圍蔓延）
以下**不列入**本產品需求：玩家進度/成就存檔、訓練課程系統、自動更新/回滾/簽章驗證、線上幽靈/排行榜/UGC 分享。

**界線釐清**：「不做存檔」指玩家進度資料。**裝置與設定持久化（控制器校準、通道映射、rates、觸控布局、OSD preset 選擇）屬系統設定，必須跨 session 保留**——否則 G4B.UI1（已校準 ≤30 秒）、G5.5、G4B.7 無法成立。單場飛行內的暫態（當場 spawn 點、當場風況選擇）為 volatile，不持久化。

---

## 1. 專案概述

### 1.1 產品定位
高擬真度 3D 四軸無人機模擬遊戲，核心賣點為**硬核物理**（螺旋槳動力學、氣動效應、氣象風場）與**真實飛控手感**，兼顧競速與闖關遊戲性。以私下授權方式提供給特定客戶／社群。

### 1.2 核心目標
1. 物理擬真第一優先：推力/反扭力、阻力、地面效應、尾流下洗、Propwash、穩態風 + Dryden 紊流 + 風切。
2. 擬真的根基是**實務硬體參數**（第 3.6 章）：馬達/槳/電池/機架皆以真實產品規格與台架實測數據建模，外界影響（風、氣壓、電量）作用於這些參數而非抽象數值。
3. 100% 可閉源商用：Tier 1 僅用 MIT/BSD/Zlib/Apache-2.0 依賴；GPL 元件（Betaflight）以獨立行程隔離為 Tier 2，**發布前須法務核准**。
4. 支援真實遙控器（RadioMaster / FrSky 等 USB joystick 模式）進行 FPV 訓練。

### 1.3 產品分層（Tier）

| 層級 | 平台 | 飛控 | 授權狀態 |
|---|---|---|---|
| **Tier 1 基礎版（本 PRD 主體）** | Win / macOS / Linux / Android /（iOS 待決策，見 1.4） | 自研高頻 PID 飛控（C++ GDExtension） | 全 MIT/BSD，完全閉源 |
| **Tier 2 專業模組（桌面限定）** | Win / macOS / Linux | Betaflight SITL 獨立行程橋接 | GPL-3.0，隔離發布，**須法務核准** |
| **Tier 3 工業選配（後期評估）** | Win / Linux | PX4 SIH | BSD 3-Clause |

### 1.4 發布通道（Release Lanes）— 取代單一全平台閘門

各 Lane 獨立推進與發布；**共用核心（shared core：GDExtension 飛控/物理/氣動）的 Gate 阻擋所有 Lane；平台專屬 Gate 只阻擋該 Lane**。

| Lane | 發行方式 | 狀態 |
|---|---|---|
| Windows GA（WIN） | 直接提供安裝檔 + 自建授權伺服器啟用（可複用既有 FastAPI 授權架構：註冊 → 簽發 → JWT 驗證） | 主線 |
| macOS / Linux GA（MAC, LIN） | 同上；**控制器實機閘門（G5.1）須逐 OS 通過，任一 OS 未過僅凍結該 OS Lane**，不得以「Desktop」名義隱含通過 | 主線（可獨立延後） |
| Android build-only | 保留 APK export/artifact 與大小檢查；沒有實機驗收，不得宣稱可發行 | **not verified** |
| iOS | **待商業決策**：私下發行僅有 Ad Hoc（100 台裝置/年）、TestFlight（≤1 萬人，仍須 Apple 審查）兩條路；Enterprise Program 僅限發給自家員工，發給外部客戶違反協議 | 凍結，Phase 0 後決策 |
| Tier 2 桌面模組 | 隨 Desktop Lane，獨立安裝包 | 附屬 |

> **剛性約束 C-1**：iOS 禁止 spawn subprocess，任何 GPL 韌體嵌入即構成傳染。Tier 2 / Tier 3 永久禁止進入 iOS / Android。
> **剛性約束 C-2**：Tier 1 依賴授權不屬 MIT/BSD/Zlib/Apache-2.0/公有領域者不得合入；CI 授權掃描違規即 build fail。
> **剛性約束 C-3**：**私下提供仍構成 GPL 意義上的散布**。Tier 2 每次交付客戶，皆須同步履行 GPL-3.0 原始碼義務（見 G7.1）。

---

## 2. 技術選型與授權矩陣

| 模組 | 選型 | 授權 | 商用風險 |
|---|---|---|---|
| 遊戲引擎 | **Godot 4.7（版本鎖定：專案凍結至特定 patch 版與 export template hash，記錄於 repo；引擎升級須重跑 G0–G3 全部 Gate）** | MIT | 無 |
| 物理引擎 | Jolt Physics（Godot 4.6+ 預設） | MIT | 無 |
| 飛控核心語言 | C++ GDExtension（1kHz PID、六自由度積分、氣動模型、硬體參數模型皆在此層）。C# 於 iOS/Android 屬實驗性、Web 不支援，故不採用 | MIT（godot-cpp） | 無 |
| 桌面渲染 | Forward+（Vulkan）+ SDFGI + Volumetric Fog | MIT | 無 |
| 行動渲染 | Mobile Renderer + LightmapGI 烘焙光照 | MIT | 無 |
| 行動觸控輸入 | Godot 4.7 內建 VirtualJoystick（Fixed/Dynamic/Following）；iOS 控制器經 SDL3 | MIT | 無 |
| 氣動公式來源 | gym-pybullet-drones 之 drag / ground effect / downwash（移植公式並以其 Python 原版為 CI 數值 Oracle） | MIT | 無 |
| 風場 / 紊流 | Dryden（MIL-F-8785C）+ 穩態風 + 風切，自研 C++ 實作 | 公開軍規標準 | 無 |
| 自研飛控 | C++ 串級 PID（角速度內環 + 角度外環）+ 互補濾波 / Mahony | 自有 | 無 |
| Tier 2 飛控 | Betaflight SITL（獨立行程、UDP、無共享記憶體、無連結） | **GPL-3.0** | **發布前須法務核准**（見 G7.1） |
| Tier 3 飛控 | PX4 SIH | BSD 3-Clause | 無 |
| 授權伺服器 | 自建 FastAPI + JWT（複用既有架構模式） | 自有 | 無 |

---

## 3. 核心技術架構

### 3.1 雙迴圈子步進架構

```
┌────────────────────────────┐        ┌─────────────────────────────┐
│  遊戲客戶端 (Godot/GDScript)  │        │  飛控核心 (C++ GDExtension    │
│  · 渲染 60–120 FPS          │        │   / Tier2: SITL 獨立行程)     │
│  · Jolt 碰撞 / 剛體 240 Hz   │◄──────►│  · PID 迴圈（見平台 Profile）  │
│  · 場景 / 風場 / 遊戲邏輯     │  狀態   │  · IMU 模擬(噪音/漂移/延遲)    │
│  每 physics tick 觸發        │  交換   │  · 馬達/電池/槳 硬體參數模型    │
│  N 次飛控子步進              │        │  · 自由空間六自由度積分         │
└────────────────────────────┘        └─────────────────────────────┘
```

- 語言分層：飛控核心 + 氣動 + 風場 + 硬體參數模型 = C++ GDExtension；遊戲邏輯/UI/關卡 = GDScript。禁止在 GDScript 實作逐子步進物理。
- Tier 1 同行程零 IPC 延遲；Tier 2 換 SITL 獨立行程，UDP 封包協定與 Tier 1 內部介面同構，確保可插拔。

### 3.2 平台物理 Profile（取代單一硬指標）

| Profile | PID 頻率 | Jolt tick | 氣動效應 | 適用 |
|---|---|---|---|---|
| Desktop Full | 1000 Hz | 240 Hz | 全開（A1–A10） | 桌面各 Lane |
| Mobile High | 1000 Hz | 240 Hz | 全開 | 旗艦行動裝置（執行期偵測） |
| Mobile Base | 500 Hz + 陀螺儀插值 | 120 Hz | 全開，Dryden 更新降至 100 Hz | 基準行動裝置 |

> **剛性約束 C-4**：Mobile Base 與 Desktop Full 對同一組輸入序列的姿態輸出偏差須通過 G0.9（fidelity 等價 Gate）。Profile 之間**不是**門檻鬆緊，而是兩組各自凍結的門檻。

### 3.3 碰撞權威切換規格（新增，回應審查 High 6）

- **Canonical state**：自由飛行時權威 = GDExtension 高頻積分；Jolt broadphase 偵測到接觸的當幀起，權威 = Jolt，直到連續 N 幀（可配置，預設 3）無接觸後交回。
- 交接時衝量回寫：Jolt 解算之衝量/接觸法向回寫飛控核心之速度/角速度狀態；飛控積分器重置積分項（防 PID windup）。
- CCD：無人機剛體啟用 Jolt 連續碰撞偵測，防高速穿模。
- 能量約束：碰撞後總動能不得增加（超出 restitution 設定值 +1% 即為 bug）。

### 3.4 空氣動力學模型（A1–A10）

| # | 效應 | 模型 | 來源 |
|---|---|---|---|
| A1 | 馬達推力/反扭力 | F = k_t·ω²、τ = k_q·ω²（k_t/k_q 由 3.6 節台架推力表擬合，非手調） | 標準模型 + 實測表 |
| A2 | 馬達動態 | 一階慣性環節，τ_m 由實測階躍響應標定 | SimITL 思路 |
| A3 | 機身阻力 | 轉速-速度耦合線性阻力矩陣 | Forster (2015) Eq. 4.2 |
| A4 | 地面效應 | 推力增益 vs z/R_prop | Shi et al. (2019) Eq. 15 |
| A5 | 尾流下洗 | 上方機對下方機升力衰減 | DSL 實驗模型 |
| A6 | Propwash | 大姿態變化穿越自身尾流之角速度擾動注入 | 自研 + 真機 blackbox 標定（G3.6） |
| A7 | 穩態風 | 3D 向量場，場景可配置 | 自研 |
| A8 | 紊流 | Dryden 成形濾波器，輕/中/重軍規參數 | MIL-F-8785C |
| A9 | 風切 | 風速隨高度剖面 | MIL-F-8785C |
| A10 | 電池-推力耦合 | 電壓 sag → 可用推力上限（由 3.6 電池參數驅動） | SimITL 思路 |

> **已知物理近似邊界（誠實聲明，隨產品文件揭露）**：本產品為剛體動力學 + 參數化氣動模型，非 CFD。未建模現象：渦環狀態（VRS，垂直快速下降穿越自身下洗）、槳葉柔性與失速、精細紊流-機體交互。A6 propwash 為自研近似項，以 G3.6 之真機頻段能量比（0.5–2.0 倍）界定其擬真度範圍。

### 3.5 UI/UX 設計需求

#### 3.5.1 設計原則（凍結後與 Gate 同等剛性）
1. **Stick-time first**：墜機→重飛迴圈是本品類核心體驗。
2. **對齊 FPV 社群慣例**：rates 曲線公式與匯入格式和 Betaflight 對齊（RC Rate / Super Rate / Expo 同名同義）。**PID / 濾波器參數標示為 sim profile，明文不保證與真機等價，UI 須顯示免責提示**（回應審查 High 8）。
3. **雙平台自適應而非縮放**。
4. UI 動效用 Godot 4.7 Control offset transforms，禁止移動實際 layout 做動畫。

#### 3.5.2 競品 UX 參考（僅參考互動流程與資訊架構，禁止複製美術資產）

| UX 流程 | 參考對象 | 學習重點 |
|---|---|---|
| 墜機重試迴圈 | Velocidrone / Uncrashed | 單鍵瞬時重生、計時自動重置、幽靈重播 |
| 機體調參/虛擬工作台 | Betaflight Configurator / Liftoff / SITL Forge | 分頁式參數、rates 曲線即時預覽、以真實零件型號組機 |
| 首次上手 | Velocidrone 校準流程 | 通道自動偵測 → 端點校準 → 直入練習場 |
| 行動觸控布局 | FPV Freerider | 雙虛擬搖桿可調、可視性平衡 |
| 極簡 HUD | Flowstate（開源） | FPV 眼鏡視角 OSD |

#### 3.5.3 資訊架構剛性約束
- 常用功能（起飛、換機體、換地圖、調 rates、重播）距主選單 ≤ 3 層。
- 「飛行手感」與「系統設定」兩棵獨立樹。
- 調參支援 JSON 匯出/匯入、恢復預設、即時生效。
- 本地化 zh-TW / en，字串全部外部化。

#### 3.5.4 人機操作 UI/UX（Human-Drone Operation，回應 v3.0 審查）

**主選單第一層固定五入口**：`Quick Fly`、`Controller`、`Drone`、`Map`、`Settings`。
- `Quick Fly`：預設機體 + 預設地圖 + 無風直接進場；若控制器未校準，先導入 Controller Setup 而非帶著失控狀態進場。
- 無任何控制器時，UI 明確提示需要 gamepad/radio，並提供鍵盤/手把 fallback 模式（明示非擬真操控）。

**Controller Setup Flow（固定順序）**：偵測裝置 → 16 通道 live monitor → 搖桿指派 → 端點校準 → 反向偵測 → arm / mode switch 映射 → 油門低位安全檢查 → 測試懸停台。

**校準驗收合約（Calibration Acceptance Contract，回應審查 C3）**——全數通過才允許寫入 calibrated profile，任一未過即擋存檔並標示原因：
- 四軸唯一映射，零重複指派。
- 端點：實測 min/max 覆蓋該軸行程 ≥ 95%；中心偏移 ≤ ±2% 滿量程；deadzone 可配置 0–10%。
- 靜置抖動 RMS ≤ 0.5% 滿量程（1 秒取樣）。
- Switch：≥ 2 個穩定狀態、去抖 ≤ 50 ms。
- 油門低位檢查通過為 arm 之前置條件（未低位不得 arm，preflight 面板同步阻擋）。
- 反向偵測可注入測試（G4B.UI2 之 100% 偵測率以本合約為判定標準）。

**三種輸入 Profile（回應審查 H4，Channel Monitor 依 Profile 呈現）**：
- `RadioProfile`：16ch live bar / raw / normalized / deadzone / 中心 / 端點 / switch 狀態，完整校準合約。
- `GamepadProfile`：軸/鍵顯示、sticky throttle 模式（油門不回中語意）、deadzone、鍵位綁定、UI 明示「非擬真操控」。
- `KeyboardProfile`：離散輸入，僅保證可起飛/暫停/重生/退出，明示限制用途。

**操作 Action Contract（回應審查 H2）**：pause / reset / change spawn / exit / arm / mode 於三種 Profile 各有預設映射、可重綁、衝突偵測、畫面 glyph 提示；**所有飛行中救援動作（reset/pause）必須「手不離主控制器」可達**——radio 按鈕不足時提供組合鍵（chord）或明確提示替代路徑。

**Quick Fly 狀態機（回應審查 H1）**：

| 進入時狀態 | 出口 |
|---|---|
| 已校準控制器 | → 直接進場 |
| 未校準 | → Controller Setup（完成→進場；取消→主選單） |
| 無控制器 | → 提示 + Gamepad/Keyboard fallback 或返回 |
| 授權不可達 / 離線寬限過期 | → 明確錯誤畫面：Retry / Diagnostics / Exit（禁止靜默鎖死，見 G6.6） |
| 地圖/機體 JSON 載入失敗 | → 錯誤明示 + 回退出廠預設（factory default）選項 |

**Pause / Reset / Spawn 語意（回應審查 H3，凍結為規格）**：
- Pause：凍結物理與計時器，輸入監控持續（Channel Monitor 可用）。
- Reset：回 spawn 姿態、清空線/角速度、清 PID 積分項、清碰撞狀態、當段遙測標記分段；**保持 armed、油門即時跟隨搖桿**（沿用競速模擬器慣例）；Time Trial 下計時與 checkpoint 歸零。
- Change Spawn：結束本段（計時/checkpoint 清空），於新 spawn 依 Reset 語意重生。

**Channel Monitor 為一等 UI**（依上述 Profile 分規格呈現）。飛行中控制器斷線：fail loud——畫面即時警示 + 顯示重連狀態，禁止靜默失控。

**飛行中 Pause Overlay（固定項）**：`Resume`、`Reset`、`Change Spawn`、`Rates`、`Camera`、`OSD`、`Controller Monitor`、`Status Diagram`、`Exit`。Rates / camera / OSD 修改即時生效，不重載場景。

**OSD Preset（內建三組）**：`Minimal`、`Race`、`Debug`。元件：電壓/電量（含 sag 即時值）、armed 狀態、flight mode、計時、lap/checkpoint、訊號狀態、警告訊息、reset 提示。OSD 編輯僅做元件開關與位置拖曳，不做字型/皮膚系統。

**Drone 選擇（簡化 Workbench）**：第一層僅顯示 preset 卡片（`5" Freestyle`、`5" Race`、`Iris Trainer`），preset 內可調：camera angle、FOV、rates、槳型（若支援）。Advanced 分頁才暴露 3.6 原始參數與 JSON 匯入/匯出。

**Map 選擇**：地圖卡顯示——類型（競速/花飛/闖關）、建議機體、風況 preset、spawn 數、模式（Free Flight / Time Trial）。同畫面完成選圖 + 選模式 + 選風況 + 起飛。場內提供方向指示、reset-to-spawn。

**首飛輔助（非課程）**：首次進場顯示小型 preflight 面板（`Throttle low` / `Arm` / `Mode` / `Reset` 四狀態燈），起飛後自動隱藏，可於設定停用。無教學文字、無進度保存。

#### 3.5.5 機體狀態圖（Drone Status Diagram）

**目的**：以俯視機體示意圖即時顯示各部位所受之動態影響，讓玩家「看見」物理層正在發生什麼。

**剛性約束 C-5：狀態圖所有數值必須取自物理層真值（GDExtension 遙測快照），禁止任何裝飾性/推測性動畫。** 物理效應關閉時，其對應指示必須歸零——狀態圖因此兼作 A1–A10 效應的可視化驗證面。

| 顯示元素 | 資料來源 | 呈現 |
|---|---|---|
| 四馬達推力/轉速 | A1/A2 每馬達即時值 | 各臂端箭頭長度 + RPM 環，飽和（100% 油門上限）時變色警示 |
| 馬達電流 | 3.6 馬達模型 | 過流警示（**溫度欄位移除**：現行模型無熱模型，顯示即違反 C-5 真值約束；待熱模型建模後再納入） |
| 風向量 | A7 穩態風 + A8 紊流合成，相對機頭方位 | 機體周圍箭頭 + 紊流強度脈動 |
| 風切 | A9 | 高度變化時風箭頭漸變 |
| 地面效應 | A4 增益值 | 機腹下方氣墊指示，強度隨 z/R |
| 尾流下洗 | A5 | 受上方尾流影響時之下壓指示 |
| Propwash | A6 擾動注入量 | 機體抖動指示 + 受影響軸高亮 |
| 機身阻力 | A3 三軸阻力向量 | 迎風面高亮 |
| 電池 | A10：電壓、sag、剩餘容量 | 電量條 + sag 即時壓降 |
| 姿態/飽和 | 飛控狀態 | PID 輸出飽和警示（例如某軸已無控制餘裕） |

**技術規格**：物理層以 30 Hz 降頻輸出 `TelemetrySnapshot`（雙緩衝交換，禁止 UI 直接輪詢子步進狀態或以 mutex 包物理狀態）。**Schema 凍結欄位**：timestamp（模擬時間，µs）、座標系（機體 FRD）、馬達順序（Betaflight 慣例 1–4）、每馬達 {推力 N、轉速 rad/s、電流 A、飽和 flag}、風向量（世界系 + 機體系 m/s）、紊流強度、地效增益、下洗力 N、propwash 擾動 rad/s²、三軸阻力 N、電池 {電壓 V、sag V、剩餘 mAh}、PID 三軸 {輸出、飽和 flag}、armed/mode、schema version。
**分期交付（同一 Must，兩階段）**：切片階段 = Debug 最小版（馬達推力/RPM、電壓 sag、armed/mode、風向量、PID 飽和）；GA 前 = A1–A10 全效應完整版 + Pause Overlay 完整面板。渲染成本量測改為**固定場景 on/off 差分，報 P95/P99，CPU/GPU 分列**（G4B.UI6c 依此判定）。

### 3.6 硬體參數系統（新增）

**原則：所有物理行為由「實務零件參數」驅動，玩家以組裝真機的心智模型設定機體；外界影響（風、氣壓、溫度、電量）作用於這些參數。**

#### 3.6.1 參數 Schema（JSON，玩家可編輯，內建預設組）

| 類別 | 參數 | 實務範例（5 吋 6S 花飛/競速預設組） |
|---|---|---|
| 機架 | 軸距、臂長、乾重、迎風面積(三軸) | 軸距 225 mm、乾重 420 g |
| 馬達 | 定子規格、KV、內阻、最大電流、τ_m | 2207 / 1860 KV / 6S |
| 螺旋槳 | 直徑×螺距×葉數、質量、**台架推力-扭矩-轉速-電流表** | 5.1×4.9×3（三葉）|
| 電池 | 串數、容量、C 值、單體內阻、放電曲線 | 6S / 1300 mAh / 100C / 內阻 3 mΩ/cell |
| ESC | 電流上限、協定與更新率 | 60 A / DShot600 等效 |
| 全機 | AUW（自動加總）、慣量矩陣、重心偏移 | AUW ≈ 680 g；Ixx≈Iyy≈2.5–4×10⁻³ kg·m²（5 吋級實務量級，**非** Iris 的 0.0291） |
| 感測 | IMU 噪音密度、偏置漂移、氣壓計噪音 | 依常見 FC 規格書 |
| FPV | 鏡頭 uptilt、FOV | 25° / 150° |

#### 3.6.2 派生量規則（不得手調，一律由參數計算）
- k_t、k_q：由螺旋槳台架表（推力/扭矩 vs 轉速）最小平方擬合。
- 懸停油門：由 AUW 與推力表解出，**5 吋 6S 預設組的懸停油門應落在 22–35% 區間**（實務合理性檢查）。
- TWR：滿油門總推力 / AUW，5 吋競速組應達 8:1 以上。
- 可用推力上限：隨電池電壓（sag 模型）即時折減。
- 慣量：由零件質量分布估算（提供 CAD 匯入或簡化桿-點模型），並可被實測值覆寫。

#### 3.6.3 雙基準機參數包（Phase 1 交付物）
1. **5 吋穿越機資料包（主打）**：台架推力表、慣量估測（雙線擺法或 CAD）、真機 Betaflight blackbox 飛行紀錄（含 step response 與典型 propwash 動作）、階躍響應標定之 τ_m。作為 G2.8 / G3 雙軌驗收之外部真值。
2. **Iris 級資料包**：沿用 PX4 iris.sdf 慣量（0.0291/0.0291/0.0552），供 Tier 3 與定高教學。

---

## 4. 開發階段與剛性驗收門檻

### 4.0 閘門總則 v2（回應審查 Critical 1 / 2）

1. **門檻數值剛性**：核准後凍結，任何人無權下修。未達標 → 修改 → 重測，循環直到通過；每次重測留存報告與差異分析。
2. **Gate 分類與證據要求**：

| Gate 類型 | 執行方式 | 通過證據 |
|---|---|---|
| CI-A（CI 自動化） | Linux headless / 原生單元測試，每次合併執行 | CI 紀錄 + 產物 |
| GPU-A（GPU 自動化） | 具 GPU 之 runner 或實機農場，夜間執行 | 跑分紀錄 + 截圖 |
| DEV-M（實機人工協定） | 標準化操作腳本 + 錄影/輸入紀錄 | 檢核表 + 錄影 + 簽核 |
| USR（使用者研究） | 標準問卷/計時協定，樣本數寫死於 Gate | 原始數據 + 統計 |
| LEG（法務/授權審查） | 法務書面核准 | 核准函 |

   可自動化者**必須**自動化（CI-A/GPU-A）；不可自動化者必須依協定留存證據與簽核。
3. **阻擋範圍（Blocking scope）**：每個 Gate 標註 SC（shared core，阻擋所有 Lane）或平台代號（僅阻擋該 Lane）。任一 SC Gate 未過，所有 Lane 停止進入下一 Phase；平台 Gate 未過僅凍結該 Lane。
4. **Phase 0 特例**：Phase 0 是 Spike，其結論**允許**重定平台範圍與 Profile 歸屬（例如將某效應移出 Mobile Base），但既定 Profile 內的門檻數值不得修改；重定範圍須全體核准人簽字並記入變更紀錄。Phase 1 起無此特例。
5. 豁免程序（預期使用次數為零）：書面技術論證 + 兩名外部飛手/工程師背書 + 全體核准人簽字。

**Gate 表格欄位**：Gate | 門檻 | 類型 | 範圍

---

### Phase 0 — 技術可行性驗證（Spike）

**目標**：證明 Godot 4.7 + Jolt + C++ GDExtension 撐得起各 Profile，並凍結 iOS Lane 決策。

**目前環境執行註記（2026-07-10）**：桌面實機驗收以本機 Ubuntu 26.04 LTS、AMD Ryzen 9 7945HX with Radeon Graphics、NVIDIA GeForce RTX 4060 Ti 為唯一基準。Android 與 iOS 是 build-only 車道：保留 export/build smoke、native tests、replay、資產與 renderer/profile 檢查；Android 保留 APK artifact/大小檢查，iOS 實際 Xcode build smoke 在有 macOS/Xcode runner 前為 **not verified**。沒有行動實機時，P99/FPS/Perfetto、OTG、MFi/VirtualJoystick、錄影、安裝、溫度、high-speed latency 與 crash-free 均為 **N/A**，不得標示為通過；這不豁免桌面或 shared-core 的數值、DEV-M、USR、LEG 門檻。

| Gate | 門檻 | 類型 | 範圍 |
|---|---|---|---|
| G0.1 | Desktop Full profile：物理（Jolt+GDExtension 子步進合計，主執行緒，vsync off，排除前 10 秒 warmup，模擬時間 60 秒）P99 每幀 ≤ 3 ms（凍結本機：Ubuntu 26.04、Ryzen 9 7945HX、RTX 4060 Ti） | GPU-A | SC |
| G0.2 | Mobile High 與 Mobile Base 兩 profile 於基準行動裝置：物理 P99 ≤ 5 ms 且整體 ≥ 60 FPS（量測定義同 G0.1；以 Perfetto 拆解物理/渲染占比）。目前無實機：**N/A，非 pass**；保留 build-only 檢查 | DEV-M→GPU-A | AND, iOS |
| G0.3 | 1000/500 Hz 子步進下四元數積分 10 分鐘無 NaN、範數漂移 < 1e-6 | CI-A | SC |
| G0.4 | 桌面/行動雙渲染管線同場景資產打通 | GPU-A | SC |
| G0.5 | RadioMaster USB joystick 於 Ubuntu desktop 識別 16 通道；Android OTG 目前 **N/A，非 pass** | DEV-M | LIN, AND |
| G0.6a | **共用核心決定性**：GDExtension 於 Win / Linux / Android（主線 Lane 平台）建置皆過同一組單元測試——同平台重播 bitwise 一致；跨平台物理量容忍：60 秒標準機動終端姿態差 ≤ 0.5°、位置差 ≤ 5 cm（統一 `-ffp-contract=off` 等旗標） | CI-A | SC |
| G0.6b | **逐 Lane 建置 smoke**：macOS 建置 + 同組測試（僅擋 MAC Lane）；iOS 建置 + 同組測試（僅擋 IOS Lane；目前無 macOS/Xcode runner，為 **not verified**） | CI-A | MAC / IOS |
| G0.7 | Linux headless 可無視窗執行完整物理模擬並輸出數據 | CI-A | SC |
| G0.8 | **碰撞權威切換**（回應 High 6）：四場景各 100 次隨機化重複——(a) 30 m/s 正撞牆、(b) 5° 掠角擦地、(c) 撞桿反彈、(d) 翻滾觸地後恢復。全數：無 NaN、速度/角速度有限、動能不增加（restitution 容忍 +1%）、交接後 0.5 秒內飛控可重新響應輸入、同種子重播結果一致 | CI-A | SC |
| G0.9 | **Fidelity 等價**：Mobile Base vs Desktop Full 同輸入序列（60 秒標準機動）姿態軌跡 RMSE ≤ 1.5°、位置 RMSE ≤ 15 cm（**僅擋行動 Lane**；Desktop 主線不受此 Gate 阻擋） | CI-A | AND, IOS |
| G0.P | **可玩垂直切片（Playable Slice，回應審查 C2）**：冷啟動 → 主選單 → Quick Fly → 預設機/預設圖（佔位美術可）→ spawn → 油門低位 → arm → 起飛 → pause → reset → exit 全流程可走通，於本機 Ubuntu desktop 以維護者操作、輸入 log + build hash 驗收；Android 實機部分目前 **N/A，非 pass**。**本 Gate 只驗操作性，不驗手感**（PID 粗調可）；此 Gate 未過，Phase 1 之後的深度物理工作不得超過團隊工時 20% | DEV-M | SC |
| G0.10 | iOS Lane 決策文件：Ad Hoc / TestFlight 路線之裝置數、審查風險、成本評估，做出 Go/No-Go 並簽核 | LEG | IOS |

---

### Phase 1 — 剛體動力學、馬達模型與硬體參數系統

| Gate | 門檻 | 類型 | 範圍 |
|---|---|---|---|
| G1.1 | 懸停推力：模擬懸停油門 vs 解析解偏差 ≤ 0.5% | CI-A | SC |
| G1.2 | 反扭力偏航穩態角加速度 vs 解析解偏差 ≤ 2% | CI-A | SC |
| G1.3 | 馬達一階響應 63.2% 時間 = τ_m ± 1 子步進 | CI-A | SC |
| G1.4 | 能量守恆：無阻力自由拋體 30 秒機械能漂移 < 0.1% | CI-A | SC |
| G1.5 | 電池模型：滿→空全油門，推力上限單調遞減，sag 曲線 vs 設定 R² ≥ 0.99 | CI-A | SC |
| G1.6 | 參數零硬編碼：機體常數靜態掃描 0 檢出 | CI-A | SC |
| G1.7 | **硬體參數系統**：3.6.1 Schema 全欄位可由 JSON 載入；**schema 含 version 欄、全欄位單位與座標系標註、馬達順序與旋向、槳表插值規則（範圍內線性、禁止外插——越界即拒絕）**；驗證器拒絕越界值 100% 攔截；載入失敗回退出廠預設並明示；熱切換機體不重啟場景 | CI-A | SC |
| G1.8 | **派生量實務合理性**：5 吋 6S 預設組——懸停油門落於 22–35%、TWR ≥ 8、預估懸停續航落於 3–6 分鐘區間 | CI-A | SC |
| G1.9 | **k_t/k_q 擬合**：由台架推力表擬合之 k_t、k_q 反推推力/扭矩，對表內各轉速點殘差 ≤ 3% | CI-A | SC |
| G1.10 | **5 吋機資料包交付**（3.6.3）：台架表、慣量估測、blackbox 紀錄齊備並入版控。**擷取協定（回應審查 H8）**：記錄韌體版本與濾波設定、盡可能取未濾波陀螺儀、時間對齊與重採樣方法文件化、記錄初始條件；**紀錄分為標定組（calibration）與保留組（holdout），兩組不同飛行架次，標定組僅用於調參** | DEV-M | SC |

---

### Phase 2 — 自研飛控

| Gate | 門檻 | 類型 | 範圍 |
|---|---|---|---|
| G2.1 | PID 迴圈實際頻率達 Profile 標稱值（P99 抖動 ≤ ±10%） | CI-A + DEV-M | SC |
| G2.2 | IMU 模擬含噪音/偏置/隨機游走/取樣延遲，皆可配置且測試覆蓋 | CI-A | SC |
| G2.3 | **Angle Mode 姿態保持（修正版）**：無風、姿態指令歸零後 60 秒，滾轉/俯仰角漂移 ≤ ±1°；**不設水平位置門檻**（無位置感測器之姿態模式物理上必然漂移） | CI-A | SC |
| G2.3b | （選配）Position Hold 模式**若實作**：須同時模擬 GPS/光流感測器（含噪音），60 秒水平漂移 ≤ ±50 cm | CI-A | SC |
| G2.4 | Angle Mode 30° 滾轉階躍：上升 ≤ 150 ms、超調 ≤ 10%、2% 穩定 ≤ 500 ms | CI-A | SC |
| G2.5 | Acro：720°/s 指令峰值角速度誤差 ≤ 5%；rates 曲線 vs Betaflight 同參數逐點誤差 ≤ 1% | CI-A | SC |
| G2.6 | Altitude Hold：氣壓計噪音開啟，60 秒高度漂移 ≤ ±15 cm | CI-A | SC |
| G2.7 | 手感盲測：≥5 名 Betaflight 實機飛手，Acro 盲測均分 ≥ 7.0 且無人 ≤ 4（問卷含真機 blackbox 回放錨定題） | USR | SC |
| G2.8 | **Blackbox 重播真值**：取 G1.10 真機紀錄之搖桿輸入重播入模擬器，陀螺儀三軸軌跡相關係數 ≥ 0.90、角速度 RMSE ≤ 真機峰值角速度之 8%。**判定一律以 holdout 組為準（標定組結果僅供參考），開迴路（模型辨識）與閉迴路（含飛控）重播分開報告** | CI-A | SC |
| G2.9 | **SITL 交叉驗證**：同輸入分別餵自研飛控與 Betaflight SITL（開發環境工具，不隨 Tier 1 發布），姿態響應趨勢相關係數 ≥ 0.85（此為自研飛控之健全性檢查，非等價承諾） | CI-A | SC |

---

### Phase 3 — 空氣動力學與氣象（雙軌驗收：公式殘差 + 實測殘差）

| Gate | 門檻 | 類型 | 範圍 |
|---|---|---|---|
| G3.1 | 阻力：等速前飛穩態俯仰/推力 vs Forster 解析 ≤ 5%；**且** C++ 移植版 vs gym-pybullet-drones Python 原版逐點 ≤ 1e-6 | CI-A | SC |
| G3.2 | 地面效應：z/R 5→1 增益曲線 vs Shi Eq.15 ≤ 5%；Python Oracle 逐點 ≤ 1e-6；低空懸停「氣墊」可觀測 | CI-A | SC |
| G3.3 | 下洗：雙機交錯升力衰減 vs DSL 模型 ≤ 10%；Python Oracle 逐點 ≤ 1e-6 | CI-A | SC |
| G3.4 | **Dryden（determinism 修正版）**：固定 seed、Welch 法（段長 2¹⁴、50% overlap、Hann 窗）估 PSD，0.1–10 rad/s 各 bin 與理論譜偏差 ≤ 10%（95% 信賴區間內），輕/中/重三檔；同 seed 重跑 bitwise 一致 | CI-A | SC |
| G3.5 | 風切剖面 vs 軍規模型逐點 ≤ 5% | CI-A | SC |
| G3.6 | Propwash 雙軌：(a) 機制測試——split-S 出彎擾動注入、強度與油門相關係數 ≥ 0.8、關閉時為 0；(b) **實測殘差**——重播 G1.10 之 propwash 動作 blackbox，擾動頻段（10–80 Hz）陀螺儀 PSD 能量比真機對應值落於 0.5–2.0 倍區間 | CI-A | SC |
| G3.7 | **效能預算（修正版）**：全效應開啟後，本機 Ubuntu 桌面物理 P99 相對 G0 基線增幅 ≤ 20%，且絕對值仍 ≤ 3 ms；行動各 profile 的 5 ms 實機條件目前 **N/A，非 pass** | GPU-A / DEV-M | DESK |
| G3.8 | 氣象盲測：飛手盲判無風/中紊流/強陣風，正確率 ≥ 80% | USR | SC |

---

### Phase 4 — 渲染、場景與遊戲性

| Gate | 門檻 | 類型 | 範圍 |
|---|---|---|---|
| G4.1 | 本機 Ubuntu 桌面（Ryzen 9 7945HX + RTX 4060 Ti）完整場景全效果 1080p ≥ 120 FPS（P99 ≥ 90） | GPU-A | DESK |
| G4.2 | 行動基準機同場景 ≥ 60 FPS（P99 ≥ 45），30 分鐘熱節流後 ≥ 50 FPS；目前無實機：**N/A，非 pass** | DEV-M | AND, IOS |
| G4.3 | **分期**：切片階段 ≥1 張 Free Flight 地圖 + reset-to-spawn + exit；**GA 前 ≥3 張完整地圖**（含 ≥1 條 Time Trial 路線：checkpoint 方向箭頭 + finish panel `Retry / Change Map / Exit`）+ 計時/檢查點/重生 QA 清單 100%；地圖卡含 3.5.4 規定資訊；場內方向指示可用 | DEV-M | SC |
| G4.4 | FPV 攝影機：uptilt/FOV/OSD；桌面含類比雜訊濾鏡 | GPU-A | SC |
| G4.5 | 雙渲染管線資產同源，人工分支 0 | CI-A | SC |

### Phase 4B — UI/UX

| Gate | 門檻 | 類型 | 範圍 |
|---|---|---|---|
| G4B.1 | 首次啟動至起飛 ≤ 90 秒（行動觸控 ≤ 60 秒），未接觸過產品之 FPV 玩家 ≥ 10 人，P90 | USR | SC |
| G4B.2 | 墜機→重飛 ≤ 1.5 秒（P99，重生鍵至油門可輸入） | GPU-A | SC |
| G4B.3 | 校準精靈無協助完成率 ≥ 90% | USR | DESK, AND |
| G4B.4 | SUS ≥ 75（≥10 人，含 ≥3 行動端） | USR | SC |
| G4B.5 | 選單深度 ≤ 3 層，自動遍歷驗證 | CI-A | SC |
| G4B.6 | Rates 介面與 Betaflight 曲線公式一致、即時預覽、JSON 與 Betaflight diff 可逐項核對；**PID/濾波顯示 sim profile 免責提示**（3.5.1 原則 2） | GPU-A | SC |
| G4B.7 | 觸控布局可自訂持久化，誤觸率 ≤ 1%/分鐘 | USR | AND, IOS |
| G4B.8 | 本地化 zh-TW/en 覆蓋 100%、0 硬編碼字串（CI）；**UI 截斷/溢出稽核於 GPU runner 截圖比對**（headless 不得宣稱涵蓋此項） | CI-A + GPU-A | SC |
| G4B.9 | UI 動效以 offset transforms 實作、layout 不變（自動斷言）、不阻塞輸入 > 100 ms | GPU-A | SC |
| G4B.UI1 | **First Fly Flow**：未看說明書之 FPV 玩家——已校準控制器 ≤ 30 秒起飛、未校準 ≤ 90 秒（含完成 Setup Flow）；無控制器時提示與 fallback 可用（樣本 ≥ 10 人，P90） | USR | SC |
| G4B.UI2 | **Controller Setup**：RadioMaster / FrSky 實機各一完成 3.5.4 全流程；**故意設置之軸反向與端點不足，UI 檢核必須 100% 主動偵測提示**（各 10 次注入測試） | DEV-M | DESK, AND |
| G4B.UI3 | **Pause Overlay**：固定項全數存在；rates/camera/OSD 修改即時生效不重載（自動斷言）；Reset 至可輸入 ≤ 1.5 秒（P99） | GPU-A | SC |
| G4B.UI4 | **OSD Presets**：三 preset 於 1080p 與行動橫向、zh-TW/en 四組合下，主飛行視野遮擋率 ≤ 8%，警告訊息不遮擋畫面中央 1/3（自動截圖幾何稽核） | GPU-A | SC |
| G4B.UI5 | **選擇流程**：Quick Fly 一鍵進預設場；選機/選圖/選模式/選風況/起飛於單層畫面完成，全流程確認次數 ≤ 3 | GPU-A + USR | SC |
| G4B.UI6 | **機體狀態圖**：(a) 真值一致——狀態圖各數值 vs 物理層遙測快照逐項相等（容忍僅顯示取整），A1–A10 任一效應關閉時對應指示歸零（自動化逐效應開關測試）；(b) 更新率 ≥ 30 Hz、資料延遲 ≤ 100 ms；(c) 完整版與迷你版渲染成本合計 ≤ 0.5 ms/幀（各平台 Profile）；(d) 迷你版於 Debug OSD 下不違反 G4B.UI4 遮擋門檻 | CI-A + GPU-A | SC |

---

### Phase 5 — 輸入裝置與延遲

| Gate | 門檻 | 類型 | 範圍 |
|---|---|---|---|
| G5.1 | **逐 OS 控制器閘門**：Windows / macOS / Linux 各自——radio 實機（RadioMaster、FrSky 至少各一）+ 通用 gamepad 一款，完成 16 通道映射 + 反向 + 端點校準（依校準合約判定）+ 斷線重連；**任一 OS 未過僅凍結該 OS Lane** | DEV-M | WIN / MAC / LIN |
| G5.2 | Android OTG joystick 同 G5.1；目前無實機：**N/A，非 pass** | DEV-M | AND |
| G5.3 | iOS（若 Lane 續行）：MFi（SDL3 路徑）+ VirtualJoystick（Fixed/Dynamic 雙模式）可完成 G2.3 姿態保持測試；目前無實機：**N/A，非 pass** | DEV-M | IOS |
| G5.4 | 端到端延遲（搖桿電氣訊號→畫面，240fps+ 高速攝影）：桌面 ≤ 40 ms；行動 ≤ 60 ms 的實機條件目前 **N/A，非 pass** | DEV-M | 各 Lane |
| G5.5 | 輸入映射匯出/匯入、斷線重連不丟設定（校準/映射跨 session 持久化，見範圍排除之界線釐清） | CI-A | SC |
| G5.6 | **Channel Monitor 一等 UI**：16 通道 live bar / raw / normalized / deadzone / 中心 / 端點全數即時顯示，更新率 ≥ 30 Hz；自動檢核四項提示（油門低位、arm 映射、mode 映射、軸重複）功能驗證 | GPU-A + DEV-M | SC |
| G5.7 | **斷線 fail loud**：飛行中拔除控制器 → 500 ms 內畫面警示 + 顯示重連狀態；重插後 ≤ 2 秒恢復輸入且校準不丟失（各 20 次） | DEV-M | 各 Lane |

---

### Phase 6 — 私下發行與部署（取代商店合規）

| Gate | 門檻 | 類型 | 範圍 |
|---|---|---|---|
| G6.1 | Win/macOS/Linux 安裝包 ≤ 300 MB | CI-A | DESK |
| G6.2 | Android APK ≤ 300 MB，側載安裝流程文件化（含簽章與未知來源指引）；APK artifact/大小保留，實機側載目前 **N/A，非 pass** | CI-A + DEV-M | AND |
| G6.3 | 授權掃描：Tier 1 產物 0 GPL/LGPL/AGPL；NOTICE 自動生成 | CI-A | SC |
| G6.4 | 冷啟動至可飛：桌面 ≤ 15 秒；行動 ≤ 20 秒的實機條件目前 **N/A，非 pass** | GPU-A / DEV-M | 各 Lane |
| G6.5 | 封測 7 日 crash-free session ≥ 99.5%（遙測須 opt-in，私下發行仍須隱私告知文件）；行動實機部分目前 **N/A，非 pass** | DEV-M | 各 Lane |
| G6.6 | **授權伺服器**：註冊→簽發→JWT 驗證全流程可用；離線寬限期機制（斷網 ≤ 72 小時可玩）；伺服器不可達時明確提示而非靜默鎖死 | CI-A + DEV-M | SC |
| G6.7 | 交付流程演練：從客戶名單到發送安裝檔+授權金鑰之 SOP 全程演練一次成功，含撤銷授權 | DEV-M | SC |
| G6.8 | **診斷支援包（回應審查 H10）**：`Settings > Diagnostics > Export Support Bundle` 一鍵匯出——build hash、OS/GPU/裝置資訊、授權狀態、近期 log、控制器 raw 取樣、輸入映射與校準、最後錯誤；**自動化稽核：bundle 內 0 個 secrets / JWT / 個資（遮罩驗證）** | CI-A + DEV-M | SC |
| G6.9 | **設定持久化表（回應審查 H9）**：Persistent（校準/映射/rates/OSD 配置/相機/觸控布局/語言/畫質）與 Volatile（本局 spawn/臨時風況/當場計時與遙測）逐項落地一致；settings schema 含 version；factory reset 可用；匯入失敗回退預設並明示 | CI-A | SC |

---

### Phase 7 —（桌面限定）Betaflight SITL 專業模組

| Gate | 門檻 | 類型 | 範圍 |
|---|---|---|---|
| G7.1 | **法務核准（前置，未過不得開發發布物）**：無共享記憶體、無動態/靜態連結、協定文件公開、GPL binary/source/build script 一一對應、**每次私下交付同步履行原始碼義務**之交付清單，經法務書面核准 | LEG | T2 |
| G7.2 | Configurator 連線：以**外部獨立工具**方式開啟（不嵌入專有主程式 UI），WebSocket proxy 屬 GPL 隔離區 | DEV-M + LEG | T2 |
| G7.3 | SITL 模式端到端延遲增加 ≤ 10 ms | DEV-M | T2 |
| G7.4 | Blackbox 匯出可被 Blackbox Explorer 解析 | CI-A | T2 |
| G7.5 | **Fail loud（修正版）**：SITL 崩潰→立即暫停本次飛行、全螢幕提示「SITL 不可用」、blackbox 標記中止；僅允許回主選單或以 Tier 1 飛控開新局（UI 明確顯示目前飛控來源）。**禁止靜默回退** | CI-A（故障注入） | T2 |

---

## 5. 驗收方法學

0. **CI 平台範圍（修正版）**：Linux headless 僅承擔——數值模擬、頻譜分析、GDExtension 單元測試、資產載入 smoke、選單樹遍歷。渲染/截圖/UI 視覺/效能類 Gate 一律 GPU runner 或實機（DEV-M/GPU-A）。Web 不列入任何目標。
1. 測試報告：每 Gate 一份，含環境、版本雜湊、原始數據、判定；未過附根因與修改計畫。
2. 重測循環：修改 → 該 Phase 全 Gate 回歸 → 報告。
3. 基準機凍結：桌面為本機 Ubuntu 26.04 LTS、Ryzen 9 7945HX + RTX 4060 Ti（driver 580.159.03）。Android/iOS 維持 build-only，沒有實機時不建立替代行動基準，也不得把 N/A 寫成通過。
4. 盲測規範：受測者不知修改內容；問卷含真機 blackbox 回放錨定題。
5. 版本鎖定：Godot 4.7 之 patch 版本與 export template hash 記錄於 repo；引擎升級觸發 G0–G3 全量重跑。

## 6. 風險登記簿（節錄）

| 風險 | 影響 | 緩解 |
|---|---|---|
| Mobile Base profile 仍超預算 | G0.2 | Phase 0 特例程序重定行動 Lane 範圍（總則 4.0-4），門檻數值不動 |
| iOS 私下發行法律路徑受限 | G0.10 | Phase 0 完成 Go/No-Go；No-Go 則 iOS Lane 關閉，資源轉桌面/Android |
| GPL 語意耦合疑慮 | G7.1 | 法務前置核准；協定文件公開；Configurator 外置 |
| 台架推力表數據取得 | G1.10 | 優先使用公開馬達台架數據庫；必要時自購測試台實測 |
| Shi/Forster 參數為 Crazyflie 尺度 | G3.1–G3.3 | 公式結構不變、以 5 吋機資料包重擬合係數（Phase 1 交付） |
| 引擎升級破壞物理 | 全部 | 版本鎖定 + 升級即 G0–G3 全量重跑 |

## 7. 參考開源方案索引

| 專案 | 用途 | 授權 |
|---|---|---|
| Godot 4.7（鎖版）、godot-cpp | 引擎 / 飛控核心 | MIT |
| gym-pybullet-drones | 氣動公式 + CI Python Oracle | MIT |
| Betaflight（SITL） | Tier 2 真韌體；Phase 2 交叉驗證工具 | GPL-3.0（隔離） |
| PX4 SIH | Tier 3 | BSD 3-Clause |
| SimITL / KwadSim / pr0p 文獻 | 雙模擬子步進架構參考 | 參考 |
| MIL-F-8785C / MIL-HDBK-1797 | Dryden / 風切 | 公開標準 |
| Flowstate | 開源 UX 參考（HUD） | 開源 |
