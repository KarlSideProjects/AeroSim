# 產品需求文件 (PRD) — Project AeroSim
## AirSim-class 多旋翼模擬平台與遊戲化飛行體驗

| 文件屬性 | 內容 |
|---|---|
| 版本 | v4.1.8（AirSim-class minimum；2026-07-24 UI/UX 成品標準與 Android lane 決策同步） |
| 文件狀態 | 產品邊界已核准；GitHub issue 同步中 |
| 發行模式 | **私下提供（Private Distribution）**，不上架 Google Play / App Store / Steam |
| 開發模式 | 階段閘門制（Phase-Gate）：**門檻數值為剛性要求，核准後凍結、不得下修；未達標即退回修改，循環直到通過** |

### 變更紀錄
- v4.1.8：確認第一版 UI/UX 標準由 CAP-006/G4.6 的完整可玩成品承擔；G2.9 僅保留為未來 Betaflight 開發對照，不作 UI/UX 或 Ubuntu qualification 門檻。
- v4.1.7：Android Player Mode 本期 deferred，不產生、不簽章、不驗收 Android APK 或側載；保留未來可獨立重啟的 Android lane，且不阻擋 Ubuntu minimum。
- v4.1.5：凍結 v1 輸入映射（不提供玩家重綁）；Industrial Test Range 改以 descriptor 的正式 `SpawnNorth`／`SpawnSouth` 清單循環出生；Keyboard `R`／Xbox `X` 只做 Reset，Xbox `START+X` 才做 Change Spawn，且永不作 Arm/Takeoff；新增 GPU-A Reset/Respawn P99 專用 gate，分別量測 plain X 與 Pause Overlay Reset，各至少 200 次並以 armed、pause off、非零 throttle 已被 physics/control telemetry 接受為終點。
- v4.1.6：依產品決策移除專用 GPU-A Reset/Respawn 測試與其阻擋門檻；Reset／Change Spawn 改由 GUT 與 headed functional checks 驗證。
- v4.1.4：Xbox A 的 Arm/Takeoff 必須以目前機體 hover throttle 加受控起飛輔助升至約 1 m，再交回玩家油門；不得使用一次性跳躍速度，X 僅保留 Reset 行為。
- v4.1.3：HUD 輸入提示必須跟隨目前 active input profile；Xbox profile 顯示 A／START／X／RB／Y／B，KeyboardProfile 才顯示 T／P／R／C／H／Esc，禁止同時使用錯誤裝置提示。
- v4.1.2：開發用 debug build 的 Quick Fly 不要求授權金鑰；正式／release build 仍必須遵守授權驗證與離線寬限規則。
- v4.1.1：新增 UI overlay 不重疊、響應式布局與初始 telemetry 尚未就緒時的可讀狀態規範；以人工截圖發現的主選單、Operations Dashboard、Debug API 面板擠壓問題作為本次修正依據。
- v4.1：新增 Playable Game Milestone、延後人工審核至完整可玩後、固定外部 AirSim v1.8.1 reference checkout 與上游 open/closed issue 稽核，並固定 Codex Luna high 實作及 Sol high 疑難顧問規則。
- v4.0：產品改為多旋翼模擬平台優先，新增 Player Mode／Lab Mode、AirSim 1.8.1 相容面、PX4 SITL、雙機、基準感測器、Operations Dashboard、Dataset Recording、單一 Industrial Test Range、Godot-native GLB pipeline、Codex AI 視覺 gate 與 Ubuntu x86_64 完整資格驗證；GA 三地圖改為一張正式地圖，主選單改為七入口。
- v3.2：接受 v3.1 審查 C1–C4、H1–H4、H7–H10；H5 改分期不降級（3 張地圖仍為 GA Must）；H6 分期交付並移除溫度欄位（無熱模型即無真值）；新增已知物理近似邊界聲明。
- v3.1：接受 v3.0 對抗式審查之操作 UI/UX 發現；新增機體狀態圖需求；明文界定「不做存檔」之範圍。
- v3.0：接受對抗式審查報告之 Critical 1–4、High 5–8 及多數附加發現；新增第 3.6 章硬體參數系統；發行模式改為私下提供；修正 G2.3（Angle Mode ≠ 位置保持）、G0.6（跨平台浮點容忍）。
- v2.2：新增 UI/UX 章節與 Phase 4B。
- v2.1：Godot 4.7、C++ GDExtension、Linux headless CI。

---

## 0. v4.1 規範優先序與最低成果

### 0.1 規範優先序

1. 本 PRD 定義產品成果、範圍與 release gate。
2. [`docs/product_capabilities.md`](docs/product_capabilities.md) 是功能與特性的逐項正本，記錄能力 ID、目前狀態與最低驗收證據。
3. [`CONTEXT.md`](CONTEXT.md) 定義領域語言；`docs/adr/` 記錄架構層不可逆或具取捨的決策，驗收與產品範圍裁定則以 `docs/decisions/` 及其 decision flow 為準。
4. 本文件後段保留的 v3.x 物理、飛控、輸入、授權與發行 gate，在不衝突時繼續有效；任何衝突一律以 v4.1 與能力正本為準。

### 0.2 AirSim-class minimum 定義

AirSim-class minimum 不是外觀仿製。AeroSim 必須在同一 Godot 產品內同時交付：

| 能力群 | 必備成果 | 能力 ID |
|---|---|---|
| 產品入口 | Player Mode、Lab Mode、Quick Fly、Map Catalog、七入口主選單、完整可玩里程碑 | CAP-001–006 |
| 相容與控制 | `airsim==1.8.1` 凍結子集、PX4 SITL、雙機、NED/FRD/SI、local-only RPC、完整飛行指令面、經 issue 稽核的 AirSim reference | CAP-010–017 |
| 感測與觀測 | RGB、DepthPlanar、Segmentation、IMU、GPS、magnetometer、barometer、LiDAR、Operations Dashboard、simulation-time 取樣 | CAP-020–023 |
| 世界與場景 | 一張 Industrial Test Range、Godot-native glTF/GLB pipeline、Codex 視覺驗證、catalog objects、風雨霧與日照、自製雙機外觀 | CAP-030–036 |
| 證據與資料 | deterministic Flight Replay、雙機同步 Dataset Recording、可攜 dataset package | CAP-040–042 |
| 發行資格 | Ubuntu x86_64 完整 qualification、指定 runner 效能 gate、本機低規格不阻擋 | CAP-050–051 |

