# PRD_AeroSim Adversarial Review Report

審查對象：`PRD_AeroSim.md`  
方法：2 個 subagent 平行對抗式審查，第二輪交叉互評後由主 agent 彙整。  
狀態：未修改 `PRD_AeroSim.md`；本報告為新增審查文件。

## Executive Summary

兩位 reviewer 的共同結論：這份 PRD 最大問題不是某幾個數值門檻太嚴，而是 Gate 模型本身不自洽。它把 CI、自動化數值測試、實機跑分、使用者研究、法務稽核、商店審查與人工盲測都塞進同一種「剛性不可調 Gate」，導致文件一旦核准就很可能無法執行。

最小有效修正不是逐條改 Gate，而是先補四個欄位：

- `Gate type`：CI / device lab / user study / legal review / store review / manual protocol
- `Platform scope`：Desktop / Android / iOS / Tier 2 DLC / shared core
- `Release blocking scope`：阻擋整體 Phase、阻擋相依工作、或只阻擋特定平台發布
- `Change procedure`：Phase 0 發現不可行時如何調整門檻，而不是把 Spike 結果也鎖死

## Mutual Review Consensus

Subagent A（技術/物理/工程）與 Subagent B（產品/UX/法務/發布）互評後的共識：

1. Gate 模型不自洽是最高優先問題，應列 Critical。
2. 全平台發布被行動端 Gate 綁死，會直接阻斷桌面 GA，應列 Critical。
3. GPL/Tier 2 邊界不能只靠「獨立行程 + UDP」宣稱安全，尤其 G7.2 引入 Configurator / WebSocket proxy 後更複雜。
4. Linux headless 只能承擔核心模擬與部分資產 smoke test，不能代表 rendering、UI、截圖、GPU、mobile thermal 或 store build。
5. 行動端 240Hz Jolt + 1000Hz 子步進 + 全氣動效果的單一硬門檻過度剛性；應改成平台 profile 與可驗證 fidelity tier。
6. 物理 Gate 多數只驗公式一致，還不足以支撐「真實 FPV 訓練」商業承諾。
7. Betaflight 設定「1:1 抄進遊戲，反之亦然」是過度承諾；可保留 rates 公式一致，但 PID/filter/手感等價需降級。
8. SITL crash 時靜默回退內建飛控會誤導使用者，也會污染 blackbox/調參結果。

保留異議：

- A 認為「高頻自研物理與 Jolt 權威切換」應進 Top 8；B 同意重要，但認為比 GPL、商店合規與全平台 release scope 低一級。彙整後保留在 Top 8，因為它是核心飛行手感與 crash/retry loop 的產品級風險。
- B 認為商店合規缺項可列 Critical；A 認為若首發不含 IAP/UGC/遙測，嚴重度應依功能開啟而定。彙整後列 High，並建議用 store compliance matrix 作條件式 Gate。

## Top Findings

### Critical 1. Gate 模型自相矛盾，PRD 核准後不可執行

位置：`PRD_AeroSim.md:8`, `PRD_AeroSim.md:136-141`, `PRD_AeroSim.md:155`, `PRD_AeroSim.md:221-240`, `PRD_AeroSim.md:261`

問題：PRD 宣稱每個 Gate 都是剛性、不可調、必須自動化並納入 CI，但同一份文件又要求實機人工驗證、使用者測試、SUS 問卷、高速攝影與法務稽核。這不是測試細節缺漏，而是治理模型衝突。

影響：團隊會在第一個人工或實機 Gate 遇到「違反總則」；最後只能假裝 CI 覆蓋，或任意破例。

最小修正：

- 把 Gate 分為 `CI automated`、`device-lab automated`、`manual protocol`、`user-study`、`legal/store review`。
- 總則改成「可自動化者必須自動化；不可自動化者必須保存原始紀錄、環境、判定表與 reviewer 簽核」。
- 每個 Gate 加上 `release blocking scope`，避免平台專屬 Gate 阻斷不相依工作。

### Critical 2. 全平台發布被剛性 Gate 綁死，桌面 GA 會被 iOS/Android 風險阻斷

位置：`PRD_AeroSim.md:19`, `PRD_AeroSim.md:27`, `PRD_AeroSim.md:136-140`, `PRD_AeroSim.md:152`, `PRD_AeroSim.md:239`

問題：核心目標是 Windows / macOS / iOS / Android 全平台發布，且任一 Gate 未過不得進下一 Phase。這表示 Android OTG、iOS MFi/觸控、行動熱節流、App Store 審查任何一項卡住，都會阻斷桌面版上市。

影響：最大商業風險是發布節奏失控。桌面 FPV 核心客群會被行動端硬體、政策與輸入限制拖住。

最小修正：

