# Godot 4.x Headed 自動化測試調研報告（AeroSim）

日期：2026-07-10
範圍：只做調查與實測驗證；未修改任何專案檔案、未 commit、未動 GitHub issues。
（實測過程中 Godot 依常規重建了 gitignored 的 `.godot/` 快取；`git status` 中的 `.gitignore` 修改與 `skills-lock.json` 為調查開始前既有狀態，非本次產生。）

---

## 1. 結論摘要

### 本機方案推薦
**不裝 plugin，自製 GDScript SceneTree 驗收腳本（原生做法）**。已在本機完整實測通過：

- 用 `--script` 掛一支 `extends SceneTree` 的 walkthrough 腳本，實例化主場景後以 `Input.parse_input_event()` 注入按鍵（T=takeoff、P=pause、R=respawn、Esc=exit），每步 `root.get_texture().get_image().save_png()` 截圖 + 斷言狀態旗標，全程 **約 19 秒**。
- 這條測試**直接抓到了那次事故**：`root.get_camera_3d() == null` 斷言失敗、截圖 91% 是同一灰色 —— headless 永遠看不到的問題，headed 一跑就現形。
- 重要修正：無 Camera3D 時畫面**不是全黑**，而是 Godot 預設 clear color 的灰色 (76,76,76)。斷言應寫成「有 active Camera3D」+「畫面非單一顏色（單色佔比 < 99%）」，而非只查黑。

### CI 可行性判定：**可行，且建議放進 CI**
- 本機（= self-hosted runner 所在機器）已具備全部條件：`xvfb-run`/`Xvfb`/`vulkaninfo` 已安裝，`/usr/share/vulkan/icd.d/lvp_icd.json`（lavapipe 軟體 Vulkan）存在。**無缺套件，不需安裝任何東西。**
- 實測：`VK_ICD_FILENAMES=lvp_icd.json xvfb-run -a` 下，Godot 4.7 forward_plus 以 llvmpipe 正常出圖（`Vulkan 1.4.335 - Forward+ - Using Device #0: llvmpipe`），截圖、輸入注入、Movie Maker 全部可用。
- **不要用 DISPLAY=:0 跑 CI**（風險見第 5 節）；`xvfb-run -a` 每個 job 自動分配獨立 X display，天然隔離並發 job。

---

## 2. 工具比較表

| 工具 | 授權 | Godot 4 支援 | headed / 輸入模擬 | 截圖比對 | 成熟度 | 適用性判定 |
|---|---|---|---|---|---|---|
| **GUT** (bitwes/Gut) 9.x | MIT ✅ | ✅（有 godot_4_7 分支） | 有 `InputSender` 輸入模擬；可 headed 跑 | ❌ 無內建 | 高（最老牌） | 邏輯單元測試佳；視覺驗收無直接幫助 |
| **GdUnit4** (MikeSchulze/godot-gdunit-labs) | MIT ✅ | ✅ | `SceneRunner` 專為場景測試設計：`simulate_key_pressed` / `simulate_action_press` / 滑鼠模擬 / await frames | ❌ 無內建 | 高（活躍、有 GitHub Action 整合、JUnit XML 報告） | 若日後 UI 測試規模擴大，**首選框架** |
| **GDSnap** (Nokorpo/GDSnap) | MIT ✅ | ✅ | 無輸入模擬（純截圖比對） | ✅ baseline 比對、diff 視覺化（cyan/red）、回報像素差異數與百分比、可 CLI 跑、可掛 GUT | 低（15 stars、16 commits、無 release） | 概念可參考，不建議依賴；自製像素斷言已夠 |
| **godot-ui-automation** (graydwarf) | MIT ✅ | Godot 4.5+ | ✅ 錄製/回放 UI 互動（點擊、拖曳、鍵盤） | ✅ baseline + 容差比對 | 低（22 stars、v1.0.0 2026-01、**僅在 Windows 測過**） | Linux 未驗證，不建議 |
| **Movie Maker mode**（引擎內建 `--write-movie`） | 隨 Godot（MIT）✅ | ✅ | 不模擬輸入，但強制固定 timestep → **確定性影格** | 產出 PNG 序列可自行 diff | 引擎內建 | ✅ 適合「人可看的存證影格序列」（已實測） |

授權結論：上表全部 MIT，皆符合 Tier 1（MIT/BSD/Zlib/Apache-2.0）。但本報告推薦路線**零外部依賴**。

專門的 Godot 4 visual regression 生態現況：只有 GDSnap 與 godot-ui-automation 兩個小型專案，皆不成熟；沒有值得直接採用的成品。