上述 Confirmed target 全部轉為 Available，才可宣稱達到 AirSim-class minimum。只有物理單元測試、AirSim 風格 UI、可載入的灰盒場景或單張截圖都不構成完成。

### 0.3 明確不包含

- 汽車、道路交通與 `CarClient`。
- AirSim 全 API、浮動最新版相容或任意外部模型匯入。
- Unity UI／Unreal UMG、Blueprint、C++ 或 packaged `.pak` 自動轉換。
- 三張 GA 地圖；第一版只有一張正式 Industrial Test Range，但保留 Map Catalog UI。
- ArduPilot SITL、HITL、逐馬達 PWM、遠端 RPC、ROS bag、Parquet、資料庫。
- `DepthVis`、disparity、surface normals、infrared、object detection、optical flow、distance sensor。

### 0.4 開發參考、Agent 與人工審核順序

- Microsoft AirSim 參考庫放在 AeroSim **主 checkout root** 外的 sibling `../AirSim-reference`，固定 tag `v1.8.1`、commit `96235148a332fe7cb3d3525a0720e26faaca99e0`，只讀使用且不得成為 build/runtime/scene dependency；linked worktree 必須由 `git rev-parse --git-common-dir` 的 parent 解析該路徑。
- 引用或改寫 AirSim path、symbol、setting、protocol behavior 或 fixture 前，必須依 `docs/airsim_reference_policy.md` 搜尋相關 open 與 closed upstream issues，並在實作 issue／PR 留下 query、URL、適用性、授權與導出測試。
- Codex 專案實作預設 `gpt-5.6-luna` high；只有具體、有限、模糊或高風險的問題可交給 read-only `gpt-5.6-sol` high 顧問，最後決策與驗證仍由主 Agent 負責。模型不可用時必須揭露，不得靜默冒稱。
- CAP-006 前不要求人工視覺、UI 或可玩性審核；deterministic gates 與 Codex AI Visual Verification 仍持續產生 provisional evidence。Ubuntu packaged game 通過完整可玩流程後，才開始第一次人工完整遊玩與 Approved Visual Reference 核准。

### 範圍排除（Must-Not，避免範圍蔓延）
以下**不列入**本產品需求：玩家進度/成就存檔、訓練課程系統、自動更新/回滾/簽章驗證、線上幽靈/排行榜/UGC 分享。

**界線釐清**：「不做存檔」指玩家進度資料。**裝置與設定持久化（已確認的手把映射、rates、OSD preset 選擇）屬系統設定，必須跨 session 保留**。觸控布局需要完整的虛擬 Xbox 輸入契約，目前沒有可直接使用的 Godot 內建功能或外掛，故延後，不列入本期 settings domain。單場飛行內的暫態（當場 spawn 點、當場風況選擇）為 volatile，不持久化。

---

## 1. 專案概述

### 1.1 產品定位
多旋翼模擬平台優先、遊戲化入口預設。Player Mode 提供可直接遊玩的飛行迴圈；Lab Mode 讓既有 AirSim 1.8.1 Python client、PX4 SITL 與資料工作流控制同一世界。硬核物理、真實飛控手感與私下授權交付仍保留，但不再單獨定義產品完成。

### 1.2 核心目標
1. 交付一個可玩且可程式控制的共同模擬世界；任何功能不得只存在測試 harness 或 UI 假資料。
2. 物理擬真：推力/反扭力、阻力、地面效應、尾流下洗、Propwash、穩態風 + Dryden 紊流 + 風切。
3. 擬真的根基是**實務硬體參數**（第 3.6 章）：馬達/槳/電池/機架皆以真實產品規格與台架實測數據建模，外界影響作用於這些參數而非抽象數值。
4. 既有 AirSim client 在凍結相容面內不修改即可使用；相容面外明確失敗。
5. 100% 可閉源商用：Tier 1 僅用 MIT/BSD/Zlib/Apache-2.0 依賴；GPL 元件（Betaflight）維持隔離且不阻擋 minimum。
6. 支援 Xbox 360 相容 gamepad 進行 Player Mode 飛行；真實 RC 遙控器不是 v4.1 minimum，未來若有需求以獨立 Profile 回補。

### 1.3 產品分層

| 層級 | 平台 | 飛控 | 授權狀態 |
|---|---|---|---|
| **AirSim-class minimum** | Ubuntu x86_64 | 自研飛控 + PX4 SITL、Player Mode + Lab Mode | 全部阻擋 Ubuntu qualification |
| **Player Mode lanes** | Windows；Android（future lane） | 自研高頻 PID 飛控 | Windows 可獨立交付；Android 本期 deferred，均不阻擋 Ubuntu minimum |
| **Deferred professional module** | 桌面 | Betaflight SITL 獨立行程橋接 | GPL-3.0，隔離發布，須法務核准 |

> **本期 lane 狀態**：所有 Android／`AND` 專屬 gate 本期均為 **deferred / not run / not pass**；只有明確重啟 Android lane 後才恢復。這些 gate 不得阻擋 Ubuntu qualification；Ubuntu／`LIN` 與 shared-core gate 仍依各自門檻驗收。

### 1.4 發布通道

Ubuntu x86_64 是唯一必須同時通過 Player Mode、Lab Mode、PX4、RPC、感測器、Dataset、場景與視覺 gate 的 Qualification Platform。其他 Lane 不得阻擋它。

| Lane | 發行方式 | 狀態 |
|---|---|---|
| Ubuntu AirSim-class | 私下提供安裝包 + 授權啟用 | 唯一完整 qualification，阻擋 minimum |
| Windows Player Mode | 私下提供桌面包 | 非阻擋，可獨立發布 |
| Android Player Mode | 本期不承諾交付；保留未來 lane | **Deferred**：本期不產生、不簽章、不驗收；重啟 Android lane 後才恢復驗收 |
| macOS / iOS | 未承諾 | Deferred |
| Betaflight module | 桌面獨立安裝 | Deferred，須法務核准 |

> **剛性約束 C-1**：iOS 禁止 spawn subprocess，任何 GPL 韌體嵌入即構成傳染。Betaflight module 永久禁止進入 iOS / Android。
> **剛性約束 C-2**：Tier 1 依賴授權不屬 MIT/BSD/Zlib/Apache-2.0/公有領域者不得合入；CI 授權掃描違規即 build fail。
> **剛性約束 C-3**：**私下提供仍構成 GPL 意義上的散布**。Deferred Betaflight module 每次交付客戶，皆須同步履行 GPL-3.0 原始碼義務（見 G7.1）。

---

## 2. 技術選型與授權矩陣

