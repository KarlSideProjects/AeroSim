# AeroSim 文件導覽

這裡是 AeroSim 的文件入口。AeroSim 是一個 **Simulation Platform**：Player Mode
供人操作，Lab Mode 供軟體控制與觀測；它不只是 FPV 遊戲。

## 從哪裡開始

- 想快速建置、執行與測試：讀 [README](../README.md) 與 [AGENTS](../AGENTS.md)。
- 想知道產品邊界、驗收與交付目標：讀 [PRD](../PRD_AeroSim.md) 與
  [Product Capabilities](product_capabilities.md)。
- 想快速理解系統與名詞：讀 [開發者 Wiki](wiki/README.md)。Wiki 是可追溯導覽，
  不是權威規格的替代品。
- 想理解決策原因：讀 [ADR](adr) 與 [決策記錄](decisions)。
- 想理解外部整合與資料契約：讀 [AirSim reference policy](airsim_reference_policy.md)、
  [Hardware parameters](hardware_parameters.md)、[Telemetry snapshot](telemetry_snapshot.md)、
  [Dataset recording](dataset_recording.md) 與 [Python oracles](python_oracles.md)。
- 想執行或恢復發行流程：讀 [Release delivery SOP](release_delivery_sop.md)、
  [License server](license_server.md) 與 [Diagnostic support bundle](diagnostic_support_bundle.md)。

## 權威來源地圖

| 問題 | 權威來源 |
| --- | --- |
| 產品範圍、驗收與交付門檻 | PRD 與 Product Capabilities |
| 為什麼採取某項架構或流程 | ADR 與決策記錄 |
| 實際可執行行為 | source code、設定與測試 |
| AirSim 適配研究與授權處置 | AirSim reference policy 與其 audit |
| 專案用語 | [CONTEXT](../CONTEXT.md) |

文件中的衍生說明必須連回這些來源；遇到衝突時，以權威來源為準。
