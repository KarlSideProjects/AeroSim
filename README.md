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
GODOT_CPP_DIR=/path/to/godot-cpp scons target=template_debug platform=linux
GODOT_BIN=/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 scripts/run_headless_smoke.sh --output build/headless_smoke.json --frames 5
```

`scripts/run_headless_smoke.sh` 會以 headless 模式執行 `common/smoke/headless_smoke.gd`，呼叫 `AeroSimNative.probe_value()`，依 `--frames` 或 `--seconds` 跑 physics ticks，並輸出 JSON。

## CI

GitHub Actions 會執行：

1. 原生 C++ 單元測試。
2. 授權掃描，並確認 GPL fixture 會 fail。
3. 下載並驗證 Godot `4.7-stable` Linux editor hash。
4. 下載鎖定 commit 的 godot-cpp，建置 Linux GDExtension。
5. headless smoke，確認 GDScript 可呼叫 native probe 並輸出檔案。