| 模組 | 選型 | 授權 | 商用風險 |
|---|---|---|---|
| 遊戲引擎 | **Godot 4.7（版本鎖定：專案凍結至特定 patch 版與 export template hash，記錄於 repo；引擎升級須重跑 G0–G3 全部 Gate）** | MIT | 無 |
| 物理引擎 | Jolt Physics（Godot 4.6+ 預設） | MIT | 無 |
| 飛控核心語言 | C++ GDExtension（1kHz PID、六自由度積分、氣動模型、硬體參數模型皆在此層）。C# 於 iOS/Android 屬實驗性、Web 不支援，故不採用 | MIT（godot-cpp） | 無 |
| 桌面渲染 | Forward+（Vulkan）優先；Godot RenderingDevice backend 不可用時 fallback 至 Compatibility（OpenGL 3） | MIT | 無 |
| 行動渲染 | Mobile Renderer + LightmapGI 烘焙光照 | MIT | 無 |
| 行動觸控輸入 | 本期 deferred；Godot 4.7 的 VirtualJoystick／TouchScreenButton 僅作未來 semantic-action adapter 的 primitives，不視為 Xbox 虛擬手把；實體 iOS 控制器仍走 SDL3 | MIT | 無 |
| 氣動公式來源 | gym-pybullet-drones 之 drag / ground effect / downwash（移植公式並以其 Python 原版為 CI 數值 Oracle） | MIT | 無 |
| 風場 / 紊流 | Dryden（MIL-F-8785C）+ 穩態風 + 風切，自研 C++ 實作 | 公開軍規標準 | 無 |
| 自研飛控 | C++ 串級 PID（角速度內環 + 角度外環）+ 互補濾波 / Mahony | 自有 | 無 |
| Minimum 外部飛控 | PX4 SITL（鎖版、Ubuntu、MAVLink） | BSD 3-Clause | AirSim-class 必備 |
| Deferred 飛控 | Betaflight SITL（獨立行程、UDP、無共享記憶體、無連結） | **GPL-3.0** | **發布前須法務核准** |
| Lab Mode RPC | AirSim 1.8.1 msgpack-rpc 相容子集，loopback only | MIT 相容實作 | 不得暴露非 loopback |
| 場景資產 | Kenney City Kit (Industrial) + 自製 Godot 資產 | CC0 / 自有 | 來源、hash、license 入版控 |
| 相容實作參考 | Microsoft AirSim `v1.8.1` @ `96235148…` 外部只讀 checkout | MIT | 每次引用先稽核 open/closed issues；不得成為依賴 |
| 授權伺服器 | 自建 FastAPI + JWT（複用既有架構模式） | 自有 | 無 |

**渲染相容性政策**：產品不要求特定 GPU 型號、品牌或獨立顯卡。桌面啟動先使用 Forward+；若目標平台的 Godot RenderingDevice backend 不可用，允許 Godot fallback 至 Compatibility renderer，並接受進階光照/霧效等視覺功能降低。Reference Performance Profile 的硬體只用於可重現的效能基準，不是安裝、啟動或功能相容性的必要條件。啟動後的 shader/driver hang 仍須另行 fail loud，不以 fallback 宣稱已解決。

---

## 3. 核心技術架構

### 3.1 雙迴圈子步進架構

```
┌────────────────────────────┐        ┌─────────────────────────────┐
│  Player/Lab (Godot/GDScript) │        │  飛控核心 (C++ GDExtension    │
│  · 渲染 60–120 FPS          │        │   / Tier2: SITL 獨立行程)     │
│  · Jolt 碰撞 / 剛體 240 Hz   │◄──────►│  · PID 迴圈（見平台 Profile）  │
│  · 場景 / Dashboard / RPC     │  狀態   │  · IMU 模擬(噪音/漂移/延遲)    │
│  每 physics tick 觸發        │  交換   │  · 馬達/電池/槳 硬體參數模型    │
│  N 次飛控子步進              │        │  · 自由空間六自由度積分         │
└────────────────────────────┘        └─────────────────────────────┘
```

- 語言分層：飛控核心 + 氣動 + 風場 + 硬體參數模型 = C++ GDExtension；遊戲邏輯/UI/關卡 = GDScript。禁止在 GDScript 實作逐子步進物理。
- 自研飛控同行程零 IPC 延遲；PX4 SITL 經鎖定的 MAVLink bridge 接入相同 Vehicle Instance 契約。Godot Y-up 只存在內部，所有外部 API、PX4、Replay 與 Dataset 使用 NED world、FRD body、SI units。

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
| A6 | Propwash | 大姿態變化穿越自身尾流之角速度擾動注入 | 自研機制 + Python Oracle／SITL 趨勢交叉驗證（G3.6） |
| A7 | 穩態風 | 3D 向量場，場景可配置 | 自研 |
| A8 | 紊流 | Dryden 成形濾波器，輕/中/重軍規參數 | MIL-F-8785C |
| A9 | 風切 | 風速隨高度剖面 | MIL-F-8785C |
| A10 | 電池-推力耦合 | 電壓 sag → 可用推力上限（由 3.6 電池參數驅動） | SimITL 思路 |

> **已知物理近似邊界（誠實聲明，隨產品文件揭露）**：本產品為剛體動力學 + 參數化氣動模型，非 CFD。未建模現象：渦環狀態（VRS，垂直快速下降穿越自身下洗）、槳葉柔性與失速、精細紊流-機體交互。A6 propwash 為自研近似項，以 G3.6 的機制注入與油門相關性界定目前驗收範圍；真機頻段能量比暫不作門檻。

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
| 首次上手 | Velocidrone 控制器確認流程 | 裝置偵測 → 固定映射確認 → 直入練習場 |
| 行動觸控布局 | FPV Freerider | Future reference only；本期不實作 |
| 極簡 HUD | Flowstate（開源） | FPV 眼鏡視角 OSD |

#### 3.5.3 資訊架構剛性約束
- 常用功能（起飛、換機體、換地圖、調 rates、重播）距主選單 ≤ 3 層。
- 「飛行手感」與「系統設定」兩棵獨立樹。
- 調參支援 JSON 匯出/匯入、恢復預設、即時生效。
- 本地化 zh-TW / en，字串全部外部化。

#### 3.5.4 人機操作 UI/UX（Human-Drone Operation，回應 v3.0 審查）

