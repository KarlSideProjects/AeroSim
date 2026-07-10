# 2026-07-10 — 本機 Ubuntu 基準與行動 build-only 車道

| 欄位 | 內容 |
|---|---|
| 決策日期 | 2026-07-10 |
| 決策人 | Karl（維護者） |
| 對應 issue | #17、#18、#55 |

## 凍結桌面 G0.1 環境

G0.1 的正式 gate 僅在目前本機環境成立：Ubuntu 26.04 LTS、AMD Ryzen 9 7945HX with Radeon Graphics、NVIDIA GeForce RTX 4060 Ti（driver 580.159.03）。維持既有剛性協定：Jolt、240 Hz physics、1 kHz native 子步進、VSync off、10 秒 warmup、60 秒量測與物理 P99 ≤ 3 ms。任何其他 CPU、GPU、Godot/godot-cpp provenance 或無 headed 顯示的結果都不是 G0.1 gate。

## Android 與 iOS 的 build-only 邊界

Android 與 iOS 仍保留 source、export/build smoke、native tests、replay、資產與 renderer/profile 檢查；Android 另保留 APK artifact 與大小檢查。iOS 保留 export 設定的靜態檢查；在 macOS/Xcode CI runner 可用前，實際 iOS build smoke 為 **not verified**。

目前沒有 Android 或 iOS 實機，因此下列均為 **N/A**，不得標示為 pass：行動 P99/FPS/Perfetto、Android OTG、iOS MFi/VirtualJoystick、實機錄影、安裝、溫度、high-speed latency 與 crash-free session。這只界定行動裝置依賴的驗收，並不豁免桌面裝置專屬、shared-core、DEV-M、USR、LEG 或任何桌面數值門檻。

本決策就目前環境覆寫 `G0.10-ios-lane.md` 的 Ad Hoc 實機部署與裝置驗收動作；iOS Lane 仍保留為未來可恢復的 build-only 車道，而非關閉或通過。
