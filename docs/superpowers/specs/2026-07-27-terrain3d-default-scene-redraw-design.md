# Terrain3D 預設場景重繪設計

日期：2026-07-27
狀態：已核准，待實作
分支：`worktree-terrain3d-default-scene-redraw`

## 問題

預設 Free Flight 地圖 `terrain3d_range` 名義上使用 Terrain3D，實際上是灰盒：

- 地形由 `scripts/generate_terrain3d_range_ground.gd` 程序產生，只有兩座 `smoothstep` 小丘，範圍 161 × 161 m。
- `Terrain3DMaterial` 是 `[sub_resource type="Terrain3DMaterial" id="1"]`，完全沒有設定任何 shader 參數，因此沒有 auto shader、沒有 dual scaling、沒有 macro variation，region 外緣直接是可見的地圖邊界。
- 地貌裝飾是 3 顆 `SphereMesh` 當雲、2 根 `CylinderMesh` 當岩石。
- `assets/third_party/terrain3d_demo/demo/data/` 標示為第三方目錄，但產生腳本會就地覆寫它。經雜湊比對，兩個 region 檔都已被改寫，官方第三個 region 從未 vendored 進來。第三方資產邊界實質上已經失效。

## 資料來源調查

上游候選比較：

| 來源 | 授權 | 可用性 | 結論 |
| --- | --- | --- | --- |
| Terrain3D 官方 demo（`TokisanGames/Terrain3D` `project/demo/`） | MIT | 三個手工雕刻 region 直接可用，格式與本專案 addon 1.0.2 相同 | **採用** |
| 真實世界 DEM（USGS / Copernicus / UnrealHeightmap / TouchTerrain） | 各異 | 需自行處理投影、高度縮放、貼圖權重繪製，且必須在編輯器內操作 | 不採用，工作量與風險不成比例 |
| 純程序生成升級 | 不適用 | 完全可重現，但地形品質上限低於手工雕刻 | 不採用為主來源，保留為作業層手段 |

官方資料取自 tag `v1.0.2-stable`（與本專案 `addons/terrain_3d` 版本一致；`main` 分支為 1.1.x，資料格式有版本風險）。2026-07-27 取得的 SHA-256：

```
ac86dbbe16cfbd7c963aa42598f98101f36017c54eb74e2934b4411d0741e162  terrain3d_00_00.res
b99ee709308c7e6fd9b27b86e6656708726f2080f6c9f6cb33f6176f05c9a221  terrain3d_00-01.res
ef38ace6e235317d96e4f6aa9c2137e335d65af7f2fc2158f2175e23fb996eb3  terrain3d_00-02.res
```

## 官方地形實測

以 Godot 4.7 headless 載入官方三個 region 量測（探測腳本見實作附錄）：

- `region_size = 1024`、`vertex_spacing = 1.0`，region 位置 `(0,0)`、`(0,-1)`、`(0,-2)`。
- 世界範圍 x ∈ [0, 1024]、z ∈ [−2048, 1024]，即 **1024 × 3072 m**。
- 高度範圍 **−54.0 ~ +365.6 m**，南側（z ≈ 512~768）為 350 m 級山峰群。
- 控制圖 base id 幾乎全為 0（岩壁），overlay 以 id 1（草地）為主；**id 2 從未被使用**。
- x < 64 與 x > 896 的邊緣、以及原點角落為高度 0 的平坦區。

### 飛行場選址

以「24 m 內落差小」與「120 m 內落差大」兩項掃描全圖，最佳候選：

| 座標 | 高度 | 24 m 內落差 | 120 m 內落差 |
| --- | --- | --- | --- |
| **(432~512, −704~−736)** | 79.7 m | 0.13 ~ 1.06 m | ~70 m |
| (352~368, −384) | 74.6 m | 1.26 ~ 2.37 m | ~120 m |
| (272~288, −1744) | 105 m | 1.13 ~ 2.08 m | ~96 m |

採 **(456, 79.7, −720)** 為飛行場中心：面積最大的天然高原，位於山谷中央，南向面對 350 m 山峰群，起飛即具景深，四向皆可飛行。

## 設計

### 1. 資產分層

現行「第三方目錄被作業腳本就地覆寫」的做法必須終止，改為兩層：

```
assets/third_party/terrain3d_demo/demo/data/   官方 v1.0.2-stable 原檔，唯讀，SHA-256 鎖定
assets/maps/terrain3d_range/data/              作業層輸出，場景 data_directory 指向此處
```

代價是約 12 MB 的重複資料。可稽核的第三方資產邊界優先於儲存量，且與 `docs/research/godot_scene_acquisition_and_validation.md` 對 Kenney 資產的既有做法（凍結檔案 + SHA-256 + 授權快照）一致。

### 2. 地形作業層

`scripts/generate_terrain3d_range_ground.gd` 改寫為讀官方原檔、疊加、輸出到新目錄。作業範圍限制在起降區約 200 × 200 m：