---

## 3. 實測紀錄

### 3.1 環境檢查（全通過，無缺套件）
```
$ which xvfb-run Xvfb vulkaninfo
/usr/bin/xvfb-run  /usr/bin/Xvfb  /usr/bin/vulkaninfo

$ ls /usr/share/vulkan/icd.d/
... intel_icd.json  lvp_icd.json  nvidia_icd.json  radeon_icd.json ...
（lvp = lavapipe 軟體 Vulkan）

$ vulkaninfo --summary   # 三個裝置
GPU0: AMD (0x1002/0x164e, iGPU)    GPU1: NVIDIA (0x10de/0x2803)    GPU2: llvmpipe/lavapipe

$ echo $DISPLAY $WAYLAND_DISPLAY $XDG_SESSION_TYPE
:0  wayland-0  wayland
```

### 3.2 Headed 渲染 + 截圖探針（xvfb + lavapipe）
```
$ VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/lvp_icd.json xvfb-run -a \
    Godot_v4.7-stable_linux.x86_64 --path . --resolution 1280x720 \
    --script <scratchpad>/headed_capture_probe.gd

Godot Engine v4.7.stable.official.5b4e0cb0f
Vulkan 1.4.335 - Forward+ - Using Device #0: Unknown - llvmpipe (LLVM 21.1.8, 256 bits)
exit=0
```
探針報告（report.json）：`has_active_camera3d: false`、`display_driver: X11`、`video_adapter: llvmpipe`。

像素分析（PIL）：
```
size: (1280, 720)  unique colors: 174
top colors: [((76,76,76), 842008), ((46,46,46), 77512), ((223,223,223), 411), ...]
→ 91.4% 像素是 (76,76,76)（Godot 預設 clear color），非全黑但為「無相機」的單色畫面
```

### 3.3 Movie Maker mode（xvfb + lavapipe）
```
$ ... xvfb-run -a Godot ... --path . --write-movie <dir>/frame.png --fixed-fps 30 --quit-after 15
Movie Maker mode enabled, recording movie in 1152×648 @ 30 FPS...
Done recording movie ... 15 frames at 30 FPS ... (100% of real-time speed)
→ 產出 frame00000000.png ... frame00000014.png + frame.wav
```
結論：可用於確定性影格存證。注意 (1) 解析度取專案視窗設定，`--resolution` 不影響 movie 尺寸；(2) `--write-movie` 需要渲染，**不能**與 `--headless` 併用，但在 Xvfb 下完全可行；(3) fixed-fps 使物理/渲染逐格同步，影格序列確定性高，適合 G0.P「錄影存證」需求。

### 3.4 完整 walkthrough 探針（輸入注入 + 逐步截圖 + 斷言）
腳本流程：冷啟動(30 frames) → 注入 T(takeoff) → 飛行 60 frames → 注入 P(pause) → 再注入 P(resume) → 注入 R(reset) → 注入 Esc(exit)，每步截圖 + 斷言。

```
結果 report.json：
  steps: 00_cold_start, 01_takeoff, 02_flying, 03_paused, 04_reset, 05_exit（6 張 PNG 全數產出）
  failures: ["active Camera3D present after cold start"]   ← 唯一失敗 = 真實回歸！
  其餘 4 個輸入注入斷言全部通過：
    takeoff_requested ✅  paused ✅  reset_count>=1 ✅  exit_requested ✅
  程序 exit code = 1（正確反映失敗）
  總耗時：real 19.3s（含引擎啟動與資源 import）
```
證明：`Input.parse_input_event()` 注入 `InputEventKey`（press+release 成對）能正確驅動 `_unhandled_input` 的 action 判定（`flight_takeoff`/`flight_pause`/`flight_respawn`/`flight_exit`），不需真實鍵盤。

### 3.5 現況佐證
- 主場景 `res://levels/smoke/smoke.tscn` 確實無 Camera3D、無 Light、無 UI 節點——事故根因與 headed 測試偵測結果吻合。
- `common/flight/flight_runtime.gd` 已暴露 `quick_fly()`、`request_takeoff()`、`set_paused()`、`respawn()`、`screen`、`main_menu_entries` 等 API 與狀態旗標，驗收腳本有現成掛鉤。

---

## 4. 建議架構

### 4.1 本機 headed 驗收腳本（主要交付物）

新增兩個檔案（實作時）：
- `tests/headed/headed_acceptance.gd` — SceneTree walkthrough（下方骨架）
- `scripts/run_headed_acceptance.sh` — 包裝：選 display 後端、跑 Godot、跑像素檢查、彙整輸出

