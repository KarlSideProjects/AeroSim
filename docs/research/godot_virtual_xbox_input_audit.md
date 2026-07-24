# Godot 4.7 虛擬 Xbox 輸入調查

日期：2026-07-24

## 結論

Godot 4.7 內建 `VirtualJoystick`，但它不是 Xbox 虛擬手把。它把觸控位置轉成四個 InputMap action 的 analog strength；不會建立 `InputEventJoypadMotion`、Xbox device ID、GUID 或完整的 Xbox 按鈕／軸裝置。因此不能直接接到 AeroSim 目前以 `JOY_AXIS_*` 與實體 gamepad device 為前提的輸入路徑。

Godot Asset Library 有多個 virtual joystick 外掛，但本次查到的方案同樣只提供 action／analog joystick，沒有完整的 Xbox surface、AeroSim semantic adapter、按鈕配置與 settings persistence。它們不能消除本專案仍缺少的產品契約與測試工作，所以不加入依賴。

依需求，`touch_layout` 不納入 #136 的 v1 settings domain，觸控功能延後到行動／觸控 owner 重新定義完整 contract 後再做。

## 證據

- [Godot 4.7 VirtualJoystick API](https://docs.godotengine.org/en/4.7/classes/class_virtualjoystick.html)：說明它是 touchscreen Control，透過四個 InputMap action 輸出方向與強度。
- [Godot 4.7 VirtualJoystick source](https://github.com/godotengine/godot/blob/5b4e0cb0fd279832bbdd69fed5354d4e5ad26f88/scene/gui/virtual_joystick.cpp#L1209-L1254)：實作呼叫 `Input.action_press()`／`action_release()`，沒有建立 joypad 裝置或 joypad motion event。
- [Godot 4.7 TouchScreenButton API](https://docs.godotengine.org/en/4.7/classes/class_touchscreenbutton.html)：可把觸控按鈕接到 action，但仍不是 Xbox 虛擬裝置。
- [Godot Asset Library joystick search](https://godotengine.org/asset-library/asset?filter=joystick)：列出的選項是 community joystick controls，不是完整 Xbox virtual gamepad。
- [Virtual Joystick DX](https://godotengine.org/asset-library/asset/5256) 與 [Virtual Joystick CF](https://godotengine.org/asset-library/asset/4891)：可提供 analog joystick/action glue，但仍需 AeroSim 自己定義 adapter、buttons、layout schema、persistence 與 tests；因此不採用。
- [Godot 4.7 controller documentation](https://docs.godotengine.org/en/4.7/tutorials/inputs/controllers_gamepads_joysticks.html)：描述的是實體 controller/gamepad 支援，不提供從觸控建立虛擬 Xbox device 的 API。

Godot 本身為 [MIT license](https://github.com/godotengine/godot/blob/5b4e0cb0fd279832bbdd69fed5354d4e5ad26f88/LICENSE.txt)。本次沒有新增第三方依賴。

## 後續界線

若日後重啟觸控需求，使用 Godot 內建 `VirtualJoystick`／`TouchScreenButton` 作為 primitives，另行定義 semantic-action adapter 與 layout persistence schema；不要把它冒充成實體 Xbox profile，也不要先引入外掛。
