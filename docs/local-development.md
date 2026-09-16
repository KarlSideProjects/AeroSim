# 本機面板與授權測試

[返回 README](../README.md)

本頁保留開發面板及 DEV-M fixture 的操作細節；一般建置與啟動請先閱讀 README。

## 外部 Ground Station Panel（GSP）

GSP 是開發／調校用的獨立瀏覽器面板；飛行中的操作仍在 Godot 內完成。它只在 debug build 啟用。一般除錯流程無須設定啟動參數：模擬器會在啟動時改為 borderless windowed、在 `127.0.0.1` 的 8765–8769 間選一個可用埠，並將面板安裝到 Godot 的 user-data 目錄（Ubuntu 通常是 `~/.local/share/godot/app_userdata/AeroSim/gsp/`）；在暫停選單按 `OPEN GSP PANEL` 才開啟瀏覽器面板。

這是使用者觸發的開啟請求，較符合 Wayland 的焦點規則；若仍未看到瀏覽器分頁，按 `COPY GSP URL`，再將網址貼到既有瀏覽器的位址列。面板連線所需的 token 每次啟動都會重新產生。Godot 的 stdout 會印出 `GSP panel URL: file://...#port=...&token=...`；在 **模擬器仍在執行時**，複製完整 URL 到 Firefox 或 Chromium 的網址列即可開啟同一個面板。不要自行刪除 fragment 的 token，也不要把該 URL 分享給其他人；它授予本機模擬器這次執行期的控制權。停止模擬器後，該 URL 與 token 都會失效。

若 GSP 無法啟動（例如埠已被佔用），模擬器本身仍可正常執行；請查看 Godot 輸出中的錯誤訊息。

## Ubuntu DEV-M 授權 fixture

要先驗證「啟用後可以玩、斷網仍可進入 grace」時，不需要 production private key。使用下列腳本在 `build/` 產生一次性的 ephemeral RSA-2048 key、license key、SQLite license database、Godot provider config，以及本機 server 啟動器：

需 Python 3.11；可透過 `PYTHON_BIN` 指定對應執行檔。

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
