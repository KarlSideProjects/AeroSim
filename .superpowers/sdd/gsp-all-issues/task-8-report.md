# Issue #248：預設值遷移安全流程報告

## 問題與目標

Issue #248 要求讓舊版 preset 在目前 tuning registry 改變時，可以先預覽差異，再由面板明確確認，最後沿用既有 GSP tuning 的 authoritative boundary 與 atomic commit 流程套用。流程必須防止 capability 被錯誤 preset、錯誤 registry、檔案變更、過期或重複使用；不能把 GPU vendor/type 寫死，也不能提前改變 runtime/native 狀態。

本次只實作 #248，保留 #241–#247 的既有 preset、tuning、WebSocket、panel 與 smoke 行為，不引入後續 issue 的功能。

## 實作方案

### Preset 分類與 capability

- 在 `GspPresetStore` 增加遷移分類：
  - `removed`：preset 有、目前 registry 沒有的參數。
  - `missing`：目前 registry 有、preset 沒有的參數，使用 registry default。
  - `out_of_range`：preset 值超出目前 descriptor 範圍，修正為 min/max。
- 預覽會回傳完整分類、修正後 values、preset content SHA-256，以及目前 registry hash。
- runtime 產生隨機 `migration_id`，capability 綁定 preset name、檔案 content hash、registry hash、修正後 values、建立時間與 30 秒 TTL。
- capability 最多保留 8 筆；超過上限淘汰最舊項目並記錄為 expired。
- apply 前檢查 name、檔案 hash、registry hash、migration id、TTL 與確認旗標；成功 apply 後立即消耗 capability 並記錄 used id，避免 replay。

### WebSocket 公開契約

新增兩個明確 operation：

- `preview_preset_migration`：只接受 `{name}`，只讀，回傳 `preset_ack` 與既有 identity envelope。
- `apply_preset_migration`：只接受 `{name, migration_id, confirmed}`，`confirmed` 必須是布林值 `true`，並沿用既有 tuning ACK/commit/error 契約。

錯誤情況包含未確認、missing、wrong、expired、stale、reused；錯誤不會進入 pending/staged/native commit。

### Panel 確認與 authoritative commit

- panel 增加 Preview migration 按鈕與 migration report 區塊，顯示三類差異及 original/default/corrected 值。
- 收到 preview ACK 後明確顯示需要確認，只有 `window.confirm(...) === true` 才送出 apply。
- apply 不建立第二套提交路徑，而是轉入既有 `gsp_tuning_batch_request(..., "preset", ...)`，於既有 authoritative boundary 由 native `stage_flight_tuning_batch` / `commit_flight_tuning` atomic commit。
- 同一 commit 的 origin peer 與 observer peer 都收到一致的 preset source、corrected/default values 與 tuning commit。

## 測試與驗證

先跑 focused tests：

- `node tests/test_gsp_panel_behavior.js`：PASS。
- `Godot --headless ... tests/headless/gsp_preset_contract.gd`：PASS。
  - 覆蓋分類、preview read-only、unconfirmed、wrong、missing、expired、stale、reused 與 panel contract。
- `Godot --headless ... tests/headless/gsp_preset_integration.gd`：PASS。
  - 使用兩個真實 WebSocket peer，覆蓋 preview、檔案變更 stale、confirmed apply、deferred boundary、atomic commit 與 observer broadcast。
- `git diff --check`：PASS。

在 implementation commit 的 HEAD 執行 brief 指定的完整 gate：

```text
RUNNER_TEMP=/tmp/aerosim-gsp-248 \
GODOT_BIN=/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 \
scripts/verify_issue_11.sh
```

結果：exit code `0`。

- native tests、license scan、Node panel test：PASS。
- SCons Linux GDExtension build：PASS。
- GUT：`277 tests, 0 failures, 0 errors`。
- native atomic boundary：PASS。
- GSP preset contract/integration、GSP tuning integration、Quick Adjust integration、GSP tuning stress：PASS。
- headed acceptance：PASS。
- complete-session replay integration：PASS。
- headless smoke：`completed: True`，`native_probe: 47`，`simulated_frames: 5`。

完整 gate 輸出中的 Godot ObjectDB/orphan、Terrain3D、ICD、mipmap 與 deprecation 訊息均未造成失敗，屬既有環境/專案警告。headed gate 使用當前環境的 NVIDIA Vulkan 裝置，但 #248 實作沒有 GPU vendor/type allowlist 或特定硬體分支。

## 提交

- `17e5ec1 Implement safe preset migrations for #248`
- 後續提交：`Document #248 migration implementation report`

## 清理與交付狀態

