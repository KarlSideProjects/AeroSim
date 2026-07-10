# 本機 Ubuntu 基準與行動建置車道：實作計畫

> **執行者注意：** 本計畫依 `superpowers:executing-plans` 逐項執行；每個工作項目都要先寫出會失敗的測試，再做最小修正，最後執行列出的驗證命令。

**目標：** 將 G0.1 的凍結桌面基準改為目前本機 Ubuntu 26.04／Ryzen 9 7945HX／RTX 4060 Ti，讓 Android 與 iOS 保留建置車道但明確排除沒有裝置時無法執行的實機驗收。

**設計依據：** `docs/superpowers/specs/2026-07-10-local-ubuntu-build-only-lanes-design.md`

**技術棧：** Godot 4.7、GDExtension C++、Python `unittest`、Bash、GitHub Actions、Markdown

---

### 工作 1：先以測試鎖住新的 G0.1 凍結硬體

**檔案：**
- 修改：`tests/test_performance_report.py`
- 修改：`tests/test_performance_runner.py`
- 修改：`scripts/performance_report.py`
- 修改：`scripts/run_performance_benchmark.sh`

1. 將報表測試的基準 CPU/GPU 改成完整的 `AMD Ryzen 9 7945HX with Radeon Graphics` 與 `NVIDIA GeForce RTX 4060 Ti`；保留 Godot/godot-cpp 與雜湊的凍結驗證。
2. 將「非凍結硬體」測試改成：舊 Ryzen 5／GTX 1660 SUPER 必須被 gate 拒絕；本機基準能形成有 gate verdict 的報表。
3. 在 runner 測試新增或調整斷言：未指定模式時使用 `gate`，gate 會要求 7945HX 與 RTX 4060 Ti，非 smoke 的 10 秒 warmup／60 秒量測不變。
4. 先執行，確認舊實作會因舊常數或預設模式而失敗：

```bash
python3 -m unittest tests.test_performance_report tests.test_performance_runner
```

5. 在 `scripts/performance_report.py` 將兩個 G0.1 常數與錯誤訊息改為新凍結桌面；在 runner 將預設模式改為 `gate`，並將 CPU/adapter gate 前置檢查改成新硬體。
6. 重新執行相同測試，預期全數通過。

### 工作 2：把 CI 與可讀文件改為「本機硬體 gate」

**檔案：**
- 修改：`.github/workflows/performance-gpu.yml`
- 修改：`README.md`
- 修改：`docs/decisions/2026-07-10-acceptance-simplification.md`
- 新增：`docs/decisions/2026-07-10-local-ubuntu-build-only-lanes.md`

1. 將 GPU workflow 的名稱、命令與 artifact 斷言由 reference 改為 gate；明確要求 RTX 4060 Ti，驗證 `gate == "G0.1"`、`gate_eligible == true`、`gate_verdict == "pass"`，並保留 effects-off / effects-on 的比較。
2. README 的執行範例改為不帶 `--mode reference` 的本機 gate；說明 10/60 秒、3ms、Ryzen 9 7945HX、RTX 4060 Ti 和 headed 顯示需求。
3. 新增決策紀錄，列出桌面凍結環境、Android/iOS 的 build-only 保留項目，以及所有 N/A 的實機項目；清楚說明 N/A 不是 pass，且這份決策覆寫較早 iOS Ad Hoc 實機路徑在目前環境的可執行性。
4. 以文字檢查確認舊硬體與 reference 斷言不再出現在 G0.1 執行入口：

```bash
git grep -n -E 'Ryzen 5 5600|GTX 1660 SUPER|--mode reference|G0.1-reference' -- README.md scripts/run_performance_benchmark.sh scripts/performance_report.py .github/workflows/performance-gpu.yml
```

5. 執行 workflow 靜態語法檢查（現有 `actionlint` 時）：

```bash
actionlint .github/workflows/performance-gpu.yml
```

若環境沒有 `actionlint`，必須回報 `not verified`，不可把缺失當成通過。

### 工作 3：對 PRD 做最小、明確的驗收範圍調整

**檔案：**
- 修改：`PRD_AeroSim.md`