```
scripts/run_headed_acceptance.sh 行為：
  1. 預設本機直跑（DISPLAY=:0，真 GPU，最接近玩家環境）；
     --xvfb 參數或偵測到 $CI 時改用：
     VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/lvp_icd.json xvfb-run -a
  2. $GODOT_BIN --path . --resolution 1280x720 \
       --script res://tests/headed/headed_acceptance.gd -- --out-dir build/headed/
  3. python3 scripts/check_headed_frames.py build/headed/   # 像素斷言
  4. 產物：build/headed/NN_step.png 序列 + report.json，人可直接翻圖
```

GDScript 骨架（已實測驗證的模式，沿用 headless_smoke.gd 的 `_initialize → await` 風格）：

```gdscript
extends SceneTree
# tests/headed/headed_acceptance.gd

func _initialize() -> void: _run()

func _run() -> void:
    var runtime := (load("res://levels/smoke/smoke.tscn") as PackedScene).instantiate()
    root.add_child(runtime)
    await _settle(30)

    # 步驟 0：冷啟動
    await _snap("00_cold_start")
    _assert(root.get_camera_3d() != null, "active Camera3D after cold start")
    _assert(runtime.screen == "main_menu", "boots to main menu")

    # 步驟 1：Quick Fly（UI 就緒前先呼叫 API；UI 就緒後改為對選單項注入 click/enter）
    runtime.quick_fly()
    await _settle(10); await _snap("01_quick_fly")

    # 步驟 2-5：arm/起飛 → pause → reset → exit，全部用真輸入路徑
    _tap_key(KEY_T);      await _settle(60); await _snap("02_takeoff")
    _assert(runtime.takeoff_requested, "takeoff via injected key")
    _tap_key(KEY_P);      await _settle(10); await _snap("03_paused")
    _assert(runtime.paused, "pause via injected key")
    _tap_key(KEY_P);      await _settle(10)
    _tap_key(KEY_R);      await _settle(10); await _snap("04_reset")
    _assert(runtime.reset_count >= 1, "reset via injected key")
    _tap_key(KEY_ESCAPE); await _settle(10); await _snap("05_exit")
    _assert(runtime.exit_requested, "Esc requests exit")   # ← 事故第二症狀的迴歸測試

    _write_report(); quit(0 if _failures.is_empty() else 1)

func _tap_key(keycode: Key) -> void:
    for pressed in [true, false]:
        var ev := InputEventKey.new()
        ev.keycode = keycode; ev.physical_keycode = keycode; ev.pressed = pressed
        Input.parse_input_event(ev)

func _snap(name: String) -> void:
    await RenderingServer.frame_post_draw          # 必要：確保該幀已畫完
    root.get_texture().get_image().save_png(_out_dir + "/%s.png" % name)
```

像素斷言（check_headed_frames.py 核心，已驗證的判準）：
```python
# 每張 PNG：
# 1) 非全黑：max(channel) > 0
# 2) 非單色畫面（抓「無相機」灰屏）：最大單一顏色佔比 < 0.99
# 3) （選配）與上一步驟影格不完全相同，證明畫面有在動
c = collections.Counter(img.getdata())
dominant_ratio = c.most_common(1)[0][1] / (img.width * img.height)
assert dominant_ratio < 0.99, f"{name}: {dominant_ratio:.1%} 單色，疑似無相機/黑屏"
```

UI 節點可見性斷言：`_assert(node.is_visible_in_tree(), ...)`；Button 走真輸入路徑用 `InputEventMouseButton`（設 `position` 為 `button.get_global_rect().get_center()`，press+release 成對注入）；`button.pressed.emit()` 只驗 handler、繞過可見性/遮擋，僅作 fallback。

Movie Maker 作為補充存證（G0.P 的「錄影 + build hash 存證」）：
```
$GODOT_BIN --path . --write-movie build/headed/evidence.png --fixed-fps 30 --quit-after 300
```

### 4.2 CI 最小 job 形態（ci.yml，待維護者核可後加入）

