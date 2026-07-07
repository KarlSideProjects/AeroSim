# Tier 2 — Betaflight SITL 專業模組

本產品不提供 Tier 2（Betaflight SITL 真韌體橋接）作為出貨模組。產品僅出 Tier 1 自研飛控。

## Why this is out of scope

維護者於 2026-07-08 triage 會話決策放棄 Tier 2，理由：

- **法務成本與商業價值不成比例**：PRD G7.1 要求法務書面核准為開發前置（無共享記憶體/連結之隔離架構文件、GPL binary/source/build script 一一對應、每次私下交付同步履行 GPL-3.0 原始碼義務——剛性約束 C-3 明定私下提供仍構成散布）。本產品為私下提供的小規模發行，聘請法務審查 GPL 隔離架構的成本高於 Tier 2 帶來的價值。
- **維運負擔**：每次交付客戶都須同步履行原始碼義務（G7.1 交付清單），對小規模私下發行是持續性負擔。
- **產品主體不受影響**：Tier 1 自研飛控有自己的擬真驗收路徑（G2.7 盲測、G2.8 blackbox 重播真值），不依賴 Betaflight 韌體。

## 界線澄清（未被排除的部分）

- **G2.9 SITL 交叉驗證（#27）不受影響**：Betaflight SITL 作為*開發環境工具*做自研飛控健全性檢查，不隨產品發布、不進入 Tier 1 產物，與 Tier 2 出貨模組是兩回事。
- Tier 3（PX4 SIH，BSD 3-Clause）不在本紀錄範圍，維持 PRD「後期評估」狀態。
- 若未來出現明確的 Tier 2 商業需求（客戶指名要真韌體），刪除本檔並重啟 G7.1 法務流程即可。

## Prior requests

- #10 — [Epic] Phase 7 — Betaflight SITL 專業模組（Tier 2）
- #54 — Tier 2 法務核准前置（G7.1）