**主選單第一層固定七入口**：`Quick Fly`、`Lab Mode`、`Controller`、`Drone`、`Map`、`Settings`、`Quit`。
- `Quick Fly`：預設機體 + 預設地圖 + 無風直接進場；開發用 debug build 不要求授權金鑰，正式／release build 仍執行授權 gate；若相容手把尚未確認固定映射，先導入 Controller Setup 而非帶著失控狀態進場。
- 飛行 HUD 的操作提示必須依 active input profile 顯示實際可用裝置按鈕；Xbox profile 不得顯示 T／P 等鍵盤提示，Keyboard fallback 才顯示鍵盤提示。
- Xbox profile 的 A 必須執行解鎖／受控起飛：使用目前硬體設定的 hover throttle 加小幅起飛裕度，升至約 1 m 後交回右側油門桿；不得以瞬間向上速度模擬跳躍。X 僅執行 Reset，不得觸發起飛。
- `Lab Mode`：進入完整 Operations Dashboard，顯示雙機、RPC、PX4、感測器、錄製與環境狀態。
- `Map`：最低成果仍保留選擇畫面，但 catalog 只有 `Industrial Test Range`，不得顯示假地圖或 Coming Soon 卡片。
- `Quit`：Ubuntu desktop 可由 UI 正常退出，不依賴開發者快捷鍵。
- 無任何控制器時，UI 明確提示需要 Xbox 360 相容 gamepad，並提供鍵盤 fallback 模式（明示非擬真操控）。

**Controller Setup Flow（固定映射確認）**：偵測 Xbox 360 相容手把（Godot SDL mapping）→ 顯示固定映射與四軸即時值 → 玩家確認 → 建立含 schema version 的 `GamepadProfile` → 油門低位與 arm / mode preflight。

**固定映射確認合約（回應審查 C3）**——全數通過才建立 session profile，任一未過即擋進場並標示原因：
- 僅接受 Xbox 360 相容手把，SDL mapping 必須存在。
- 固定四軸映射與固定 deadzone（版本化具名常數，實作定值 raw 0.08）。
- Arm / Mode 預設鍵不得重複，按下與放開狀態可辨識，去抖 ≤ 50 ms。
- 油門低位檢查通過為 arm 之前置條件（未低位不得 arm，preflight 面板同步阻擋）。
- unknown 裝置 100% 擋下並提示 keyboard fallback（注入測試判定）。

**兩種輸入 Profile（回應審查 H4，Channel Monitor 依 Profile 呈現）**：
- `GamepadProfile`：固定映射軸/鍵、raw / normalized / 固定 deadzone、按鍵狀態、sticky throttle 模式（油門不回中語意）、UI 明示「非擬真操控」。
- `KeyboardProfile`：離散輸入，僅保證可起飛/暫停/重生/退出，明示限制用途。

**操作 Action Contract（回應審查 H2）**：pause / reset / change spawn / exit / arm / mode 於兩種 Profile 各有固定、版本化的 canonical 映射與畫面 glyph；v1 不提供玩家重綁，避免 session-only 映射造成重連或跨 session 歧義。Keyboard 固定為 `P` Pause、`R` Reset、`Shift+R` Change Spawn、`Esc` Exit、`T` Arm/Takeoff、`C` Mode；Xbox 固定為 `START` Pause、`X` Reset、`START+X` Change Spawn、`B` Exit、`A` Arm/Takeoff、`Y` Mode。`START+X` 是獨立 Change Spawn chord，不得觸發 Arm/Takeoff；**所有飛行中救援動作（reset/pause）必須「手不離主控制器」可達**。

**Quick Fly 狀態機（回應審查 H1）**：

| 進入時狀態 | 出口 |
|---|---|
| 已確認固定映射的相容手把 | → 直接進場 |
| 未確認固定映射 | → Controller Setup（完成→進場；取消→主選單） |
| 無控制器或 unknown 裝置 | → 提示 + Keyboard fallback 或返回 |
| 授權不可達 / 離線寬限過期 | → 明確錯誤畫面：Retry / Diagnostics / Exit（禁止靜默鎖死，見 G6.6） |
| 地圖/機體 JSON 載入失敗 | → 錯誤明示 + 回退出廠預設（factory default）選項 |

**Pause / Reset / Spawn 語意（回應審查 H3，凍結為規格）**：
- Pause：凍結物理與計時器，輸入監控持續（Channel Monitor 可用）。
- Reset：回 spawn 姿態、清空線/角速度、清 PID 積分項、清碰撞狀態、當段遙測標記分段；**保持 armed、油門即時跟隨搖桿**（沿用競速模擬器慣例）；Time Trial 下計時與 checkpoint 歸零。
- Change Spawn：結束本段（計時/checkpoint 清空），依地圖 descriptor 的正式 spawn 清單循環到下一個 Marker3D，於新 spawn 依 Reset 語意重生；Industrial Test Range v1 固定提供 `SpawnNorth` 與 `SpawnSouth`。

**Channel Monitor 為一等 UI**（依上述 Profile 分規格呈現）。飛行中控制器斷線：fail loud——畫面即時警示 + 顯示重連狀態，禁止靜默失控。

**飛行中 Pause Overlay（固定項）**：`Resume`、`Reset`、`Change Spawn`、`Rates`、`Camera`、`OSD`、`Controller Monitor`、`Status Diagram`、`Exit`。Rates / camera / OSD 修改即時生效，不重載場景。

**OSD Preset（內建三組）**：`Minimal`、`Race`、`Debug`。元件：電壓/電量（含 sag 即時值）、armed 狀態、flight mode、計時、lap/checkpoint、訊號狀態、警告訊息、reset 提示。OSD 編輯僅做元件開關與位置拖曳，不做字型/皮膚系統。

**Drone 選擇（簡化 Workbench）**：第一層僅顯示 preset 卡片（`5" Freestyle`、`5" Race`、`Iris Trainer`），preset 內可調：camera angle、FOV、rates、槳型（若支援）。Advanced 分頁才暴露 3.6 原始參數與 JSON 匯入/匯出。

**Map 選擇**：地圖卡顯示——類型（競速/花飛/闖關）、建議機體、風況 preset、spawn 數、模式（Free Flight / Time Trial）。同畫面完成選圖 + 選模式 + 選風況 + 起飛。場內提供方向指示、reset-to-spawn。

**首飛輔助（非課程）**：首次進場顯示小型 preflight 面板（`Throttle low` / `Arm` / `Mode` / `Reset` 四狀態燈），起飛後自動隱藏，可於設定停用。無教學文字、無進度保存。

#### 3.5.5 螢幕布局與 Overlay Collision Contract（新增）