- 新增 release lanes：`Desktop GA`、`Android beta/GA`、`iOS beta/GA`、`Tier 2 DLC`。
- Shared physics Gate 可阻擋 shared core；平台專屬 Gate 只阻擋該平台。
- Phase 0 應允許驗證後重定平台 scope，不應把 Spike 的未知數也永久鎖死。

### Critical 3. GPL/Tier 2 邊界不可驗收，且 G7.2 擴大法務風險

位置：`PRD_AeroSim.md:20`, `PRD_AeroSim.md:28`, `PRD_AeroSim.md:48`, `PRD_AeroSim.md:261-262`, `PRD_AeroSim.md:296`

問題：PRD 把「獨立行程 + UDP」寫成「隔離後安全」。但 GPL 邊界不只看 IPC 形式，也看兩邊交換資料的語意與耦合程度。G7.2 又加入 WebSocket proxy 連接 Betaflight Configurator，讓資料流、散布方式與 UI 整合更複雜。

影響：閉源商用承諾可能失真；DLC 發布、source/build script 對應、Configurator/Blackbox 整合方式都需要法務與架構同時審查。

最小修正：

- 將「隔離後安全」改為「需法務核准後才可發布」。
- G7.1 增加：無 shared memory、無動態/靜態連結、公開穩定協定、GPL binary/source/build scripts 一一對應。
- Configurator / Blackbox 不嵌入專有主程式；最多外開獨立 GPL 工具或清楚標示為外部工具。

### Critical 4. Linux headless 被過度當成官方萬能驗收平台

位置：`PRD_AeroSim.md:75`, `PRD_AeroSim.md:157`, `PRD_AeroSim.md:228`, `PRD_AeroSim.md:271`

問題：PRD 指定 Linux headless 為所有自動化 Gate 的官方平台，但 headless 不能代表客戶端 rendering、UI 截圖、GPU pipeline、mobile thermal、store build 或輸入延遲。

影響：UI、截圖、本地化、渲染、行動效能可能在 CI false pass，等到實機或商店提交才爆炸。

最小修正：

- Linux headless 限定為數值模擬、頻譜分析、核心 GDExtension 單元測試與資產載入 smoke。
- Rendering/UI/screenshot/performance Gate 改用 GPU runner 或實機 device lab。
- G4B.8 的截圖稽核不得宣稱只靠 headless 完成。

### High 5. 行動端性能目標與物理野心不成比例

位置：`PRD_AeroSim.md:72`, `PRD_AeroSim.md:151-152`, `PRD_AeroSim.md:180`, `PRD_AeroSim.md:200`, `PRD_AeroSim.md:283`

問題：PRD 要求行動端同時支援 240Hz Jolt、1000Hz 飛控子步進、全氣動效果，且 G3.7 要「效能不退步」。加入 Dryden、downwash、propwash 後仍不退步，工程上不合理。

影響：Snapdragon 7 Gen 1 / A15 很可能卡死 Phase 0 或 Phase 3；風險登記簿的 500Hz 降級又被剛性 Gate 排除。

最小修正：

- G3.7 改成「不超過 G0 baseline + X% 或絕對預算」。
- 行動端建立 fidelity tier：例如 500Hz + 插值 / 氣動 LOD，但需與桌面 1kHz 訂輸出誤差上限。
- Phase 0 要先測 mobile input/UI/physics feature lock，不要等 Phase 4B/5。

### High 6. 高頻自研物理與 Jolt 權威切換沒有驗收 Gate

位置：`PRD_AeroSim.md:72-75`

問題：自由空間由 GDExtension 高頻積分，碰撞由 Jolt，碰撞時「狀態權威切換至 Jolt」。但 PRD 沒有定義 canonical state、衝量回寫、能量/角動量容許誤差、CCD/tunneling 策略。

影響：最危險的產品場景是撞門框、擦地、反彈、翻滾後恢復。現有 G1/G2/G3 多是自由飛行數值測試，抓不到這類 crash/retry loop 的核心 bug。

最小修正：

- Phase 0 新增碰撞交接 Gate：高速撞牆、擦地、反彈、翻滾後恢復。
- 驗收：姿態無 NaN、速度/角速度有限、能量損失符合 restitution/friction 預期、飛控狀態恢復可重現。

### High 7. 真實手感驗收缺外部真值，只驗公式一致不夠

位置：`PRD_AeroSim.md:83-90`, `PRD_AeroSim.md:102`, `PRD_AeroSim.md:194-201`, `PRD_AeroSim.md:277`, `PRD_AeroSim.md:286`

問題：阻力、地面效應、downwash 多數 Gate 是拿實作去比來源公式；Propwash 是自研噪音項，沒有外部真值。這是模型回歸測試，不是擬真驗收。

影響：產品可通過公式測試，仍不像 5 吋 FPV 真機。這會削弱「硬核物理」與「FPV 訓練」定位。

最小修正：

