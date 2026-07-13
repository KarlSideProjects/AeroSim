# AeroSim

Godot 4.7 + C++ GDExtension 的最小專案骨架。

## 開發決策流程

PRD 從初始規劃到目前的開發決策演進（Mermaid 總覽圖、各決策節點的原計畫／變動／驅動因素／出處、治理機制演進）：見 [docs/development-decision-flow.md](docs/development-decision-flow.md)。PRD 正本為 [PRD_AeroSim.md](PRD_AeroSim.md)（#1 pinned）。

## 環境需求

- Godot `4.7-stable`
- Python 3
- `g++` 或相容 C++17 compiler
- `scons`（若本機沒有，`scripts/verify_issue_11.sh` 會安裝到 `.deps/venv`）
- `godot-cpp`：`scripts/verify_issue_11.sh` 會 checkout 到 `docs/versions/godot-4.7.lock` 指定 commit

## 版本鎖定政策

鎖定值記錄於 `docs/versions/godot-4.7.lock`：

- Godot `4.7-stable`
- Linux x86_64 editor SHA-256
- export templates SHA-256
- godot-cpp commit

任何 Godot engine、export template 或 godot-cpp 升級都必須重跑 G0-G3 全部 Gate。

## 建置與測試

```bash
GODOT_BIN=/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 scripts/verify_issue_11.sh
```

拆開執行：

```bash
scripts/test_native.sh
python3 scripts/check_licenses.py
scripts/test_license_scan.sh
python3 -m unittest license_server.test_license_server
GODOT_CPP_DIR=/path/to/godot-cpp scons target=template_debug platform=linux
GODOT_BIN=/path/to/Godot_v4.7-stable_linux.x86_64 scripts/run_gut_tests.sh
GODOT_BIN=/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 scripts/run_headless_smoke.sh --output build/headless_smoke.json --frames 5
```

`scripts/run_headless_smoke.sh` 會以 headless 模式執行 `common/smoke/headless_smoke.gd`，呼叫 `AeroSimNative.probe_value()`，依 `--frames` 或 `--seconds` 跑 physics ticks，並輸出 JSON。

## G0.1 headed 效能量測

```bash
GODOT_BIN=/path/to/Godot_v4.7-stable_linux.x86_64 scripts/run_performance_benchmark.sh --effects off --output build/performance-effects-off.json
GODOT_BIN=/path/to/Godot_v4.7-stable_linux.x86_64 scripts/run_performance_benchmark.sh --effects on --baseline-report build/performance-effects-off.json --output build/performance-effects-on.json
```

Runner 預設為 G0.1 gate，只接受本機 Ubuntu 26.04 LTS 的 AMD Ryzen 9 7945HX with Radeon Graphics 與 NVIDIA GeForce RTX 4060 Ti、鎖定工具鏈及 headed 顯示環境。正式量測固定為 10 秒 warmup + 60 秒模擬時間、240 Hz Jolt + 1 kHz native 子步進、VSync off，P99 必須 ≤ 3 ms；只有明確的 `--mode smoke` 可縮短時間，且 smoke 不會輸出 G0.1 gate verdict。Runner 會先用鎖定的 godot-cpp checkout 重建 debug GDExtension，再把 Godot 版本與 SHA-256、godot-cpp commit、GDExtension SHA-256、native source SHA-256 寫入 JSON。報告另保存逐 physics-frame 原始樣本、P95/P99、render CPU/GPU 分列、環境與 Git revision，並同步輸出 SVG 圖表。

目前單機 on/off workload 的 `active_effects` 明列為 A3 drag 與 A4 ground effect；A5 downwash 需要雙機相對位置與逐幀交互作用，未整合前不納入本單機效能差分。

`.github/workflows/performance-gpu.yml` 每日 02:00（Asia/Taipei；18:00 UTC）或手動執行相同的 10+60 秒 G0.1 gate protocol。它只能排程到標記為 `aerosim-7945hx-4060ti` 的本機 self-hosted runner，要求真實 RTX 4060 Ti，以跨 runner lock 串行化量測，並把 JSON/SVG 存到 self-hosted runner 的 `performance-gpu` local artifact 目錄；Xvfb/lavapipe 只保留在一般 CI 的流程 smoke。

## G0.6a 決定性與重播

- `SConstruct` 與 `scripts/test_native.sh` 都關閉 fused multiply-add contraction：GCC/Clang 使用 `-ffp-contract=off`，Windows MSVC GDExtension 使用 `/fp:strict`。
- `src/native/aerosim_replay.hpp` 提供 `FlightCommand` frame 錄製與 `replay_angle_mode` 重播；`tests/native/test_replay.cpp` 驗證同平台相同輸入序列 bitwise replay。
- G0.6a 跨平台終端容忍固定在共用核心：姿態差 `<= 0.5` 度、位置差 `<= 0.05` m。

## CI

GitHub Actions 會執行：

1. 非阻擋 recovery-mode shadow 先執行同一套 GUT，累積未來升級為 pre-build gate 的可靠度證據。
2. Linux 原生 C++ 單元測試、授權與 API 檢查。
3. 下載鎖定的 Godot / godot-cpp，建置一次 Linux debug GDExtension。
4. 阻擋式 GUT 先把關，再以同一份 debug build 執行 headed acceptance、效能 harness smoke 與 headless smoke。
5. Linux release export，以及 Windows、Android 的原生測試、GDExtension 與 release export。
6. Linux / Windows / Android replay terminal-state artifacts 互相比對 G0.6a tolerance。

一般 PR 仍保留完整平台與 runtime coverage；feature branch push 不再與 PR 重複觸發同一份 CI。`push` 僅用於 `main`，另保留手動 `workflow_dispatch`。同一 PR 的較舊執行會被取消，但 main build 不會被自動取消。
