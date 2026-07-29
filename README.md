# AeroSim

Godot 4.7 + C++ GDExtension 的最小專案骨架。

## 產品文件

- [產品功能與特性](docs/product_capabilities.md)：AirSim-class 最低成果、能力邊界、驗收證據與目前實作狀態。
- [產品需求文件](PRD_AeroSim.md)：v4.1 AirSim-class minimum、既有基礎 gate 與 Ubuntu qualification 計畫。
- [Player Mode Xbox 操作說明](docs/player_mode_xbox_controls.md)：Mode 2 控制、受控起飛、Assisted Hold 與 Controller Monitor 判讀。
- [AirSim 參考政策](docs/airsim_reference_policy.md)：鎖定版本、上游 issue 稽核與引用證據要求。

## 環境需求

- Godot `4.7-stable`
- Python 3
- `g++` 或相容 C++17 compiler
- `scons`（若本機沒有，`scripts/verify_issue_11.sh` 會安裝到 `.deps/venv`）
- `godot-cpp`：固定 commit 已隨 repo 放在 `third_party/godot-cpp/`，不需要另外下載

## 快速開始（Linux）

```bash
git clone https://github.com/jhihweijhan/AeroSim.git
cd AeroSim
git switch main
```

先建置 GDExtension；`godot-cpp` 已包含在 repo，不需另外下載：

```bash
python3 -m pip install --user scons  # 若 scons 尚未安裝
GODOT_CPP_DIR=third_party/godot-cpp scons target=template_debug platform=linux
```

設定 Godot 4.7 執行檔後啟動編輯器：

```bash
export GODOT_BIN=/path/to/Godot_v4.7-stable_linux.x86_64
"$GODOT_BIN" --editor --path .
```

在編輯器按 `F6` 執行目前的 smoke 場景，或按 `F5` 執行專案主場景。也可不開編輯器直接執行：

```bash
"$GODOT_BIN" --path .
```

## 版本鎖定政策

鎖定值記錄於 `docs/versions/godot-4.7.lock`：

- Godot `4.7-stable`
- Linux x86_64 editor SHA-256
- export templates SHA-256
- godot-cpp commit

任何 Godot engine、export template 或 godot-cpp 升級都必須重跑 G0-G3 全部 Gate。

## 啟動遊戲

專案的主場景是 `levels/smoke/smoke.tscn`。Linux 上可用 Godot 4.7 編輯器啟動：

```bash
GODOT_BIN=/path/to/Godot_v4.7-stable_linux.x86_64
"$GODOT_BIN" --editor --path .
```

在 Godot 編輯器按 `F6` 執行目前場景，或按 `F5` 執行專案主場景。也可以直接執行遊戲：

```bash
"$GODOT_BIN" --path .
```

若啟動時出現找不到 `libaerosim_native`，回到 repo 根目錄重新建置：

```bash
GODOT_CPP_DIR=third_party/godot-cpp scons target=template_debug platform=linux
```

啟動後依畫面上的控制提示操作；Xbox 手把會顯示對應的手把按鍵，未連接手把時可使用鍵盤提示。

## 外部 Ground Station Panel（GSP）

GSP 是開發／調校用的獨立瀏覽器面板；飛行中的操作仍在 Godot 內完成。它只在 debug build 啟用，並要求 Godot 使用原生 Wayland。無須設定啟動參數：模擬器會在啟動時改為 borderless windowed、在 `127.0.0.1` 的 8765–8769 間選一個可用埠，並將面板安裝到 Godot 的 user-data 目錄（Ubuntu 通常是 `~/.local/share/godot/app_userdata/AeroSim/gsp/`）；在暫停選單按 `OPEN GSP PANEL` 才開啟瀏覽器面板。

這是使用者觸發的開啟請求，較符合 Wayland 的焦點規則；若仍未看到瀏覽器分頁，按 `COPY GSP URL`，再將網址貼到既有瀏覽器的位址列。面板連線所需的 token 每次啟動都會重新產生。Godot 的 stdout 會印出 `GSP panel URL: file://...#port=...&token=...`；在 **模擬器仍在執行時**，複製完整 URL 到 Firefox 或 Chromium 的網址列即可開啟同一個面板。不要自行刪除 fragment 的 token，也不要把該 URL 分享給其他人；它授予本機模擬器這次執行期的控制權。停止模擬器後，該 URL 與 token 都會失效。

若 GSP 無法啟動（例如不是原生 Wayland 或埠已被佔用），模擬器本身仍可正常執行；請查看 Godot 輸出中的錯誤訊息。

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
GODOT_CPP_DIR=third_party/godot-cpp scons target=template_debug platform=linux
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
5. 使用 repo 內鎖定 commit 的 godot-cpp，建置 Linux GDExtension。
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
