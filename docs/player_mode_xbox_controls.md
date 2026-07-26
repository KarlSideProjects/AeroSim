# Player Mode Xbox 操作說明

Player Mode 使用固定的 Xbox Mode 2 設定；目前不提供玩家重新綁定，也不是 RC 遙控器設定介面。預設是由機體後方觀看的第三人稱視角；切換 FPV 不會改變手把方向。

## 飛行控制

| 手把控制 | 作用 | 飛行方向 |
| --- | --- | --- |
| 左類比左右 | Yaw | 向右推時機頭向右轉，向左推時機頭向左轉。 |
| 左類比上下 | Throttle / 垂直速度 | 上推爬升、下拉下降；受控起飛前必須實體保持在最下方。 |
| 右類比左右 | Roll | 向右推右傾並向右移動，向左推左傾並向左移動。 |
| 右類比上下 | Pitch | 向上推機頭向下、向前飛；向下拉機頭向上、向後飛。 |

右類比的軸角色沒有互換：水平永遠是 Roll，垂直永遠是 Pitch。第三人稱從後方看時，「向前」仍是機頭所指方向；FPV 也使用相同語意。

## 起飛、復原與視角

- `A`：Arm 並受控起飛。左類比必須在最下方；完成後會爬到約一公尺並進入 Assisted Hold。
- `X`：Reset，回到目前出生平台。
- `START + X`：切換出生點後重置。
- `Y`：切換 Assisted Hold 與 Angle。
- `BACK`：切換玩家的第三人稱／FPV 視角。AirSim 相機資料仍以 FPV 為準。
- `START`：暫停／繼續。
- `B`：離開目前飛行。
- `RB`：按住進入 ACRO；放開回到原本模式。

## Assisted Hold 與 Controller Monitor

受控起飛完成後，Assisted Hold 會保持高度、朝向與水平位置。放開左右類比時，機體應在平靜場景中維持穩定；很小的右類比中心雜訊不應讓水平定位反覆解除。要刻意移動時，將右類比推過中心區；放回中心後會重新捕捉位置。

持續顯示的 Controller Monitor 同時列出每個軸的 `Raw` 與 `Normalized` 值：

- `Raw` 是手把回報的原始位置。
- `Normalized` 是套用死區、曲線與固定 Mode 2 極性後的飛行命令。

若手未碰手把時 `Raw` 或 `Normalized` 仍非零，問題是手把中心偏移；若兩者都維持零、機體仍明顯飄移，請把 Monitor、飛行模式與場景資訊一併回報。Terrain Range 的預設環境為 calm，材質 mipmap 或 Godot 相容性警告不代表飛行輸入錯誤。

## 鍵盤備援

沒有受確認 Xbox 手把時會顯示 KeyboardProfile fallback。它只用於開發與可達性備援，並非模擬器級的四軸控制；請以畫面上的鍵盤提示為準。它不會改變 Xbox Mode 2、AirSim RPC 或外部座標契約。