**剛性約束：所有同時可見的 UI surface 必須可讀、可操作且互不重疊。** 主選單、Operations Dashboard、Debug API 氣動面板、飛行 HUD、Pause Overlay 與錯誤提示必須各自使用保留的 Control 區域；不得以互相覆蓋的固定座標碰運氣。

- 必須使用 Godot Control 的 anchors、containers、minimum size 與 viewport-aware layout；視窗大小改變時重新計算布局，不得只為單一解析度硬編碼位置。
- 頭戴驗收至少檢查 1280×720、1280×800 與 1920×1080；每個可見 root UI surface 的矩形必須完全位於 viewport 內，彼此至少保留 8 px 間距，不得遮擋文字、按鈕、飛行視野中央 1/3 或其他 surface。
- Lab Mode 的完整 Operations Dashboard 與 Debug API 氣動面板必須能同時存在；若內容超過可用高度，必須採用可辨識的 scroll/collapse，而非壓縮到文字互相覆蓋。
- Native telemetry 尚未發布時，面板必須顯示明確的 `waiting/unavailable` 狀態；不得在正常冷啟動畫面顯示 `SCHEMA/INVALID`、NaN 或空白欄位作為暫態 placeholder。
- Headed acceptance 必須輸出每個 surface 的 geometry evidence，並以矩形相交與 viewport containment 斷言阻擋回歸；人工截圖若發現重疊，視為 UI gate failure，不得以功能測試通過抵銷。

#### 3.5.6 機體狀態圖（Drone Status Diagram）

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
1. **5 吋穿越機資料包（主打）**：具可再發布授權與 provenance 證據的台架推力表、慣量估測（雙線擺法或 CAD）、階躍響應標定之 τ_m；若沒有合規來源則維持 not verified／blocked，不把「公開」視為可發布。G2.8 與 G3.6(b) 不以真機 blackbox 作為驗收真值；若未來取得合規資料，再依決策重啟對應驗證。
2. **Iris 級資料包**：沿用 PX4 iris.sdf 慣量（0.0291/0.0291/0.0552），供 PX4 SITL 與定高驗證。

---

## 4. 開發階段與剛性驗收門檻

### 4.0 閘門總則 v2（回應審查 Critical 1 / 2）

1. **門檻數值剛性**：核准後凍結，任何人無權下修。未達標 → 修改 → 重測，循環直到通過；每次重測留存報告與差異分析。
2. **Gate 分類與證據要求**：

| Gate 類型 | 執行方式 | 通過證據 |
|---|---|---|
| CI-A（CI 自動化） | Linux headless / 原生單元測試，每次合併執行 | CI 紀錄 + 產物 |
| GPU-A（GPU 自動化） | 具 GPU 之 runner 或實機農場，夜間執行 | 跑分紀錄 + 截圖 |
| DEV-M（維護者遊玩驗收） | 維護者在指定平台親自安裝、操作、遊玩 | 對應 issue 留言確認；可自動量測的數值另附工具產物 |
| USR（使用者研究） | 若 Gate 保留樣本數，改由維護者依固定情境完成可操作性驗收 | 對應 issue 留言確認；不要求外部受測者問卷 |
| LEG（法務/授權審查） | 法務書面核准 | 核准函 |

   可自動化者**必須**自動化（CI-A/GPU-A）；不可自動化者由維護者依固定情境親自驗收並在對應 issue 留言確認。
3. **阻擋範圍（Blocking scope）**：每個 Gate 標註 SC（shared core，阻擋所有 Lane）或平台代號（僅阻擋該 Lane）。任一 SC Gate 未過，所有 Lane 停止進入下一 Phase；平台 Gate 未過僅凍結該 Lane。
4. **Phase 0 特例**：Phase 0 是 Spike，其結論**允許**重定平台範圍與 Profile 歸屬（例如將某效應移出 Mobile Base），但既定 Profile 內的門檻數值不得修改；重定範圍須全體核准人簽字並記入變更紀錄。Phase 1 起無此特例。
5. 豁免程序（預期使用次數為零）：書面技術論證 + 維護者核准 + 對應 issue 留言；不得以此靜默下修技術數值門檻。

**Gate 表格欄位**：Gate | 門檻 | 類型 | 範圍

---

### Phase 0 — 技術可行性驗證（Spike）

**目標**：證明 Godot 4.7 + Jolt + C++ GDExtension 可支撐 Ubuntu 可玩切片、決定性核心與後續 AirSim-class integration。

