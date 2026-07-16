# AeroSim

Godot 4.7 + C++ GDExtension 的最小專案骨架。

## 產品文件

- [產品功能與特性](docs/product_capabilities.md)：AirSim-class 最低成果、能力邊界、驗收證據與目前實作狀態。
- [產品需求文件](PRD_AeroSim.md)：v4.1 AirSim-class minimum、既有基礎 gate 與 Ubuntu qualification 計畫。
- [AirSim 參考政策](docs/airsim_reference_policy.md)：鎖定版本、上游 issue 稽核與引用證據要求。

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
GODOT_BIN=/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 scripts/run_headless_smoke.sh --output build/headless_smoke.json --frames 5
```

`scripts/run_headless_smoke.sh` 會以 headless 模式執行 `common/smoke/headless_smoke.gd`，呼叫 `AeroSimNative.probe_value()`，依 `--frames` 或 `--seconds` 跑 physics ticks，並輸出 JSON。

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
7. Linux headed acceptance 與 release artifact checks。
8. Linux replay terminal-state artifact 與 build provenance 檢查。

## Ubuntu DEV-M 授權 fixture

要先驗證「啟用後可以玩、斷網仍可進入 grace」時，不需要 production private key。使用下列腳本在 `build/` 產生一次性的 ephemeral RSA-2048 key、license key、SQLite license database、Godot provider config，以及本機 server 啟動器：

```bash
scripts/test_license_dependencies.sh
scripts/generate_devm_license_fixture.sh
```

腳本預設輸出到 `build/devm-license-fixture/`。它不會把 private key 或 license key 印到 console，也不會修改 repo 內的 production key/config。啟動本機 server：

```bash
build/devm-license-fixture/start_server.sh
```

將產生的 `license_provider.json` 傳給 Godot 的 `LicenseProvider.configure_from_path()`，再以 `license.key` 的內容呼叫 `activate()`：

```gdscript
var provider := preload("res://common/license/license_provider.gd").new()
add_child(provider)
assert(provider.configure_from_path("/absolute/path/to/build/devm-license-fixture/license_provider.json").ok)
var license_key := FileAccess.get_file_as_string("/absolute/path/to/build/devm-license-fixture/license.key").strip_edges()
var activation := await provider.activate(license_key)
assert(activation.ok)
assert(provider.get_snapshot().status == "online_valid")
```

測試斷網 grace 時，先保留 Godot 的 state file，再停止 `start_server.sh`；provider 應回報 `offline_grace_valid`。fixture 的 private key、license key、database 都只存在 `build/devm-license-fixture/`，測試完成後刪除整個目錄：

```bash
rm -rf build/devm-license-fixture
```

這是 DEV-M 整合測試資料，不是 production 金鑰流程；production private key 仍必須由外部 secret store 管理。
