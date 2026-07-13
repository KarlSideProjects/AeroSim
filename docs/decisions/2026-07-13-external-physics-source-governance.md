# 2026-07-13 — 外部物理來源治理：Formula Port + offline Oracle（PRD v3.5）

| 欄位 | 內容 |
|---|---|
| 決策日期 | 2026-07-13 |
| 決策人 | Karl（維護者，經 #115 triage 會話裁定） |
| 對應 issue | #115 |
| 性質 | **既有架構治理正式化，非門檻調整** |

## 裁定內容

1. 外部 simulator（包括 gym-pybullet-drones、RotorPy）僅可作為 source-file-level Formula Port 來源，以及鎖定版本、可離線執行的開發／測試 Oracle。AeroSim 現有 A3–A5 Formula Port 與 Python Oracle 架構因此獲正式治理定位。
2. AeroSim C++ fixed-step core + Godot/Jolt 是唯一 Tier 1 runtime state 與 collision authority。外部 simulator 不得成為 Tier 1 runtime dependency、Python per-frame path，或第二 collision authority；不採用外部 runtime engine replacement。
3. `c5d7f0b` 是廢棄且不可合併、不可續作的 unmerged governance spec，不構成已簽核決策或可延續的工作基線。

## 檔案級 Provenance

Formula Port 必須逐一記錄：

- source file 與 upstream commit；
- source-file header，以及該檔案 referenced source；
- license／attribution；
- unit／frame conversion；
- Oracle／analytic validation。

授權、GPL 邊界與上游 issue（含 closed）查證唯一依 #56「參考開源實作」條款執行，本決策不建立或重複平行政策。不明授權的常數或參數依 #56 僅可參考思路，不可作為產品資料；repo root 的 MIT 授權不會自動涵蓋常數表或資料。

## CI 稽核錨點與 Pending Ownership

- #116：NOTICE manifest regression。
- #117：Oracle integrity 與 offline cache。
- #119：export artifact 無 Python runtime dependency scan（必交付的 CI audit anchor）。

上述項目均為 pending ownership；本 docs PR 不實作它們，且不得將 #116 或 #117 表述為已完成。本決策不新增或調整任何數值 gate。

## 驅動因素

1. 保留既有 A3–A5 公式移植與 Python Oracle 的可重現、離線驗證能力。
2. 維持 AeroSim Tier 1 runtime 的固定步進狀態與碰撞權威單一來源，避免外部 runtime 依賴及雙重碰撞仲裁。
3. 讓每次 Formula Port 的來源、授權、座標與單位轉換、以及數值驗證可追溯，同時遵守 #56 的既有開源參考治理。