| Gate | 門檻 | 類型 | 範圍 |
|---|---|---|---|
| G0.1 | Desktop Full profile：物理（Jolt+GDExtension 子步進合計，主執行緒，vsync off，排除前 10 秒 warmup，模擬時間 60 秒）P99 每幀 ≤ 3 ms；Ubuntu 26.04 LTS、AMD Ryzen 9 7945HX、NVIDIA GeForce RTX 4060 Ti、driver 580.159.03 僅為可重現效能基準，不是硬體相容性要求 | GPU-A | SC |
| G0.2 | Mobile High 與 Mobile Base 兩 profile 於基準行動裝置：物理 P99 ≤ 5 ms 且整體 ≥ 60 FPS（量測定義同 G0.1；以 Perfetto 拆解物理/渲染占比）；Android portion 本期 deferred | DEV-M→GPU-A | AND, iOS（future） |
| G0.3 | 1000/500 Hz 子步進下四元數積分 10 分鐘無 NaN、範數漂移 < 1e-6 | CI-A | SC |
| G0.4 | 桌面/行動雙渲染管線同場景資產打通 | GPU-A | SC |
| G0.5 | Xbox 360 相容 gamepad 於 Ubuntu 完成固定 mapping 確認與飛行輸入；RC 遙控器若未來有需求再以新增 Profile 回補 | DEV-M | LIN |
| G0.6a | **Ubuntu 核心決定性**：同平台同 seed/input bitwise 一致；保留 `-ffp-contract=off` 等嚴格浮點旗標。Windows/Android cross-platform replay 可持續監測但不阻擋 Ubuntu qualification | CI-A | LIN |
| G0.6b | **逐 Lane 建置 smoke**：macOS 建置 + 同組測試（僅擋 MAC Lane）；iOS 建置 + 同組測試（**G0.10 Go 後才啟用**，僅擋 IOS Lane） | CI-A | MAC / IOS |
| G0.7 | Linux headless 可無視窗執行完整物理模擬並輸出數據 | CI-A | SC |
| G0.8 | **碰撞權威切換**（回應 High 6）：四場景各 100 次隨機化重複——(a) 30 m/s 正撞牆、(b) 5° 掠角擦地、(c) 撞桿反彈、(d) 翻滾觸地後恢復。全數：無 NaN、速度/角速度有限、動能不增加（restitution 容忍 +1%）、交接後 0.5 秒內飛控可重新響應輸入、同種子重播結果一致 | CI-A | SC |
| G0.9 | **Fidelity 等價**：Mobile Base vs Desktop Full 同輸入序列（60 秒標準機動）姿態軌跡 RMSE ≤ 1.5°、位置 RMSE ≤ 15 cm（**僅擋行動 Lane**；Desktop 主線不受此 Gate 阻擋） | CI-A | AND, IOS |
| G0.P | **可玩垂直切片**：Ubuntu 冷啟動 → 七入口主選單 → Map 選擇 → Quick Fly → spawn → arm → 起飛 → pause → reset → exit 全流程可走通；維護者在真實 display 親眼看到並親自操作，於 issue 留言確認，附 build hash。此 Gate 驗操作性，不取代正式場景、Dashboard 或 AirSim-class gate | DEV-M | LIN |
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
| G1.10 | **5 吋機資料包交付**（3.6.3）：台架推力表與慣量估測資料須有可再發布的授權、來源與 provenance 證據後才可入版控；目前 preset 內的開發用數值不構成 G1.10 證據，沒有合規來源時維持 not verified／blocked，不以「public」推定可發布。不要求真機 blackbox 紀錄。**資料協定**：記錄資料來源、單位、時間基準與適用範圍，並以獨立案例保留調參與驗證結果 | DEV-M | SC |

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
| G2.7 | 手感驗收：維護者以固定情境盲測 Acro 手感，於 issue 記錄比較結果與可操作性結論；不要求外部飛手樣本或真機 blackbox 錨定題 | USR | SC |
| G2.8 | **豁免真機 blackbox 真值重播**：目前不要求真機資料；保留 replay harness 供未來取得合規資料時重啟驗證 | — | — |
| G2.9 | **SITL 交叉驗證（deferred）**：未來如需 Betaflight 對照，再以同輸入比較自研飛控與 Betaflight SITL；它是開發環境信心檢查，不隨 Tier 1 發布、不作 UI/UX 標準，也不阻擋 Ubuntu qualification | — | T2（future） |

---

### Phase 3 — 空氣動力學與氣象（雙軌驗收：公式殘差 + 實測殘差）

| Gate | 門檻 | 類型 | 範圍 |
|---|---|---|---|
| G3.1 | 阻力：等速前飛穩態俯仰/推力 vs Forster 解析 ≤ 5%；**且** C++ 移植版 vs gym-pybullet-drones Python 原版逐點 ≤ 1e-6 | CI-A | SC |
| G3.2 | 地面效應：z/R 5→1 增益曲線 vs Shi Eq.15 ≤ 5%；Python Oracle 逐點 ≤ 1e-6；低空懸停「氣墊」可觀測 | CI-A | SC |
| G3.3 | 下洗：雙機交錯升力衰減 vs DSL 模型 ≤ 10%；Python Oracle 逐點 ≤ 1e-6 | CI-A | SC |
| G3.4 | **Dryden（determinism 修正版）**：解析成形濾波器頻率響應逐 bin 對 MIL-F-8785C 理論譜偏差 ≤ 10%；另以固定 seed 的 Welch 法（段長 2¹⁴、50% overlap、Hann 窗）做 95% CI smoke，輕/中/重三檔；同 seed 重跑 bitwise 一致 | CI-A | SC |
| G3.5 | 風切剖面 vs 軍規模型逐點 ≤ 5% | CI-A | SC |
| G3.6 | Propwash 機制軌：split-S 出彎擾動注入、強度與油門相關係數 ≥ 0.8、關閉時為 0；真機實測殘差軌（原 (b)）依決策豁免，未來取得合規資料時再重啟 | CI-A | SC |
| G3.7 | **效能預算（修正版）**：全效應開啟後，物理 P99 相對 G0 基線增幅 ≤ 20%，且絕對值仍 ≤ 3 ms（桌面）/ 5 ms（行動各 profile） | GPU-A / DEV-M | SC |
| G3.8 | 氣象盲測：維護者盲判無風／中紊流／強陣風，於 issue 記錄判斷與可辨識性結論；不要求外部受測樣本 | USR | SC |

---

### Phase 4 — 渲染、場景與遊戲性

| Gate | 門檻 | 類型 | 範圍 |
|---|---|---|---|
| G4.1 | Reference Performance Profile（Ubuntu 26.04 LTS、AMD Ryzen 9 7945HX、NVIDIA GeForce RTX 4060 Ti、driver 580.159.03）Player Mode 1080p default quality 穩定 60 FPS；僅指定 runner 可阻擋，本機規格不足回報 not-qualified；其他 Godot-compatible GPU 可執行功能驗收，不因未達 reference hardware 阻擋 | GPU-A | LIN |
| G4.2 | 行動基準機同場景 ≥ 60 FPS（P99 ≥ 45），30 分鐘熱節流後 ≥ 50 FPS；Android portion 本期 deferred | DEV-M | AND, IOS（future） |
| G4.3 | GA 交付一張 `Industrial Test Range`：launch area、warehouse/street、obstacle corridor、短 Time Trial route、reset-to-spawn、方向指示與 finish panel；Map Catalog 保留且只有一個真實 entry | GPU-A + DEV-M | LIN |
| G4.4 | FPV 攝影機：uptilt/FOV/OSD；桌面含類比雜訊濾鏡 | GPU-A | SC |
| G4.5 | Kenney City Kit (Industrial) CC0 為主要資產，缺口只用 Godot primitives／自製資產；clean checkout 自動 import，不依賴 Unity／Unreal 轉換 | CI-A + GPU-A | LIN |
| G4.6 | **Playable Game Milestone／第一版 UI/UX 成品標準**：先通過自動化與 headed checks，再由維護者在 Ubuntu 真實 display 親眼看到並親自完成七入口 → Controller／Drone／單一 Map 選擇 → Quick Fly → production vehicle 飛行／碰撞／pause／respawn → 短 Time Trial finish → quit，於 issue 留言確認；這個完整可玩的 packaged game 是第一版 UI/UX 與遊戲流程的成品參考標準，全程無 placeholder 或 developer-only state，Codex Critical/High = 0。此 gate 通過後才開始第一次正式人工視覺／可用性審核與初始 Approved Visual Reference 核准；G2.9 不取代此標準 | CI-A + GPU-A + DEV-M + Codex | LIN |