只清理本次 gate 產生且未被 Git 追蹤的 `.uid`、`.import` 與 generated translation artifacts；未刪除來源碼、既有測試或其他工作成果。最終工作樹應保持 clean。

## Round 1 修正（Sol-high findings）

Round 1 針對初版 gate 雖然通過、但安全與 authoritative semantics 尚未完整的問題補強如下。

### 1. 單次讀檔消除 TOCTOU

原本 `_read_preset_file` 先 `get_buffer()` 計算 hash，再 `seek(0)` 呼叫 `get_as_text()` 解析；兩次讀取可能看到不同的檔案內容。現在同一個 `PackedByteArray content` 同時用於 SHA-256 與 `get_string_from_utf8()` JSON parse，不再 seek 或第二次讀檔。

contract test 透過公開 `retrieve_preset` 讀取檔案 bytes，確認回傳 `content_hash` 等於同一份 bytes 的 hash。

### 2. Migration atomic barrier

- migration pending request 帶有 `atomic_barrier` 標記。
- `_apply_gsp_tuning_requests` 會先 flush barrier 前的普通 coalesced group，再以同一個 `_commit_gsp_tuning_batch` 單獨提交 migration，最後處理後續普通 group。
- 已經被 migration 保護的 key 若在 barrier 後被普通 tuning 競爭，該普通 request 延到下一個 physics boundary；因此不會混入 migration commit，也不會在同 tick 覆蓋 previewed key。
- 每個 migration commit 保留 `source: "preset"`、獨立 commit id，origin 與 observer peer 收到相同 authoritative `committed_values`。

新增的真實兩 peer WebSocket integration test 先送普通 tuning，再送 migration apply，於同一 physics tick 驗證：普通 request 有自己的 coalesced commit、migration 有更晚且獨立的 preset commit；migration key 的 ordinary request 不會覆蓋 migration commit。

### 3. Requested/final provenance

`classify_migration` 現在同時產生：

- `values`：目前 registry 的 corrected/default final set，capability 會保存。
- `requested_values`：preset 原始值或 missing default，apply 會保存並送入 native staging。

native `stage_flight_tuning_batch` 增加 migration-only 的 optional `allow_out_of_contract` 參數；普通 tuning 預設仍拒絕 contract 外值，只有 migration barrier 使用它。這使原始 `99` 進入既有 native stage/commit，得到 `requested_value: 99`、`committed_value: 2`、`clamped: true`，而 migration ACK 與兩個 peer 的 tuning commit 都保留完整且精確的 preview final current-registry set。missing key 仍以 registry default staging。

### 4. Panel 與 WebSocket business-error coverage

panel test 現在先令 `confirm()` 回傳 false，確認完全沒有 apply message；再令其回傳 true，確認才送出 apply。real WebSocket test 覆蓋 wrong 與 reused migration id 的 `tuning_ack` business errors，並在兩次錯誤後用同一 peer 成功完成後續 preset request，證明連線未被錯誤關閉。

### Round 1 tests

Focused tests：

- `node tests/test_gsp_panel_behavior.js`：PASS。
- `Godot --headless ... tests/headless/gsp_preset_contract.gd`：PASS。
- `Godot --headless ... tests/headless/gsp_preset_integration.gd`：PASS。
- `git diff --check`：PASS。

修正提交 `83fb46e Fix #248 migration barrier provenance` 後，重新執行 brief 指定的 committed-HEAD full gate：

```text
RUNNER_TEMP=/tmp/aerosim-gsp-248 \
GODOT_BIN=/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 \
scripts/verify_issue_11.sh
```

結果：exit code `0`。

- native tests、license scan、Node panel test、SCons GDExtension build：PASS。
- GUT：`277 tests, 0 failures, 0 errors`。
- native atomic boundary：PASS。
- GSP preset contract/integration：PASS。
- GSP tuning integration、Quick Adjust integration、GSP tuning stress：PASS。
- headed acceptance：PASS；使用環境 NVIDIA Vulkan，但程式碼沒有 vendor/type 限制。
- complete-session replay integration：PASS。
- headless smoke：`completed: True`、`native_probe: 47`、`simulated_frames: 5`。

Gate 輸出的既有 Terrain3D mipmap、Godot deprecation、ObjectDB/RID leak、輸入法與預期錯誤注入訊息仍存在，但沒有造成 gate failure，也不是本 Round 1 引入的 #248 failure。codebase-memory MCP 本輪在 `index_status` 後回報 worktree 未索引，兩次 `index_repository` 均因 transport closed；因此本輪使用既有工作樹、已通過的 public seams 與 focused tests 完成驗證。
