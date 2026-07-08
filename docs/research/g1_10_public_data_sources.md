# G1.10 公開資料源調研與評估報告

日期：2026-07-08  
範圍：GitHub issue [#22](https://github.com/jhihweijhan/AeroSim/issues/22) 的 agent 調研階段。只評估公開資料源，不下載大量資料、不聯繫社群、不實作模型。

## 文件自檢 checklist

- [x] 對照 G1.10 blackbox 擷取協定
- [x] 列出台架資料源、來源連結、授權/C-2 評估、結論
- [x] 列出 Betaflight blackbox 資料源、來源連結、授權/C-2 評估、結論
- [x] 明確標示可直接用 / 部分可用 / 不可用
- [x] 列出資料不足時的社群代錄需求規格
- [x] 記錄 PX4 Iris 慣量來源與可引用性
- [x] 給維護者建議路徑

## 結論摘要

目前沒有找到可直接入版控、同時滿足 G1.10 技術欄位與 C-2 授權的完整公開資料源。

建議路徑：台架資料以 Tyto Robotics database 作候選短名單，但需維護者取得書面授權或改由社群/實驗室以 C-2 相容授權代測；blackbox 不採用現成公開 log，改發社群代錄規格收 calibration/holdout 獨立架次；Iris 級資料可引用 PX4 `iris.sdf.jinja` 的慣量。

## G1.10 判準摘要

### 台架表

5 吋穿越機主資料包需要 2207 級馬達 + 5.1 吋槳的台架表，至少要能擬合 `k_t` 與 `k_q`：

- 推力
- 扭矩
- 轉速
- 電流
- 量測條件：電壓/電池或電源、ESC、測試台、環境或至少測試方法
- 授權：C-2 相容，即 MIT/BSD/Zlib/Apache-2.0/公有領域，或資料權利人明確授權可入閉源 Tier 1 repo

### Betaflight blackbox

逐源對照項目：

- 韌體版本與濾波設定已知
- 未濾波 gyro 可得
- 含 step response
- 含典型 propwash 動作
- calibration/holdout 可切成不同飛行架次
- 機體參數可考證：馬達、槳、電池、AUW、機架/慣量估測
- 時間對齊/重採樣方法已文件化
- 初始條件已記錄：場地、風況、起飛電壓、模式、rates、camera angle
- 授權：C-2 相容，可入版控

## 候選台架資料源

| 資料源 | 技術覆蓋 | 授權/C-2 | 結論 | 理由 |
|---|---|---|---|---|
| [Tyto Robotics motor/prop/ESC database](https://database.tytorobotics.com/) | 部分符合。首頁標示 1518 組 propulsion systems、174811 data samples；測試頁 HTML 欄位含 rotation speed、thrust、torque、voltage、current。馬達清單可查到 2207 級，例如 [EMAX RSII 2207 2300Kv](https://database.tytorobotics.com/motors/kge/emax-rsii-2207-2300kv)、[Hypetrain Blaster 2207 2450Kv](https://database.tytorobotics.com/motors/9xz/hypetrain-blaster-2207-2450kv)、[DYS Samguk Wei 2207 2600kv](https://database.tytorobotics.com/motors/e65/dys-samguk-wei-2207-2600kv)。槳清單可查到 5.1 吋，例如 Gemfan Hurricane 51499、Azure Power 5150、T-Motor 5143、HQ 5151/5146/5141/5131。 | 不明/不相容。頁尾為 Copyright，Terms 沒有看到資料開放授權；資料庫文章稱 community-driven，但未等於 C-2 授權。 | 部分可用（僅技術參考；不可入 repo） | 技術欄位最接近 G1.10，但不可直接入版控。若維護者取得 Tyto 或資料上傳者書面授權，才可轉為可入庫資料。 |
| [Mini Quad Test Bench](https://www.miniquadtestbench.com/motor-explorer.html) / [T-Motor F60 2207 2450kv](https://www.miniquadtestbench.com/t-motor-f60-2207-2450kv.html) | 部分符合。網站有 2207 級馬達與 5 吋/接近 5.1 吋 FPV 槳測試；資料 explorer 明列 throttle hold、ramp、thrust、RPM、volts、amps、power、efficiency。 | 不明/不相容。網站與 Google Sheet 未見 MIT/BSD/CC0 等資料授權。 | 部分可用 | 可用作 sanity check 或候選零件參考；缺扭矩欄，不能擬合 `k_q`；授權不明，不能直接放入 Tier 1。 |
| [UIUC Propeller Data Site](https://m-selig.ae.illinois.edu/props/propDB.html) | 不符合本任務。UIUC 有公開風洞/靜態 propeller thrust/torque coefficient 資料，方法與引用清楚；但主要是 prop-only，非 2207 馬達 + 5.1 槳 + ESC 的電流/RPM/扭矩/推力整套台架。 | 學術公開資料，可引用；但頁面未看到可直接重散布進商用閉源 repo 的 C-2 授權。 | 不可用 | 可作公式/量測方法參考，不可作 G1.10 5 吋機台架真值。 |
| 廠商規格表/商店頁（T-Motor、HQProp、Gemfan 等） | 通常只有推力、電流、電壓、槳型，少見扭矩；量測條件與原始點不完整。 | 多為版權所有，無資料授權。 | 不可用 | 可作零件型號與合理範圍參考，不能替代 G1.10 台架表。 |

台架資料結論：Tyto 是唯一找到同時可能含四欄與 2207/5.1 候選組合的公開入口，但授權未過 C-2；Mini Quad Test Bench 接近 FPV 場景但缺扭矩。沒有可直接用來源。

## 候選公開 Betaflight blackbox 資料源

| 資料源 | 韌體/濾波 | 未濾波 gyro | step response | propwash | calibration/holdout | 機體參數 | 時間對齊/重採樣 | 初始條件 | 授權/C-2 | 結論 |
|---|---|---|---|---|---|---|---|---|---|---|
| [pichim/bf_controller_tuning](https://github.com/pichim/bf_controller_tuning) | 已驗證。README 要求 chirp、blackbox high resolution、debug `CHIRP`；抽查 `20250907/20250907_apex5_00.bbl` header 顯示 Betaflight `2025.12.0-beta (9d3558c3f)`、filter/PID/RPM filter/DShot 等設定。 | 已驗證。抽查 `20250907/20250907_apex5_00.bbl` field list 含 `gyroUnfilt[0..2]`。 | 部分符合。README 是 chirp excitation 與 offline step response 分析，適合辨識；但使用 Betaflight PR/custom beta，不是一般穩定版 flight log。 | 部分符合。README 要求 flips 等 propwash 動作；未逐段驗證每個 log 都含有效 propwash。 | 部分符合。有多個日期/機體 log，如 `20250907/20250907_apex5_00.bbl`、`20250918/20250918_aosmini_01.bbl`；但 repo 未明確標記 calibration/holdout。 | 部分不足。header 有 craft name、motor_kv、板子；未看到完整馬達型號、槳型、AUW、慣量。 | 不足。Blackbox 有時間欄位，但 repo 未把 AeroSim 所需的時間對齊與重採樣方法文件化。 | 不足。header 有 craft name 等少量資訊，未看到場地、風況、起飛電壓、rates、camera angle 的完整初始條件包。 | 不相容。repo license 是 GPL-3.0；資料未另列 C-2 授權，預設不可入 Tier 1。 | 技術上部分可用，授權上不可用 |
| [Betaflight Blackbox Log Viewer](https://github.com/betaflight/blackbox-log-viewer) | 工具支援讀 blackbox，官方文件說 log header 可檢查設定；repo 本身不提供 G1.10 資料集。 | 不適用。 | 不適用。 | 不適用。 | 不適用。 | 不適用。 | 不適用。 | 不適用。 | GPL-3.0；且是工具不是資料。 | 不可用 |
| [Betaflight blackbox-tools](https://github.com/betaflight/blackbox-tools/) | 工具可轉 CSV/PNG；不是資料集。 | 不適用。 | 不適用。 | 不適用。 | 不適用。 | 不適用。 | 不適用。 | 不適用。 | GPL-3.0；且是工具不是資料。 | 不可用 |
| [PIDtoolbox](https://github.com/ianrmurphy/PIDtoolbox) | 分析工具，README 聚焦 Betaflight blackbox PID/propwash 分析。 | 不適用。 | 工具可分析 step response，但 repo 未提供可用 log 資料集。 | 工具可分析 propwash，但 repo 未提供可用 log 資料集。 | 不適用。 | 不適用。 | 不適用。 | 不適用。 | 授權非 C-2 可直接採用路徑；且無資料集。 | 不可用 |
| FPV 社群論壇/Facebook/YouTube/個別 issue 附件 | 通常零散，可能有 log 或截圖。 | 不可驗證。 | 不可驗證。 | 不可驗證。 | 不可驗證。 | 不可驗證。 | 不可驗證。 | 不可驗證。 | 多數無明確資料授權；社群平台再散布條款也不等於 C-2。 | 不可用 |

blackbox 資料結論：`pichim/bf_controller_tuning` 是最接近 G1.10 技術需求的公開 log 倉庫，抽查 header 可證明有韌體/濾波與未濾波 gyro；但 GPL-3.0 與缺完整機體參數使它不能直接作 Tier 1 真值。其他來源多是工具或教學，不是可入庫資料集。

## 社群代錄需求規格

若維護者要對外徵求代錄，最低規格如下。

### 授權與交付

- 錄製者需明確授權資料以 CC0、MIT、BSD-2/3-Clause、Apache-2.0，或等價可閉源商用重散布授權納入 AeroSim。
- 交付原始 `.bbl`/`.bfl`、Betaflight CLI `diff all`/`dump`、機體照片、零件清單、AUW 實測、電池型號與當天使用電壓範圍。
- 交付時間對齊/重採樣說明：原始 log 時間欄位、起訖段落標記、同步基準、目標取樣率、插值方法、丟包/缺值處理，並附可重跑的轉檔命令或腳本。
- 每個檔案命名含日期、機體、用途：`YYYYMMDD_5inch_calibration_01.bbl`、`YYYYMMDD_5inch_holdout_01.bbl`。

### 目標硬體

- 5 吋或 5.1 吋穿越機，6S 優先。
- 馬達：2207 級，KV 1750-2050 優先；需記錄品牌/型號/KV。
- 槳：5.1 吋三葉，優先 5.1x4.3x3 或 5.1x4.9x3；需記錄品牌/型號與正反槳。
- AUW：含電池上秤，記錄到 1 g。
- 電池：S 數、容量、C rating、使用前/後電壓。

### Betaflight 設定

- 使用穩定版 Betaflight；若使用 custom build，需交付 commit hash 與理由。
- Blackbox logging 開啟 high resolution；sample rate 至少 1 kHz，優先 2 kHz。
- Log 欄位需包含 `gyroADC[0..2]`、`gyroUnfilt[0..2]`、`rcCommand[0..3]`、`setpoint[0..3]`、`motor[0..3]`、電壓/電流、RPM telemetry（若硬體支援）。
- 記錄 gyro/dterm/RPM/dynamic notch/filter 全部設定；以 header 與 CLI dump 雙重保存。

### 飛行架次

- Calibration：至少 2 個獨立 flight logs，只能用於調參/辨識。
- Holdout：至少 2 個獨立 flight logs，不得與 calibration 同架次；G2.8/G3.6 只用 holdout 報告。
- 每組至少含：roll/pitch/yaw stick step 或 chirp 類激振、快速翻滾/回正、split-S 或 dive recovery、低油門下降後補油門的 propwash 動作、正常巡航段。
- 記錄初始條件：場地、風況估計、起飛電壓、飛行模式、rates、camera angle。

## Iris 級資料包

來源：PX4-SITL_gazebo-classic commit `00ac441b271ef78eb0f394ae000d87e150d08066` 的 [`models/iris/iris.sdf.jinja`](https://github.com/PX4/PX4-SITL_gazebo-classic/blob/00ac441b271ef78eb0f394ae000d87e150d08066/models/iris/iris.sdf.jinja)。

已驗證 base link inertial 參數：

| 參數 | 值 |
|---|---:|
| mass | 1.5 kg |
| ixx | 0.029125 kg m^2 |
| iyy | 0.029125 kg m^2 |
| izz | 0.055225 kg m^2 |
| ixy / ixz / iyz | 0 |

可引用性：同 commit 的 [`package.xml`](https://github.com/PX4/PX4-SITL_gazebo-classic/blob/00ac441b271ef78eb0f394ae000d87e150d08066/package.xml) 宣告 `<license>BSD</license>`，符合 C-2 的 BSD 類授權。GitHub license API 未在 repo 根目錄偵測到標準 LICENSE 檔，因此資料包引用時必須同時保留 `package.xml` 連結與 commit hash，避免只寫「PX4」而缺授權證據。

## 建議路徑

1. 台架資料：以 Tyto 作候選查詢與零件短名單來源，但不要直接入版控；維護者先向 Tyto 或資料上傳者取得書面 C-2 相容授權。若拿不到授權，改發社群/實驗室代測需求。
2. Blackbox：不要使用現成公開 log 作真值。`pichim/bf_controller_tuning` 可當技術參考，但 GPL-3.0 不可入 Tier 1；維護者應按上方代錄規格徵求 5 吋機 calibration/holdout 獨立架次。
3. Iris：可直接建立小型 Iris 參數包，引用 PX4 `iris.sdf.jinja` 的慣量值；後續入庫時固定來源 commit。
4. Issue #22 下一步：維護者拍板「取得 Tyto 授權」或「社群代錄/代測」。在拍板前，不應把任何 GPL 或授權不明資料放進 repo。

## 驗證紀錄

已 verified：

- PRD `G1.10`、`3.6.3`、`G2.8`、`G3.6` 需求已從本 repo `PRD_AeroSim.md` 讀取。
- GitHub issue #22 agent brief 與 #56 開工指南已用 `gh api` 讀取；`gh issue view` 因 GitHub classic Projects 欄位錯誤失敗，改用 `gh api`。
- Tyto database 首頁、tests HTML 欄位、motors/propellers 清單、Terms 頁已查；確認有技術欄位與 2207/5.1 候選，但未見 C-2 授權。
- Mini Quad Test Bench explorer 與 T-Motor F60 2207 頁已查；確認有 thrust/RPM/volts/amps/power 類資料，但缺 torque 與 C-2 授權。
- `pichim/bf_controller_tuning` README、LICENSE、檔案樹與多個 log header 已抽查；確認 GPL-3.0、`gyroUnfilt`、Betaflight 版本與濾波設定存在。
- PX4 Iris `iris.sdf.jinja` 慣量與 `package.xml` BSD 宣告已查；來源固定於 commit `00ac441b271ef78eb0f394ae000d87e150d08066`。

not verified：

- 未登入 Tyto database 逐筆核對某一個「2207 馬達 + 特定 5.1 槳」測試是否同時含完整四欄；公開 HTML 顯示欄位與候選元件存在，但組合層級未完全驗證。
- 未確認 Tyto 或 Mini Quad Test Bench 願意授權資料入 AeroSim；目前視為授權不明/不可直接用。
- 未完整解析任何 `.bbl` 全檔或計算 propwash/step response 指標；只抽查 header 與 README 流程。
- Vault recall 查詢未取得可用結果：第一次參數錯誤，改用 `--repo /home/karl/Workspace/Toys/AeroSim` 後無輸出。