### Phase 4B — UI/UX

| Gate | 門檻 | 類型 | 範圍 |
|---|---|---|---|
| G4B.1 | 首次啟動至起飛 ≤ 90 秒，由維護者依固定腳本完成並於 issue 記錄計時 | USR | SC |
| G4B.2 | 墜機→重飛功能語意：Reset 保持 armed、解除 pause 並恢復油門輸入；由 GUT 與 headed functional checks 驗證，不列入專用 GPU-A P99 門檻 | CI-A + DEV-M | SC |
| G4B.3 | 固定 mapping 確認流程由維護者無協助完成，於 issue 記錄阻塞點與結論 | USR | DESK, AND |
| G4B.4 | 維護者完成固定可用性檢核並於 issue 記錄結論；不要求外部 SUS 樣本 | USR | SC |
| G4B.5 | 選單深度 ≤ 3 層，自動遍歷驗證 | CI-A | SC |
| G4B.6 | Rates 介面與 Betaflight 曲線公式一致、即時預覽、JSON 與 Betaflight diff 可逐項核對；**PID/濾波顯示 sim profile 免責提示**（3.5.1 原則 2） | GPU-A | SC |
| G4B.7 | 觸控布局與虛擬 Xbox 輸入本期 deferred；待行動／觸控 owner 凍結 semantic-action adapter、按鈕／軸映射與 persistence schema 後重新開票 | — | AND, IOS（future） |
| G4B.8 | 本地化 zh-TW/en 覆蓋 100%、0 硬編碼字串（CI）；**UI 截斷/溢出稽核於 GPU runner 截圖比對**（headless 不得宣稱涵蓋此項） | CI-A + GPU-A | SC |
| G4B.9 | UI 動效以 offset transforms 實作、layout 不變（自動斷言）、不阻塞輸入 > 100 ms | GPU-A | SC |
| G4B.UI1 | **First Fly Flow**：維護者不看說明書——已確認固定 mapping 的相容手把 ≤ 30 秒起飛、未確認 ≤ 90 秒（含完成 Setup Flow）；無控制器時提示與 keyboard fallback 可用，於 issue 記錄計時與結論 | USR | SC |
| G4B.UI2 | **Controller Setup**：Xbox 360 相容手把完成固定 mapping 確認流程；**unknown 裝置必須 100% 主動拒絕並提示 keyboard fallback**（各 10 次注入測試） | DEV-M | DESK, AND |
| G4B.UI3 | **Pause Overlay**：固定項全數存在；rates/camera/OSD 修改即時生效不重載（自動斷言）；Reset 功能由 headed functional check 驗證 | CI-A + DEV-M | SC |
| G4B.UI4 | **OSD Presets**：三 preset 於 1080p 與行動橫向、zh-TW/en 四組合下，主飛行視野遮擋率 ≤ 8%，警告訊息不遮擋畫面中央 1/3（自動截圖幾何稽核） | GPU-A | SC |
| G4B.UI5 | **選擇流程**：主選單七入口固定；Quick Fly 一鍵進預設場；Drone／Map／mode／weather 可選，Map screen 在單一 entry 時仍可用；全流程確認次數 ≤ 3 | GPU-A + USR | LIN |
| G4B.UI6 | **機體狀態圖**：(a) 真值一致——狀態圖各數值 vs 物理層遙測快照逐項相等（容忍僅顯示取整），A1–A10 任一效應關閉時對應指示歸零（自動化逐效應開關測試）；(b) 更新率 ≥ 30 Hz、資料延遲 ≤ 100 ms；(c) 完整版與迷你版渲染成本合計 ≤ 0.5 ms/幀（各平台 Profile）；(d) 迷你版於 Debug OSD 下不違反 G4B.UI4 遮擋門檻 | CI-A + GPU-A | SC |

---

### Phase 5 — 輸入裝置與延遲

| Gate | 門檻 | 類型 | 範圍 |
|---|---|---|---|
| G5.1 | **逐 OS 控制器閘門**：Linux 以 Xbox 360 相容 gamepad 完成固定 mapping 確認 + 斷線重連；Windows / macOS 為 build-only，控制器實機分項維持 N/A（未驗證凍結） | DEV-M | WIN / MAC / LIN |
| G5.2 | Android export/build-only；本期 deferred，OTG gamepad 實機分項維持 N/A（未驗證凍結） | — | AND（future） |
| G5.3 | iOS（若 Lane 續行）：MFi（SDL3 路徑）可完成 G2.3 姿態保持測試；觸控虛擬 Xbox 輸入另行 deferred | DEV-M | IOS |
| G5.4 | 端到端延遲（搖桿電氣訊號→畫面，240fps+ 高速攝影）：桌面 ≤ 40 ms、行動 ≤ 60 ms | DEV-M | 各 Lane |
| G5.5 | 固定 canonical 輸入映射與 schema version 跨 session 持久化，斷線重連不丟設定；v1 不提供玩家重綁或 mapping 匯入/匯出 | CI-A | SC |
| G5.6 | **Channel Monitor 一等 UI**：固定映射下的 raw / normalized / deadzone / 按鍵狀態全數即時顯示，更新率 ≥ 30 Hz；自動檢核四項提示（油門低位、arm 映射、mode 映射、unknown 裝置）功能驗證 | GPU-A + DEV-M | SC |
| G5.7 | **斷線 fail loud**：飛行中拔除控制器 → 500 ms 內畫面警示 + 顯示重連狀態；重插後 ≤ 2 秒恢復輸入且已確認 mapping 不丟失（各 20 次） | DEV-M | 各 Lane |

---

### Phase 6 — 私下發行與部署（取代商店合規）