- Phase 1 交付 5 吋機資料包：推力台架、慣量估測、blackbox、真機 step response、典型 propwash maneuver。
- G3 Gate 改成「公式殘差 + 實測資料殘差」雙軌。
- G2.7 / G3.8 盲測保留，但不能取代外部數據。

### High 8. Betaflight 等價承諾與 SITL fallback 會誤導使用者

位置：`PRD_AeroSim.md:111`, `PRD_AeroSim.md:184`, `PRD_AeroSim.md:226`, `PRD_AeroSim.md:265`

問題：PRD 說 Betaflight 調參術語與數值「完全同名同義」，且玩家真機設定可 1:1 抄進遊戲、反之亦然；同時 G7.5 要 SITL 崩潰時自動回退內建飛控。這會讓使用者以為仍在 Betaflight 模式飛，實際上控制器已切換。

影響：手感、調參結果、blackbox 記錄都會失真。若使用者把模擬器 PID/filter 直接抄回真機，也有產品責任風險。

最小修正：

- 只承諾 rates 曲線與匯入格式對齊；PID/filter 標示為 sim profile，不保證真機安全或等價手感。
- SITL crash 時 fail loud：暫停該 run 並提示 SITL unavailable；只允許回主選單或重開 run 後切回 Tier 1。

## Additional Findings

- G0.6 跨平台 bitwise/1e-9 浮點一致不現實。建議同平台 replay 才要求 bitwise；跨平台改用物理量 tolerance。
- G2.3 把 Angle Mode 當成 Position Hold。Angle Mode 是姿態控制，沒有 optical flow/GPS/position hold 不應要求 60 秒水平位置漂移 <= +/-5 cm。
- G0.1/G0.2 的「每幀物理預算」未定義量測點、thread、warmup、vsync、simulated time、是否含 Jolt/GDExtension/GDScript。
- G3.4 Dryden PSD Gate 未定 seed、Welch 參數、binning、信賴區間，會導致 flaky test。
- `Godot 4.7+` 應 pin 到版本、commit、export template hash；升級需重跑 G0-G3。
- Tier 2 Linux DLC 沒有 Tier 1 Linux host game 發布路徑。要嘛把 Linux 改成 dev/headless only，要嘛把 Tier 1 Linux 納入正式發布 Gate。
- iOS 包大小「蜂窩下載提示線以下」不是穩定可驗收門檻。應改為 thinned initial install / ODR 或 asset pack 的明確數字。
- Phase 6 商店合規缺 matrix：IAP、privacy/data safety、UGC、review notes/demo mode、age rating、硬體需求、資料刪除路徑、遙測 opt-in。

## Recommended PRD Patch Shape

最小修改順序：

1. 先新增 Gate 欄位：`Gate type`、`Platform scope`、`Release blocking scope`、`Evidence required`。
2. 將總則從「所有 Gate 必須自動化」改成「所有可自動化 Gate 必須自動化；其他 Gate 需有標準化 protocol 與 evidence」。
3. 切分 release lane：Desktop GA、Android GA、iOS GA、Tier 2 DLC。
4. 把 Phase 0 定位為可重選技術棧與調整 scope 的 Spike，不要把未知假設凍結成不可修改法律契約。
5. 再逐條修技術 Gate：collision handoff、mobile fidelity tier、floating tolerance、Angle Mode、Dryden PSD、Godot version pin。

## External Fact Checks

- Godot 4.7 官方 release 頁確認 4.7 已發布，並提到 Control offset transforms、Android Perfetto/GABE 等新能力：https://godotengine.org/releases/4.7/
- Godot 4.7 `VirtualJoystick` 官方文件確認此節點存在且為 touchscreen control：https://docs.godotengine.org/en/4.7/classes/class_virtualjoystick.html
- Godot 4.6 / 4.7 文件確認 Jolt 已是新 3D 專案預設物理引擎：https://docs.godotengine.org/en/4.7/tutorials/physics/using_jolt_physics.html
- Godot 4.7 features 文件確認 C# web 不支援，Android/iOS C# 支援仍有 experimental 限制；GDExtension 可用於高效能 native integration：https://docs.godotengine.org/en/4.7/about/list_of_features.html
- Apple Developer Program License Agreement 對 iOS App 下載/安裝 executable code 有限制，並要求功能解鎖走允許的分發機制：https://developer.apple.com/support/terms/apple-developer-program-license-agreement/
- FSF GPL FAQ 說 sockets/command-line 通常是 separate programs，但語意耦合仍可能影響是否被視為單一作品：https://gplv3.fsf.org/wiki/index.php/FAQ_Update
- Apple App Review Guidelines 對 UGC moderation、IAP、metadata/review 等有明確要求：https://developer.apple.com/app-store/review/guidelines/
- Google Play Data safety 文件要求開發者申報資料收集/分享、安全實務與隱私政策：https://support.google.com/googleplay/android-developer/answer/10787469?hl=en

