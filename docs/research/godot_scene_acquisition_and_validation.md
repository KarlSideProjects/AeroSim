# Godot 遊戲場景取得與驗證方案

## 結論

最保險的 production path 是：**保留 #35 已完成的 map descriptor、載入／釋放生命週期、spawn 與 primitive collision，直接在 Godot 疊加或替換成授權明確、原生提供 GLB/glTF 的美術層**。第一個候選採 [Kenney City Kit (Industrial)](https://www.kenney.nl/assets/city-kit-industrial)；官方頁標示 CC0，現行 1.0 官方下載檔實際包含 25 個 GLB。道路與植被有需要再分別加入 [City Kit (Roads)](https://www.kenney.nl/assets/city-kit-roads) 與 [Nature Kit](https://kenney.nl/assets/nature-kit)，不要先造 Unreal 轉換供應鏈。

Godot 4.7 官方把 glTF 2.0 列為推薦格式，支援 `.gltf` 與 `.glb`；GLB 可把 mesh 與 texture 放在單一檔案。[Godot 4.7：Available 3D formats](https://docs.godotengine.org/en/4.7/tutorials/assets_pipeline/importing_3d_scenes/available_formats.html)

「看起來正常合理」不能由零人工的結構測試證明。可靠契約是：**headless 結構／碰撞 gate + 固定 GPU 的 headed 截圖 + CAP-006 後一次人工核准 golden images + 後續影像 regression**。Headless 只能證明場景可載入與可碰撞；Godot 官方明載 `--headless` 會停用所有 rendering 與 window management，因此不能用它批准畫面。[RenderingServer](https://docs.godotengine.org/en/4.7/classes/class_renderingserver.html)

## 方案比較

| 方案 | 自動化與風險 | 畫面成果 | 決定 |
| --- | --- | --- | --- |
| A. 原生 GLB/glTF／Blender asset pack 直接進 Godot | 路徑最短；格式是 Godot 官方推薦；可鎖下載版本、SHA-256 與授權快照 | 可直接取得一致的建築、道路與植被；仍需組出場景並做一次視覺批准 | **production 首選** |
| B. AirSim UE4.27 Blocks 經 Unreal glTF | Blocks source project 可取得，但 AirSim 官方稱它「very basic」；AirSim 建議 UE 4.27，而 glTF exporter 到 UE 5.1 才成為引擎內建、此前是 external plugin，工具鏈版本風險較高 | Blocks 本質仍是基本方塊，轉完不會比直接保留現有 primitive yard 更像成熟遊戲 | 只作相容性研究，不作首個場景來源 |
| C. packaged Unreal extraction／community converter | 來源、版本、材質與 Level 還原不可控；AirSim 官方明說 release binaries 使用 proprietary assets，無法提供 source project | 即使抽出 mesh，也不能保證材質、燈光、Blueprint、碰撞或授權完整 | **排除 production** |
| D. Godot primitives／procedural | 最穩、最易測；目前 #35 已完成 descriptor、landmark、collision 與 headed lifecycle | 適合灰盒與測試，不足以單獨證明「正常合理的遊戲場景」 | 保留作 collision／fallback，不再把它當美術完成品 |

來源：[AirSim Blocks](https://microsoft.github.io/AirSim/unreal_blocks/)、[AirSim Linux build（UE 4.27）](https://microsoft.github.io/AirSim/build_linux/)、[Epic UE 5.1 release notes](https://dev.epicgames.com/documentation/en-us/unreal-engine/unreal-engine-5.1-release-notes?application_version=5.1)、[Epic glTF export scope/options](https://dev.epicgames.com/documentation/en-us/unreal-engine/exporting-unreal-engine-content-to-gltf)、[Epic glTF content limitations](https://dev.epicgames.com/documentation/en-us/unreal-engine/how-the-gltf-exporter-handles-unreal-engine-content)、[AirSim releases](https://github.com/microsoft/AirSim/releases)、[AirSim MIT license](https://github.com/microsoft/AirSim/blob/main/LICENSE)。AirSim repo 的 MIT license 不應被推論成 release binaries 內第三方資產的跨引擎授權。

## 建議的最小落地方式

1. 凍結 Kenney Industrial 1.0 官方 archive、`License.txt`、來源 URL 與 SHA-256；2026-07-14 取得的 archive SHA-256 為 `99a09ff148056678c0c3b7977ad9dbce55d2f243e06fbfc7c28642accef4dd9e`。只匯入實際用到的 GLB。
2. 保留 `industrial_yard` descriptor、`SpawnNorth`、map lifecycle、現有命名 landmark 與簡單碰撞形狀；讓 GLB 只負責 visual art layer。這避免把第三方 mesh 當飛行碰撞面，也避免重寫已驗證 runtime。
3. 用固定的 Godot 4.7 `.import` 設定匯入，燈光與 environment 留在 Godot 場景內，不期待跨引擎還原。若日後要自動產生 collision 或 metadata，優先使用 Godot import script；官方 importer 支援 post-import script，也支援 `-col`／`-convcol` 命名提示。[Import configuration](https://docs.godotengine.org/en/4.7/tutorials/assets_pipeline/importing_3d_scenes/import_configuration.html) [Node suffixes](https://docs.godotengine.org/en/4.7/tutorials/assets_pipeline/importing_3d_scenes/node_type_customization.html) [Model export considerations](https://docs.godotengine.org/en/4.7/tutorials/assets_pipeline/importing_3d_scenes/model_export_considerations.html)
4. 只在這個 art-layer spike 通過下列完整驗證後，才把它列為 AirSim-minimum 的第一個正式場景。

## 可驗證契約

### 1. Headless import 與結構 gate（每次 CI）

- 用固定 Godot 4.7 editor 執行 `--headless --import --path .`（`--import` 會等待 resource import 完成再退出），import error 或 missing dependency 即失敗；命令列 editor/headless/script 能力見 [Godot command line](https://docs.godotengine.org/en/4.7/tutorials/editor/command_line_tutorial.html)。
- Instantiate 場景並依 checked-in manifest 驗證：必要 landmark、唯一 spawn、有限且非零的 mesh AABB、有限 transform、預期 GLB instance、Camera3D、DirectionalLight3D／WorldEnvironment 均存在；不要只驗「至少有一個 mesh」。
- 延續現有 descriptor、unknown-map、load/free/reset assertions。
- 每個可見實體障礙都必須對應明確的 `StaticBody3D/CollisionShape3D`；另做 spawn shape query、地面 raycast、代表性障礙 shape cast，確保不穿地、出生不重疊、飛行走廊真的會撞。visual mesh 與 collision 分離，兩者對齊由場景 manifest 的 landmark transform 驗證。

### 2. Headed GPU 視覺證據（asset 或場景改版時）

- 固定 Godot 4.7、Linux GPU runner、renderer、解析度、品質設定、random seed、world time 與曝光；**不可加 `--headless`**。
- 固定四個 deterministic camera：spawn/chase、yard overview、obstacle corridor、ground-level scale。每張圖等待 `RenderingServer.frame_post_draw` 後再擷取；這是 Godot 官方建議的 Viewport capture 時序。[Using Viewports](https://docs.godotengine.org/en/4.7/tutorials/rendering/viewports.html) [Viewport](https://docs.godotengine.org/en/4.7/classes/class_viewport.html)
- CAP-006 前由 Codex 產生 provisional evidence，不請求人工作業；CAP-006 完成後才由人第一次核准四張 golden images，檢查：物件可辨識為 industrial yard、比例合理且落地、無白模／缺材質／穿插／漂浮／z-fighting、天空與曝光正常、spawn 與飛行走廊清楚、代表性障礙和 collision 一致。核准後 golden PNG 與 renderer metadata 一起進版控；後續例行改版只跑 regression，只有替換 approved reference 才需要再次人工核准。

### 3. GPU image regression（其後每次 CI）

- 同一 headed runner 重拍相同四個 camera；用 Godot 4.7 `Image.compute_image_metrics()` 比較 golden，取得 `max`、`mean_squared`、`root_mean_squared`、`peak_snr`。[Image](https://docs.godotengine.org/en/4.7/classes/class_image.html)
- 閾值先由同一 runner 重跑多次量出自然抖動後鎖定，不憑空猜數字；超標即失敗並上傳 baseline、actual、diff。Engine、renderer、GPU driver 改版時重新人工批准，不把跨 GPU pixel 差異當產品 regression。
- 現有 `_max_color_ratio < 0.99` 只能排除幾乎單色或全黑畫面；灰底、藍平台、橘色方塊仍會通過，因此只能保留為 capture sanity check，不能作視覺品質 gate。

### 4. AI Visual Verification（正式 blocking gate）

- 每張固定鏡位 GPU PNG 必須帶同一份 checked-in manifest：scene revision、camera id/transform、解析度、renderer、Godot/GPU driver、預期可見 landmark 與 approved reference image。manifest 不符、截圖缺失或 deterministic prechecks 未過，直接失敗，不送 AI 猜測。
- Vision model 同時取得 current PNG、approved reference 與該鏡位 manifest，且只准回傳 strict JSON。Rubric 固定檢查 `missing_texture`、`lighting_or_exposure`、`scale_inconsistency`、`floating_or_ground_contact`、`clipping_or_intersection`、`scene_readability`；每項輸出 `severity`（`Critical|High|Medium|Low|None`）、`evidence`、`camera_id`，JSON schema 驗證失敗即 gate 失敗。
- 合格條件是所有鏡位 **Critical = 0 且 High = 0**；Medium/Low 進 artifact/report 供人處理。AI model/version、prompt/rubric/schema 必須鎖版，變更時以 approved set 重新校準。
- AI gate 是「語意畫面異常」的補強，不取代 import/structure、collision、deterministic smoke、pixel regression 或 performance gate；它也不能自行建立第一組 approved reference。

## 自動化的界線

結構檢查能證明「載得進、尺寸不是零、物件與碰撞存在」；golden diff 能證明「沒有偏離曾經核准的畫面」。兩者都不能第一次自行判斷美術是否自然、比例是否可信、構圖是否像完成的遊戲場景。**最少且不可省的人工作業，是 CAP-006 後第一次四視角批准；後續例行 art revision 不逐次要求人工批准，只有替換 approved reference 時才重做批准。**

跳過：Unreal extraction、通用轉換器與自建 importer；只有未來確定要批次遷移多個具合法 source project 的 Unreal 場景時，才值得重新評估。
