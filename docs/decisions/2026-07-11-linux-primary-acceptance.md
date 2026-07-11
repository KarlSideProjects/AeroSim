# 2026-07-11 — Linux 實測主車道（Linux-primary acceptance）

| 欄位 | 內容 |
|---|---|
| 決策日期 | 2026-07-11 |
| 決策人 | Karl（維護者） |
| 對應 issue | #52、#18、#46、#48、#53、#55、#93、#56 |
| 關係 | 將 `2026-07-10-local-ubuntu-build-only-lanes.md` 的 build-only 邊界從行動平台**推廣到所有非 Linux 平台**；G0.1 環境凍結不變 |

## 裁定

### 1. Linux 是唯一實測平台

所有 runtime／遊戲性／效能／操作類 gate 的實測證據，只在 Linux（G0.1 凍結之本機 Ubuntu 環境）上取得。

### 2. Linux 實測序列（固定順序，不得跳關）

1. **自動化**：native 單元測試、headless smoke、CI 全綠。
2. **Godot headed 測試優先**：#83 harness（截圖序列、active Camera3D、畫面非單色、操作有可觀察回饋）；UI／場景／可玩類證據以 headed 為準，headless 綠燈不得單獨放行（#14 事故教訓）。
3. **完成後交 human**：前兩層全過，才 @維護者做遊玩驗收，此為最後一關。不得跳過 headed 直接丟給人工，也不得以人工驗收替代自動化證據。

### 3. 非 Linux 平台一律「build 能過」為主

Windows／macOS／Android／iOS 的驗收 = **source build／export 成功 + 既有 CI 自動測試**（跨平台單元測試、G0.6a replay-compare、授權掃描、artifact 尺寸、簽章完整性）。不新增實機或人工驗收；平台專屬實測 gate 一律標 **N/A（未驗證凍結）**，不得標 pass。依 PRD 1.4，Lane 獨立，凍結不阻擋主線。

### 4. 逐平台對照

| 平台 | 保留 | 轉 N/A（未驗證凍結） |
|---|---|---|
| Windows | build、安裝包尺寸（G6.1）、CI 單元/replay | G5.1 控制器實機（Win 分）、G6.4 冷啟動（Win 分）、Windows 端實測效能 |
| macOS（#92 到位後） | build、簽章＋公證（`spctl` 屬產物完整性，保留）、安裝包尺寸 | 冷啟動、控制器實機（macOS 分）等實測（#93 範圍隨之縮減） |
| Android | export、release 簽章 APK、尺寸（G6.1）、側載**文件**（G6.2 文件分）、CI 單元/replay | 實機側載、行動冷啟動（G6.4 行動分）、OTG、行動效能（沿用 2026-07-10 決策） |
| iOS | export 設定靜態檢查；#92 後 build smoke | 全部實機項（沿用 2026-07-10 決策與 G0.10 覆寫） |

- **G6.5 封測**：以 Linux 交付版為封測對象；其他平台 build 產物可隨附，不設 crash-free 門檻。
- **G5.4 端到端延遲、G2.7/G3.8 盲測**等 USR/DEV-M 項：於 Linux 環境執行。
- **#92（Apple 建置環境）不受影響**：macOS/iOS 連 build 都需要 Mac，build-only 車道仍以 #92 為前置。

### 5. 非下修聲明

門檻**數值**一律不變；本裁定是驗收**平台範圍**調整，依 PRD 1.4「Lane 獨立、未過僅凍結該 Lane」結構成立。所有 N/A 項為「未驗證凍結」而非通過；未來某平台出現實測需求（客戶指名、取得實機）時，解凍該 Lane 恢復原實測 gate 即可，不需修改 PRD 門檻。

### 6. 對進行中 issue 的即時影響

- **#52**：維護者人工項縮減為 G6.7 交付演練一項（Android 實機側載與行動冷啟動計時取消）；Windows 冷啟動量測取消，G6.4 實測僅 Linux。
- **#18**：範圍即為 build/export smoke ＋既有 CI 自動檢查（OTG／行動效能維持 N/A）。
- **#46／#48**：實機驗收部分 N/A；#48 的 G5.1/G5.2/G5.4 實測僅 Linux。
- **#55／#93**：解凍後亦為 build-only 車道。
