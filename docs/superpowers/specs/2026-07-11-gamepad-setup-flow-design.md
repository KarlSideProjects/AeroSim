# #40 Gamepad Setup Flow 設計

## 目標

實作 Xbox 360 相容手把的校準精靈，讓玩家在單一 session 內完成四軸、Arm 和 Mode 的有效校準，並把已驗證的 `CalibrationProfile` 交給 Quick Fly 使用。

本設計對應 PRD v3.3 的 GamepadProfile、3.5.4 校準驗收合約和 G4B.UI2。所有數值門檻沿用 PRD：端點至少 95%、中心偏移不超過 2%、1 秒 RMS 不超過 0.5%、按鍵去抖不超過 50 ms。白話與樣本契約以 `docs/gamepad-calibration-contract.md` 為準。

## 範圍

包含：

- 固定八步精靈：裝置偵測、可用軸/按鍵監看、四軸指派、端點校準、反向偵測、Arm/Mode 指派、油門低位、測試懸停台。
- 可注入的校準樣本處理與 `CalibrationProfile`。
- 六項校準合約的具名拒絕原因與畫面提示。
- 只在本次遊戲 session 內將驗證 profile 套用到 Quick Fly。
- 自動化紅綠樣本、Linux headed 證據和維護者遊玩驗收交接。

不包含：

- 跨 session 落盤、factory reset、匯入匯出、斷線重連。這些由 #49 在 #40 交付 profile schema 後實作。
- RC 遙控器、RadioProfile 或 16 通道支援。
- PR #106 正在修改的 ACRO 搖桿讀取函式。

## 架構

`GamepadCalibration` 是不依賴 Godot input singleton 的校準核心。它接收可注入的軸樣本和按鍵事件，維護當前精靈步驟，最後只產生兩種結果：完整 `CalibrationProfile` 或具名拒絕碼。

`CalibrationProfile` 包含四個唯一軸映射、各軸端點/中心/deadzone 資訊、反向旗標、Arm/Mode 按鍵與 sticky throttle 語意。資料只能在六項合約都通過後建立，避免 runtime 持有半成品校準資料。

Setup UI 只顯示核心所回報的步驟、即時樣本和拒絕原因；它不自行計算門檻。完成時 UI 將 profile 交給 runtime 的 session 狀態。Quick Fly 讀取該 session profile：存在且有效時進入 preflight，否則導向 Setup；無手把時維持既有 KeyboardProfile fallback。

`flight_runtime.gd` 的改動限於 Setup 入口、session profile 接收與 Quick Fly 的校準判斷。不得修改 PR #106 所改的 `_acro_roll_stick`、`_acro_pitch_stick`、`_acro_yaw_stick` 與 `_gamepad_axis`。

## 校準流程

1. 偵測至少一個 Xbox 360 相容手把；沒有裝置時顯示 KeyboardProfile fallback。
2. 顯示所有可用軸與按鍵的 raw/normalized live monitor。
3. 對 roll、pitch、yaw、throttle 各指派一個不同軸；重複軸立即拒絕。
4. 以採樣結果驗證每軸的端點覆蓋、中心偏移與靜置 RMS。
5. 由指定移動方向判定反向，寫入 profile 的方向旗標。
6. 指派不同的 Arm/Mode 按鍵，並以 50 ms 視窗拒絕按鍵彈跳。
7. 只有油門位於低位時允許 profile 完成。
8. 測試懸停台消費已驗證 profile；成功後 session 內的 Quick Fly 可直接進入 preflight。

## 失敗語意

每個未通過項都停留在目前步驟、阻止 profile 交付並顯示具名原因。失敗原因至少區分：未偵測手把、軸重複、端點不足、中心偏移、靜置雜訊、按鍵重複、按鍵彈跳與油門非低位。

任何缺少必需樣本、非有限數值或未知裝置狀態都 fail loud，不以預設映射或鍵盤資料補足。因為 #49 未完成，重啟後的校準消失必須明確標為未實作持久化，而非宣稱跨 session 保留。

## 驗證

自動化驗證以注入樣本執行：一組好手把樣本必須建立 profile；六組壞手把樣本必須各自被對應合約拒絕。軸反向與端點不足各重複 10 次，全部應被主動提示，符合 G4B.UI2。

額外驗證固定精靈順序、拒絕時 profile 不可用、完成後 session Quick Fly 進入 preflight，並明確不測跨 session persistence（#49 範圍）。

Linux 實測按固定順序進行：自動化通過後，在本機真實 display 執行 headed walkthrough，保存截圖、active Camera3D、非單色和可觀察操作回饋。完成後在 #40 @jhihweijhan 請求遊玩驗收；未收到確認前 issue 保持 open。

## 衝突與整合

開工前已比對 PR #106：其對 `flight_runtime.gd` 的變更僅限 ACRO 搖桿讀取函式。本票不得修改該區段。若 #106 更新而觸及本設計的 Setup 或 Quick Fly 區段，立即停止平行修改，在 #40 留心跳並依 #56 改選不重疊工作。

完成時開 draft PR 並以 `Closes #40` 關聯。獨立對抗式審查的 Critical/High 發現全部修正後，才可 rebase、等待 CI 全綠並 squash merge；但人工遊玩驗收未確認前，不關閉 issue 或解鎖 #49。