- 輕微整平兩個起降坪基座（該高原原本落差已 < 1.1 m，只需消除殘餘傾斜）。
- 繪製起降坪 apron 使用 SoilSand（overlay id 2，blend 1.0）。官方資料未使用 id 2，此層完全由本專案作業產生。
- 確保飛行場核心區的草地覆蓋（base id 1）。

腳本必須是冪等的：重跑一次得到相同輸出。

### 3. 場景重繪（`levels/free_flight/terrain3d_range.tscn`）

| 節點 | 處理 |
| --- | --- |
| `Terrain3D` | `data_directory` 指向作業層輸出；material 套用官方 demo 完整參數（`auto_shader`、`dual_scaling`、`world_background = 2`、macro variation、noise texture、projection）。保留 `collision_mode = 3`、`collision_mask = 1`、`metadata/airsim_segmentation_id = 1` |
| `Terrain3D/Terrain3DParticles` | 新增，引用 `addons/terrain_3d/extras/particle_example/Terrain3DParticles.tscn`，與官方 Demo.tscn 相同用法 |
| `Sun` | 調整角度朝南側山峰群，保留 `shadow_enabled` 與正的 `light_energy` |
| `AeroSimEnvironment` | 重調 sky、高度霧、曝光至 3 km 尺度。必須維持 `BG_SKY` + `sky_material` + `fog_enabled` + `fog_density > 0` + 非線性 tonemap |
| `CloudLayer` | 節點保留（測試要求存在且含可見 mesh）。雲體尺度與材質重做，配合 80 m 起飛高度與 350 m 山峰 |
| `SpawnNorth` / `SpawnNorthPlatform`（seg 2）<br>`SpawnSouth` / `SpawnSouthPlatform`（seg 8） | 節點名稱、階層、metadata 不變，座標搬到高原。平台需水平且中心對齊 spawn，spawn 下方 2 m 射線必須命中平台 |
| `NorthRidgeRock`（seg 9）<br>`EastRidgeRock`（seg 10） | 節點保留（測試要求為可見且具碰撞的 StaticBody3D）。搬到實際有起伏的山脊，mesh 由圓柱改為岩石造型 |
| `TimeTrial/Checkpoint01-03`、`TimeTrial/Finish` | 節點名稱不變，沿「高原 → 谷底 → 回爬」路線重排，每個 marker 必須高於該點地形高度 |
| `Landmarks` | 新增。放置 Kenney City Kit Industrial（CC0，已在專案內）建物作為地標與飛行障礙 |

硬性限制：場景中不得出現任何 `RigidBody3D`；不得存在 `GroundCollision` 節點。

### 4. 測試取樣座標更新

`tests/headless/terrain3d_range_smoke.gd` 有三處硬編碼座標，在官方地形上必然失敗：

| 斷言 | 官方地形實測 | 處理 |
| --- | --- | --- |
| `get_texture_id((80,0,-80)).x == 1`（草地 base） | base id 為 0 | 改取樣飛行場實際草地點 |
| `get_texture_id((8,0,-36)).y == 2` 且 blend ≥ 0.99 | 官方未使用 id 2 | 改取樣作業層繪製的起降坪礫石 apron |
| `get_height((30,0,-72)) ≥ 3.0`、`(76,0,-48) ≥ 3.0` | 0.0 / −0.15 | 改取樣 RidgeRock 的新山脊位置 |
| `intersect_ray` 於 `(30,0,-60)` 需吻合地形高度 ±0.25 | — | 改取樣飛行場附近有起伏處 |

**只改座標，不改斷言意圖或強度。** 節點名稱、segmentation id、階層與所有結構性檢查全部維持。

`tests/headed/headed_acceptance.gd` 初判僅斷言節點名稱與相對關係（平台對齊 spawn、camera、map id 等），預期不需修改，實作時以實跑確認。

### 5. 驗證契約

依 `docs/research/godot_scene_acquisition_and_validation.md` 既有分層：

1. `--headless --import --path .` 無 import error 或 missing dependency。
2. `tests/headless/terrain3d_range_smoke.gd` 全數通過。
3. GUT 測試與 `scripts/test_native.sh` 通過（後者不受本變更影響，仍執行以防迴歸）。
4. Headed 四鏡位截圖（spawn/chase、高原全景、谷底走廊、地面尺度），由實作者逐張檢視：物件可辨識、比例合理且落地、無白模／缺材質／穿插／漂浮／z-fighting、天空與曝光正常。

依 AGENTS.md，CAP-006 前不請求人工視覺審查；本次產生的是 provisional evidence。

## 明確排除

- 不引入真實世界 DEM 匯入管線。
- 不修改 `industrial_yard` 地圖。
- 不改動 `common/maps/free_flight_map.gd` 的地圖描述機制或 `config/maps/terrain3d_range.json` 的 schema。
- 不改動 `project.godot` 的 `main_scene`；`levels/smoke/smoke.tscn` 仍是 runtime 殼。
