# AeroSim

Godot 4.7 + C++ GDExtension 的最小專案骨架。

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
AEROSIM_BETAFLIGHT_SITL_ADAPTER=/path/to/betaflight-sitl-adapter python3 scripts/sitl_cross_validate.py
GODOT_CPP_DIR=/path/to/godot-cpp scons target=template_debug platform=linux
GODOT_BIN=/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 scripts/run_headless_smoke.sh --output build/headless_smoke.json --frames 5
```

`scripts/run_headless_smoke.sh` 會以 headless 模式執行 `common/smoke/headless_smoke.gd`，呼叫 `AeroSimNative.probe_value()`，依 `--frames` 或 `--seconds` 跑 physics ticks，並輸出 JSON。

`scripts/sitl_cross_validate.py` 是 G2.9 開發工具：它要求外部 Betaflight SITL adapter executable，透過 stdio CSV 隔離 GPL 邊界，輸出 `build/sitl_cross_validation.json`；未提供 adapter 時會 `not verified` 失敗，不會 mock。

## G0.6a 決定性與重播

- `SConstruct` 與 `scripts/test_native.sh` 都關閉 fused multiply-add contraction：GCC/Clang 使用 `-ffp-contract=off`，Windows MSVC GDExtension 使用 `/fp:strict`。
- `src/native/aerosim_replay.hpp` 提供 `FlightCommand` frame 錄製與 `replay_angle_mode` 重播；`tests/native/test_replay.cpp` 驗證同平台相同輸入序列 bitwise replay。
- G0.6a 跨平台終端容忍固定在共用核心：姿態差 `<= 0.5` 度、位置差 `<= 0.05` m。

## CI

GitHub Actions 會執行：

1. Linux 原生 C++ 單元測試。
2. 授權掃描，並確認 GPL fixture 會 fail。
3. 授權伺服器 API 整合測試。
4. 下載並驗證 Godot `4.7-stable` Linux editor hash。
5. 下載鎖定 commit 的 godot-cpp，建置 Linux GDExtension。
6. headless smoke，確認 GDScript 可呼叫 native probe 並輸出檔案。
7. Windows 原生 C++ 單元測試與 GDExtension 建置。
8. Android emulator 執行同一組原生 C++ 單元測試，並建置 Android arm64 GDExtension。
9. Linux / Windows / Android replay terminal-state artifacts 互相比對 G0.6a tolerance。
10. 若設定 `AEROSIM_BETAFLIGHT_SITL_ADAPTER` repo variable，Linux job 會額外跑 G2.9 SITL 交叉驗證，報告存 self-hosted runner Local Folder。
