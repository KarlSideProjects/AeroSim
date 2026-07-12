# 2026-07-12 — Xbox Default Profile：固定映射確認取代校準精靈（PRD v3.4）

| 欄位 | 內容 |
|---|---|
| 決策日期 | 2026-07-12 |
| 決策人 | Karl（維護者） |
| 對應 issue | #40（主）、#41、#49 |
| 性質 | **需求範圍縮減**（比照 G2.8 豁免先例），明文記錄，非靜默下修 |

## 決策內容

以**固定、版本化的 Xbox 360 相容手把映射**取代八步校準精靈：偵測到相容手把（`Input.is_joy_known()`，SDL mapping 存在）→ 確認畫面（顯示固定映射與四軸即時值）→ 玩家確認 → 建立 session `GamepadProfile` → preflight。unknown 裝置明確提示不支援＋keyboard fallback，禁止套用 Xbox 映射。

## 驅動因素

1. **需求簡化**（維護者裁定）：產品只需支援標準手把即可遊玩。
2. **平台事實**：Godot 內建 SDL gamepad mapping 資料庫，Xbox 360 相容手把的軸/按鍵布局標準化（`JOY_AXIS_*` 值域 -1..1），四軸唯一性由布局保證，逐軸校準屬過度工程。
3. **產品定位**：目標使用者為手把玩家（延續 v3.3 決策）。

## 移除與保留

| 移除（範圍縮減） | 保留（仍為硬性要求） |
|---|---|
| 八步校準精靈（3.5.4 原固定順序） | 固定 deadzone：具名常數，raw 軸 0.08–0.10 區間內定值，寫入 profile schema |
| 端點覆蓋 ≥95%、中心 ±2%、靜置 RMS ≤0.5% 採樣合約 | Arm/Mode 預設鍵不重複＋去抖 ≤50 ms（runtime 行為） |
| 反向偵測與 G4B.UI2 各 10 次注入測試 | 油門低位為 arm 前置（preflight 同步阻擋） |
| `CalibrationProfile` 與採樣資料持久化 | sticky throttle 語意；KeyboardProfile fallback |
| | unknown 裝置 100% 擋下（注入測試，取代原反向注入） |

## 風險註記（誠實揭露）

固定映射不偵測**硬體不良**：中心漂移、端點磨損、雜訊超標的手把不會被主動抓出，玩家體感為「機體自行漂移／手感鈍」。緩解：
1. 固定 deadzone 吸收典型漂移。
2. 確認畫面顯示四軸即時值（漂移肉眼可見）。
3. preflight 面板保留 Throttle low 狀態燈。
殘餘風險由維護者接受（私下發行、目標用戶自有近代手把）。

## 連動

- **G4B.UI2** 改寫為「固定映射確認流程」gate（見 PRD v3.4）；G4B.3、G4B.UI1、G5.6 措辭連動修訂，門檻數值（30/90 秒、30 Hz、50 ms）不變。
- **#49**：持久化對象改為「已確認映射＋schema version」。
- **#41**：Channel Monitor 顯示來源收斂為 raw/normalized/固定 deadzone/按鍵狀態（無採樣端點/中心資料）。
- **Superseded**：`docs/gamepad-calibration-contract.md`（保留檔案加註記，留審計軌跡）。