1. 把 G0.1 與方法學的桌面基準改成 Ubuntu 26.04、Ryzen 9 7945HX、RTX 4060 Ti；保留 3ms、10 秒 warmup、60 秒量測、240Hz、1kHz、Jolt 與 VSync-off。
2. 在 Phase 0 前新增目前環境的 lane 執行註記：Android/iOS 僅 build-only；未持有實機時其 FPS/P99/Perfetto、OTG/MFi/VirtualJoystick、錄影、安裝、溫度、延遲、crash-free 等實機條件一律 N/A，不能列為通過；不豁免桌面與 shared-core 門檻。
3. 將 G0.2、G0.5 的 Android/iOS 實機分支標示為此環境 N/A，保留 Android export／APK 與 native tests、iOS export 設定；iOS 實際 Xcode 建置 smoke 直到 macOS/Xcode runner 可用前是 `not verified`。
4. 以針對性搜尋確認文字一致：

```bash
git grep -n -E '7945HX|4060 Ti|build-only|N/A|not verified' -- PRD_AeroSim.md docs/decisions/2026-07-10-local-ubuntu-build-only-lanes.md
```

### 工作 4：在凍結本機完成兩組 headed G0.1 gate 證據

**檔案：**
- 修改：`docs/performance/g0_1-7945hx-4060ti-effects-off.json`
- 修改：`docs/performance/g0_1-7945hx-4060ti-effects-off.svg`
- 修改：`docs/performance/g0_1-7945hx-4060ti-effects-on.json`
- 修改：`docs/performance/g0_1-7945hx-4060ti-effects-on.svg`

1. 先檢查顯示伺服器、Godot 4.7 binary、godot-cpp checkout、SCons 與 GDExtension build 前置條件；任何一項缺失即停止並回報 `blocked`/`not verified`。
2. 對 effects-off 執行完整 gate：

```bash
GODOT_BIN=.deps/godot/Godot_v4.7-stable_linux.x86_64 \
scripts/run_performance_benchmark.sh \
  --effects off \
  --output docs/performance/g0_1-7945hx-4060ti-effects-off.json
```

3. 對 effects-on 執行完整 gate，並以 effects-off 報表做比較：

```bash
GODOT_BIN=.deps/godot/Godot_v4.7-stable_linux.x86_64 \
scripts/run_performance_benchmark.sh \
  --effects on \
  --baseline-report docs/performance/g0_1-7945hx-4060ti-effects-off.json \
  --output docs/performance/g0_1-7945hx-4060ti-effects-on.json
```

4. 檢查兩份 JSON 都是 `G0.1`、`gate_eligible: true`、`gate_verdict: pass`，資料量為 14,400，P99 ≤ 3ms，且 effects-on 有可比較的 comparison。

```bash
python3 - <<'PY'
import json
from pathlib import Path
for effects in ("off", "on"):
    report = json.loads(Path(f"docs/performance/g0_1-7945hx-4060ti-effects-{effects}.json").read_text())
    assert report["gate"] == "G0.1"
    assert report["gate_eligible"] is True
    assert report["gate_verdict"] == "pass"
    assert report["sample_count"] == 14400
    assert report["p99_ms"] <= 3.0
assert "comparison_to_baseline" in json.loads(Path("docs/performance/g0_1-7945hx-4060ti-effects-on.json").read_text())
PY
```

### 工作 5：整體驗證、審查與 GitHub 閉環

**檔案：**
- 修改：GitHub #17、#18、#55 的 issue body/labels/comments（無本機檔案）

1. 執行完整相關測試：

```bash
python3 -m unittest discover -s tests -p 'test_*.py'
```

2. 執行專案既有的格式、靜態與 native 驗證命令；若有現成 CI 對應入口，以該入口為準，並逐項記錄結果。
3. 用 `git diff --check` 與 `git status --short` 檢查 diff 和工作樹。
4. 將 #17 的基準敘述更新為新 Ubuntu desktop gate；將 #18/#55 的 Android/iOS 實機驗收標記目前為 N/A、保留 build-only，不能解除其未來裝置驗收需求。
5. 進行一輪獨立 adversarial code review，修正所有 P0/P1；然後重新跑受影響驗證。
6. 依 #56：建立 PR（`Closes #17`）、確認 CI 成功、在最新 `origin/main` rebase、重新確認 CI，再 squash merge；確認 #17 已關閉並依依賴關係解除下游工作。