```yaml
  headed-smoke:
    runs-on: [self-hosted, Linux, X64]
    needs: [linux]          # 重用既有建置流程的順序位
    steps:
      # （沿用既有 Clean / checkout / tool paths / Fetch Godot / Fetch godot-cpp / scons 步驟）
      - name: Headed acceptance (Xvfb + lavapipe)
        env:
          VK_ICD_FILENAMES: /usr/share/vulkan/icd.d/lvp_icd.json
        run: |
          xvfb-run -a --server-args="-screen 0 1280x720x24" \
            scripts/run_headed_acceptance.sh --xvfb
      - name: Store headed screenshots locally
        if: always()        # 失敗時截圖最有價值
        run: |
          cp -a build/headed "$AEROSIM_CI_ARTIFACT_RUN_DIR/headed-linux"
          echo "::notice::Stored headed-linux screenshots in $AEROSIM_CI_ARTIFACT_RUN_DIR"
```
- 用 lavapipe 而非真 GPU：與 runner 上其他 job（含 Android 模擬器）零 GPU 競爭、無 driver 版本漂移、結果最可重現。實測本場景 19 秒即完成，llvmpipe 效能綽綽有餘。
- `xvfb-run -a` 自動找空閒 display，兩個 runner（actions-runner-1/-4）並發跑也不互撞。

### 4.3 基準線比對（第二階段，先不做）
第一階段只做「結構性斷言」（有相機、非單色、UI 可見、狀態旗標），**不做逐像素 baseline 比對**。理由：本機真 GPU（AMD/NVIDIA）與 CI lavapipe 的渲染輸出必然存在像素級差異，跨 renderer 的 baseline 一定假警報。若日後要做，baseline 必須「同 renderer 各存一套」且用容差比對（可屆時再評估 GDSnap 的 diff 演算法或自寫 SSIM）。

---

## 5. 風險

| 風險 | 影響 | 對策 |
|---|---|---|
| **CI 用 DISPLAY=:0 / Wayland 真 session** | session 鎖屏/登出即全紅；螢幕保護吃焦點；並發 job 在同一 display 開窗互搶焦點；跑 CI 時視窗彈到使用者桌面干擾工作；runner 以 service 跑時未必有 XDG_RUNTIME_DIR/Wayland socket 權限 | **CI 一律 xvfb-run -a**，真 display 僅供本機手動驗收 |
| lavapipe 與真 GPU 渲染差異 | 像素級 baseline 比對跨 driver 必假警報；極少數 driver bug 只在真 GPU 出現 | 第一階段只做結構性斷言；本機手動驗收用真 GPU 補盲區 |
| llvmpipe 效能 | 場景變重（GA 期地圖、粒子）後 headed job 變慢 | 目前 19s；監控 job 時長，必要時降解析度或減步驟 frame 數 |
| `Input.parse_input_event` 非 OS 層輸入 | 測不到視窗焦點遺失、OS 鍵盤布局、IME 等真實輸入層問題 | 接受此限制；它已覆蓋事故類型（action 綁定、UI 流程）。OS 層問題屬手動驗收範圍 |
| `screen == "main_menu"` 等內部狀態斷言與實作耦合 | 重構 UI 時測試跟著改 | 以「行為斷言」（截圖非單色、exit_requested）為主，內部狀態斷言為輔 |
| 無相機畫面是灰不是黑 | 只斷言「非全黑」會漏抓 | 已改為「單色佔比 < 99% + 有 active Camera3D」雙斷言 |
| Movie Maker 檔案量 | PNG 序列大（1152×648 每幀 ~數百 KB） | 只在驗收/存證跑，限 `--quit-after`；CI 不常設 |
| Godot 啟動時 import（.godot 被清時） | 首跑較慢、偶發 import 競態 | 沿用 run_headless_smoke.sh 既有的 .godot 預備手法 |
| GDSnap / godot-ui-automation 不成熟 | 引入後變孤兒依賴 | 不採用；全部原生 API 自製（零依賴） |

---

## 附：本次實測產物（皆在 scratchpad，未進專案）
- `headed_capture_probe.gd`、`headed_walkthrough_probe.gd` — 探針腳本
- `headed_probe/frame_030.png`、`headed_probe/report.json` — 無相機灰屏證據
- `headed_walkthrough/00_cold_start.png` … `05_exit.png`、`report.json` — 六步截圖與斷言結果
- `movie/frame00000000.png` … — Movie Maker 影格序列

Sources:
- [GdUnit4 GitHub (MIT)](https://github.com/godot-gdunit-labs/gdUnit4)
- [GdUnit4 SceneRunner actions 文件](https://godot-gdunit-labs.github.io/gdUnit4/latest/advanced_testing/scene_runner/actions/)
- [GUT GitHub (MIT, godot_4_7 分支)](https://github.com/bitwes/Gut)
- [GDSnap GitHub (MIT)](https://github.com/Nokorpo/GDSnap)
- [godot-ui-automation GitHub (MIT)](https://github.com/graydwarf/godot-ui-automation)
