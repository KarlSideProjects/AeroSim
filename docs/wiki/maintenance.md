---
title: AeroSim Wiki 維護與來源規則
aliases:
  - AeroSim wiki maintenance
status: maintained
sources:
  - .github/TRIAGE.md
  - .github/workflows/docs-ci.yml
  - docs/product_capabilities.md
last_verified: 2026-07-26
---

# AeroSim Wiki 維護與來源規則

Wiki 是衍生導覽：PRD、能力記錄、ADR、決策、設定、程式碼與測試才是權威來源。每個頁面
必須保有可解析的來源、唯一別名與最後驗證日期；核心索引必須涵蓋每個 Wiki 頁面。

`title` 一律使用繁體中文。`aliases` 必須是非空清單，並至少包含一個穩定英文別名；可
視搜尋需求加入繁體中文別名，但不可與其他頁面重複。`sources` 也必須是非空清單，且每筆
都要指向 repository 內的權威來源或本 repository 的 GitHub issue／pull request。

Wiki metadata 的 `status` 只使用 `maintained`、`historical` 或 `superseded`。頁面內的
產品能力則使用 **Available**、**Foundation**、**Confirmed target**；相容性主張必須明確
標示為 **verified**、**target** 或 **unsupported**，不能以模糊成功取代未支援行為。

未來的同步 agent 只會提出最小 Wiki PR，並保留人工審核。issue 內容是未信任資料；只有
經維護者核准的來源才能影響可寫入 agent 的 Wiki 同步。
