# Xbox Default Profile 設計

## 目標

以固定、版本化的 Xbox 360 相容手把映射取代手動校準精靈。只有 `Input.is_joy_known()` 為真的 SDL-mapped 手把可使用此映射；玩家確認「使用 Xbox 預設配置」後即可進入 Quick Fly。

## 流程

1. 偵測到 SDL-mapped Xbox 相容手把時，主選單與 Quick Fly 顯示「使用 Xbox 預設配置」、固定映射及四軸 raw/normalized 即時值。
2. 玩家確認後，建立有效的 session `GamepadProfile` 並進入 preflight。
3. 未確認的已知手把不進入飛行，也不開啟校準精靈。
4. unknown 裝置明確提示不支援並提供 KeyboardProfile fallback；禁止套用 Xbox 映射。
5. Settings > Controller 只顯示裝置、固定映射與「重設為 Xbox 預設配置」。

## 資料與範圍

`GamepadProfile` 保存固定 Xbox 四軸、預設且不同的 Arm/Mode、sticky throttle、具名固定 deadzone 常數（raw 軸 0.08-0.10，不能使用 action 預設 0.5）與 schema version；不包含採樣端點、中心、雜訊、反向校準或手動按鍵映射。#49 改為持久化玩家已確認的預設映射與 schema version，不處理校準資料。

移除 #40 的 CalibrationProfile、八步精靈、六項校準合約與相關注入測試。PRD 的 Controller Setup 與 G4B.UI2 改為固定映射確認、Quick Fly gate 及無手把 fallback 驗收。

## 驗證

自動化驗證固定映射完整性、deadzone 範圍、Arm/Mode 不重複且去抖 <=50 ms、unknown 裝置 100% 擋下、確認後進入 Quick Fly preflight、未確認手把被導向確認畫面及無手把 fallback。Linux headed 驗證確認畫面、四軸即時值、套用後 preflight 與 keyboard fallback。preflight 維持油門低位阻擋。維護者僅需以 Xbox 相容手把確認映射與飛行；不再進行校準流程。

## 邊界

不加入 RC、RadioProfile、手動映射、校準、匯入匯出或斷線重連。PR 關聯使用 `Refs #40`，不使用 `Closes #40`；維護者實機遊玩確認前 #40 保持 open。
