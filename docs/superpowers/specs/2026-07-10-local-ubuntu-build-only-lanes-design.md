# 本機 Ubuntu 基準與行動 Build-Only Lane 設計

**目標：** 將維護者的 Ubuntu 工作站設為正式桌面效能基準，同時保留 Android 與 iOS 為僅 CI／build 的 lane，不再要求任何裝置實測驗收。

## 決策

### 桌面基準

凍結的 G0.1 桌面環境為：

- Ubuntu 26.04 LTS
- AMD Ryzen 9 7945HX with Radeon Graphics
- NVIDIA GeForce RTX 4060 Ti，driver 580.159.03

G0.1 的量測規則與 P99 ≤ 3 ms 門檻完全不變：Jolt 與 GDExtension 主執行緒合計、VSync off、10 秒 warmup、60 秒量測、240 Hz physics、1 kHz substep。效能 harness 會將此確切 CPU／GPU／工具鏈視為 `gate`，而非 `reference`。

### Android 與 iOS lane

Android 與 iOS 都保留為產品 lane，但在目前環境中是 build-only。

仍須執行的驗證：

- 平台 export/build smoke 與可用平台工具鏈上的 native unit test。
- 共用決定性重播、資產載入、renderer 設定與 profile-equivalence CI。
- Android APK artifact 與大小檢查。
- iOS 靜態／export 設定檢查；實際 iOS build smoke 在有 macOS/Xcode CI runner 前維持 `not verified`。

以下裝置相依項目為不適用，且不阻擋目前工作：行動 FPS/P99/Perfetto 證據、Android OTG 控制器測試、iOS MFi/VirtualJoystick 裝置測試、行動錄影、實機安裝流程、熱節流、高速攝影延遲與行動 crash-free soak test。它們必須標為不適用，絕不可標示為通過。

此變更不豁免桌面裝置相依 gate、shared-core DEV-M/USR/LEG gate，亦不下修任何桌面數值門檻。

## 單一依據與 issue 狀態

PRD 會新增簡短的當前環境政策並連到決策文件。該決策文件是 Android/iOS 裝置相依 gate 的完整例外依據，避免逐一改動後續每個 Phase 表格，同時保留未來有設備時的數值需求。

- #17 從舊的 Ryzen 5 5600／GTX 1660S 前置改為本機 Ubuntu 基準；只有新的 gate 報告、完整 CI 與獨立 adversarial review 都通過後才關閉。
- #18 與 #55 成為 build-only 實作追蹤；body 會區分必要自動化檢查、不適用的實機檢查與 iOS 缺少 macOS build 環境的限制。
- 此政策不宣稱 Android/iOS 已可發行。

## 最小實作

1. 新增 `docs/decisions/2026-07-10-local-ubuntu-build-only-lanes.md`，記錄以上決策與明確的非宣稱。
2. 僅更新 `PRD_AeroSim.md` 中命名 G0.1 桌面硬體、行動基準裝置、G0.2/G0.5/G0.P 實機證據與驗收方法學基準規則的段落；完整行動例外清單連到決策文件。
3. 更新 `README.md`、`scripts/performance_report.py`、`scripts/run_performance_benchmark.sh` 與 `.github/workflows/performance-gpu.yml`，使本機 Ubuntu 成為正式 G0.1 gate 環境。
4. 更新舊 CPU/GPU eligibility 斷言的測試；重新產生 committed off/on G0.1 報告為 `gate` 報告，並要求 P99 verdict 通過。
5. 更新 #17、#18、#55 的驗收文字與 labels。#17 僅在新的證據與獨立審查後關閉；#18/#55 在其餘 build-only 工作完成前保持開啟。

## 驗證

- 報告單元測試拒絕舊 5600/1660S 身分，只接受本機 Ubuntu CPU/GPU 加上鎖定 Godot provenance 的 gate mode。
- 本機 headed gate run 的 off/on 每份都有 14,400 samples、P99 ≤ 3 ms、`gate_eligible=true`，且比較 metadata 一致。
- real-GPU workflow 在 self-hosted 本機執行 `gate` mode，並保存兩份 JSON/SVG artifact。
- Android CI 保持綠燈。Ubuntu 上 iOS 裝置／build 狀態明確為 `not verified`，不靜默跳過或回報通過。
- PRD 與 issue 文字不再宣稱本環境已實測任何 Android/iOS 實體裝置。

## 非目標

- 不以模擬器取代真實裝置的效能、控制器、熱、延遲證據。
- 不宣稱 Android 或 iOS 可發行。
- 不下修任何桌面門檻。