| Gate | 門檻 | 類型 | 範圍 |
|---|---|---|---|
| G6.1 | Ubuntu x86_64 安裝包 ≤ 300 MB；其他 Player Mode lane 各自驗收 | CI-A | LIN |
| G6.2 | Android APK ≤ 300 MB，側載安裝流程文件化（含簽章與未知來源指引）；**本期 deferred，Android lane 重啟後才啟用** | — | AND（future） |
| G6.3 | 授權掃描：Tier 1 產物 0 GPL/LGPL/AGPL；NOTICE 自動生成 | CI-A | SC |
| G6.4 | 冷啟動至可飛：在 Godot-compatible rendering path 上，桌面 ≤ 15 秒、行動 ≤ 20 秒；不得要求特定 GPU 型號，renderer fallback 後仍須產生可飛畫面並 fail loud 記錄實際 renderer；Android portion 本期 deferred | GPU-A / DEV-M | 各 Lane（Android future） |
| G6.5 | 封測 7 日 crash-free session ≥ 99.5%（遙測須 opt-in，私下發行仍須隱私告知文件）；Android portion 本期 deferred | DEV-M | 各 Lane（Android future） |
| G6.6 | **授權伺服器**：註冊→簽發→JWT 驗證全流程可用；離線寬限期機制（斷網 ≤ 72 小時可玩）；伺服器不可達時明確提示而非靜默鎖死 | CI-A + DEV-M | SC |
| G6.7 | 交付流程演練：從客戶名單到發送安裝檔+授權金鑰之 SOP 全程演練一次成功，含撤銷授權 | DEV-M | SC |
| G6.8 | **診斷支援包（回應審查 H10）**：`Settings > Diagnostics > Export Support Bundle` 一鍵匯出——build hash、OS/GPU/裝置資訊、授權狀態、近期 log、控制器 raw 取樣、輸入映射與 mapping schema version、最後錯誤；**自動化稽核：bundle 內 0 個 secrets / JWT / 個資（遮罩驗證）** | CI-A + DEV-M | SC |
| G6.9 | **設定持久化表（回應審查 H9）**：Persistent（mapping/schema version/rates/OSD 配置/相機/語言/畫質）與 Volatile（本局 spawn/臨時風況/當場計時與遙測）逐項落地一致；settings schema 含 version；factory reset 可用；匯入失敗回退預設並明示。觸控布局不在本期 domain allowlist。 | CI-A | SC |

---

### Phase 7 — AirSim-class platform minimum

| Gate | 門檻 | 類型 | 範圍 |
|---|---|---|---|
| A7.1 | Player Mode 與 Lab Mode 使用同一 simulation session；七入口、單一 Map Catalog、雙機識別與 Operations Dashboard 全部可操作，無 placeholder state | CI-A + GPU-A | LIN |
| A7.2 | `airsim==1.8.1` unmodified client 連線至 loopback-only RPC（default `127.0.0.1:41451`），支援 manifest 內 connection/pause/step/reset/settings；未知 API、setting、non-loopback bind fail loud | CI-A | LIN |
| A7.3 | 兩個 named vehicles 完成 takeoff/land/hover/home/position/path/velocity/yaw/attitude/body-rate+throttle async commands，cancel/join 與隔離語意正確；逐馬達 PWM 明確 unsupported | CI-A + GPU-A | LIN |
| A7.4 | 外部 payload 全部 NED world、FRD body、SI；simulation time 控制 pause/frames/duration 與各 sensor rate，同 seed/commands/steps 產生相同 timestamp、sample count 與狀態 | CI-A | SC |
| A7.5 | 每台車提供 Scene、DepthPlanar、Segmentation、IMU、GPS、magnetometer、barometer、LiDAR；PNG/raw/float 行為、幾何一致性、segmentation ID、noise/rate、雙機 isolation 全部通過 fixture | CI-A + GPU-A | LIN |
| A7.6 | 鎖定 PX4 版本完成 SITL connect → arm → deterministic mission → land；Dashboard 顯示具名狀態與失敗原因；ArduPilot/HITL 不納入 | CI-A + DEV-M | LIN |
| A7.7 | Lab Mode 只能從 checked-in catalog spawn/move/query/destroy objects；風、雨、霧、日照時間可由 UI/API 控制，進入 Replay/Dataset，未知 asset/path 明確拒絕 | CI-A + GPU-A | LIN |
| A7.8 | Flight Replay 可重建雙機、commands、environment、objects 與 collisions；Dataset Recording 產生 versioned directory（manifest/JSONL/PNG/PFM/float32 LiDAR），validator 能拒絕 incomplete、gap、identity 或檔案錯誤 | CI-A | LIN |
| A7.9 | 每個 PR 執行 structure/dependency/collision/render/basic-image checks；視覺相關變更與每次 release 具四張固定 GPU screenshots 與 Codex strict JSON review，Critical/High = 0。G4.6 前使用 provisional reference 且不要求人工；G4.6 後才建立 Approved Visual Reference，後續重大 replacement 須人工核准 | GPU-A + Codex | LIN |
| A7.10 | 指定 Reference Performance Profile：Player Mode 1080p default 60 FPS；文件化雙機 sensor workload real-time factor ≥ 1.0。本機低規格只可 not-qualified，不得因硬體規格阻擋功能開發 | GPU-A | LIN |

---

### Phase 8 —（桌面限定）Betaflight SITL 專業模組

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
3. 效能資格機凍結：Ubuntu 26.04 LTS、AMD Ryzen 9 7945HX、NVIDIA GeForce RTX 4060 Ti、driver 580.159.03。效能 gate 只在具名 runner 阻擋；其他本機執行功能／決定性測試並回報 not-qualified。未來 Player Mode lane 的平台基準各自凍結，不阻擋 Ubuntu。
4. 盲測規範：受測者不知修改內容；問卷使用固定情境比較題，不依賴真機 blackbox 回放。
5. 版本鎖定：Godot 4.7 之 patch 版本與 export template hash 記錄於 repo；引擎升級觸發 G0–G3 全量重跑。
6. AirSim 引用證據：每個受影響 issue／PR 必須列出 v1.8.1 path／symbol／commit、open/closed issue queries、相關 URL 與 disposition、license attribution 及導出測試；無結果只代表查過，不代表無缺陷。
7. Agent 證據：Codex 報告記錄實際 model identity 與 reasoning profile；Sol 建議須附問題邊界與主 Agent 的採納或拒絕理由。

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
| Microsoft AirSim 1.8.1 @ `96235148a332fe7cb3d3525a0720e26faaca99e0` | Python client、RPC/settings 相容與實作參考；引用前查 upstream issues | MIT |
| PX4 | minimum SITL 飛控 | BSD-3-Clause |
| Kenney City Kit (Industrial) | Industrial Test Range 主要 3D 資產 | CC0 |
| gym-pybullet-drones | 氣動公式 + CI Python Oracle | MIT |
| Betaflight（SITL） | Tier 2 真韌體；Phase 2 交叉驗證工具 | GPL-3.0（隔離） |
| SimITL / KwadSim / pr0p 文獻 | 雙模擬子步進架構參考 | 參考 |
| MIL-F-8785C / MIL-HDBK-1797 | Dryden / 風切 | 公開標準 |
| Flowstate | 開源 UX 參考（HUD） | 開源 |
