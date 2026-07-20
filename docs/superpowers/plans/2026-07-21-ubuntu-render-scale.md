# Ubuntu 3D Render Scale Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver #135's persistent 50%–100% 3D render scale with immediate preview and an explicit Apply transaction.

**Architecture:** A small `QualityProfile` follows the existing `RatesProfile` validation pattern and is stored in the existing SettingsStore envelope. `FlightRuntime` owns the live viewport value and the Graphics panel's committed-preview transaction; it never creates a second settings store or renderer configuration layer.

**Tech Stack:** Godot 4.7, GDScript, GUT, existing headed acceptance runner.

## Global Constraints

- `quality` has exactly `{ "schema_version": 1, "render_scale": <float> }` when configured; `quality: null` means 1.00.
- Accept only finite 0.50–1.00 values in 0.05 steps, canonicalized by integer tick calculation; an absent top-level `quality` key is invalid.
- Change only `Viewport.scaling_3d_scale`; do not add dynamic resolution, FSR, AA, shadows, fog, platform branches, scenes, or dependencies.
- Preview immediately, persist only through Apply, restore the captured value on Back or failed Apply, and use the same Control callbacks for mouse, keyboard, and gamepad.
- Global factory reset changes the runtime viewport only after the existing complete-document save succeeds.

---

### Task 1: Validate the quality domain inside the existing settings envelope

**Files:**
- Create: `common/flight/quality_profile.gd`
- Create: `tests/gut/test_quality_profile.gd`
- Modify: `common/flight/settings_store.gd`
- Modify: `tests/gut/test_settings_store.gd`

**Interfaces:**
- Produces `QualityProfile.default_profile() -> Dictionary` and `QualityProfile.validate_profile(candidate: Variant) -> Dictionary`.
- `validate_profile` returns `{ "ok": true, "error": "", "profile": { "schema_version": 1, "render_scale": canonical_scale } }` or `{ "ok": false, "error": reason }`.
- `SettingsStore.validate_document` delegates a non-null `quality` slot to `QualityProfile.validate_profile` and writes its canonical profile into the normalized document.

- [ ] **Step 1: Write the failing quality and envelope tests**

```gdscript
func test_quality_profile_accepts_each_render_scale_tick() -> void:
    const path := "res://common/flight/quality_profile.gd"
    assert_true(ResourceLoader.exists(path))
    if not ResourceLoader.exists(path):
        return
    var quality = load(path)
    for tick in range(11):
        var result: Dictionary = quality.validate_profile({
            "schema_version": 1,
            "render_scale": 0.50 + 0.05 * tick,
        })
        assert_true(result.ok, result.error)
        assert_eq(result.profile.render_scale, 0.50 + 0.05 * tick)

func test_quality_profile_rejects_off_step_values() -> void:
    const path := "res://common/flight/quality_profile.gd"
    assert_true(ResourceLoader.exists(path))
    if not ResourceLoader.exists(path):
        return
    var result: Dictionary = load(path).validate_profile({"schema_version": 1, "render_scale": 0.51})
    assert_false(result.ok)
    assert_string_contains(result.error, "0.05")
```

Add `test_settings_store_validates_the_versioned_quality_slot` that rejects `render_scale: 0.51`, accepts `1.0`, accepts `quality: null`, and confirms deleting the top-level `quality` key fails as a missing envelope field.

- [ ] **Step 2: Run test to verify it fails**

Run: `GODOT_BIN=/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 scripts/run_gut.sh -gtest=test_quality_profile.gd,test_settings_store.gd`

Expected: FAIL because `quality_profile.gd` does not exist and SettingsStore accepts an off-step `quality` object.

- [ ] **Step 3: Implement the minimum validator and store delegation**

```gdscript
# common/flight/quality_profile.gd
class_name QualityProfile
extends RefCounted

const SCHEMA_VERSION := 1
const DEFAULT_RENDER_SCALE := 1.0
const MIN_RENDER_SCALE := 0.50
const MAX_RENDER_SCALE := 1.00
const RENDER_SCALE_STEP := 0.05
const FIELD_NAMES := ["schema_version", "render_scale"]

static func default_profile() -> Dictionary:
    return {"schema_version": SCHEMA_VERSION, "render_scale": DEFAULT_RENDER_SCALE}

static func validate_profile(candidate: Variant) -> Dictionary:
    # Reject non-objects, unknown/missing fields, non-finite values, and bad schema.
    # Compute tick := roundi((value - MIN_RENDER_SCALE) / RENDER_SCALE_STEP),
    # require 0 <= tick <= 10 and is_equal_approx(value, MIN_RENDER_SCALE + tick * RENDER_SCALE_STEP),
    # then return the canonical tick-derived float.
```

In `SettingsStore.validate_document`, directly after the existing rates block, validate non-null `source["quality"]`, return a failure unchanged, then assign `normalized["quality"] = quality_result.profile`. Keep the current top-level allowlist and recovery path unchanged.

- [ ] **Step 4: Run test to verify it passes**

Run: `GODOT_BIN=/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 scripts/run_gut.sh -gtest=test_quality_profile.gd,test_settings_store.gd`

Expected: PASS; all eleven ticks are canonical and invalid/absent values are rejected.

- [ ] **Step 5: Commit**

```bash
git add common/flight/quality_profile.gd tests/gut/test_quality_profile.gd common/flight/settings_store.gd tests/gut/test_settings_store.gd
git commit -m "feat: validate #135 quality settings"
```

### Task 2: Apply and persist the Graphics preview transaction

**Files:**
- Modify: `common/flight/flight_runtime.gd`
- Modify: `tests/gut/test_flight_runtime_load.gd`
- Modify: `tests/headed/headed_acceptance.gd`

**Interfaces:**
- Produces `show_graphics(return_screen: String = "settings")`, `_preview_render_scale(scale: float)`, `_apply_graphics_settings()`, and `_close_graphics_panel()`.
- `_save_quality_profile(profile: Dictionary) -> Dictionary` uses the existing load-modify-save envelope transaction and changes the committed runtime value only after `save_document` succeeds.
- Graphics panel nodes are named `GraphicsPanel`, `RenderScale`, `RenderScaleValue`, `Apply`, `ResetDefaults`, and `Back` beneath `MainMenu`.

- [ ] **Step 1: Write the failing runtime and UI transaction tests**

```gdscript
func test_graphics_preview_back_restores_the_committed_viewport_scale() -> void:
    var runtime := _graphics_runtime_with_store(1.0)
    runtime.show_graphics()
    runtime._on_render_scale_changed(0.75)
    assert_eq(runtime.render_scale, 0.75)
    assert_false(runtime.settings_store.save_called)
    runtime._close_graphics_panel()
    assert_eq(runtime.render_scale, 1.0)

func test_graphics_apply_persists_once_and_failed_apply_restores_preview() -> void:
    var runtime := _graphics_runtime_with_store(1.0)
    runtime.show_graphics()
    runtime._on_render_scale_changed(0.75)
    runtime._apply_graphics_settings()
    assert_eq(runtime.settings_store.save_calls, 1)
    assert_eq(runtime.settings_store.document.quality.render_scale, 0.75)
    runtime.settings_store.fail_save = true
    runtime.show_graphics()
    runtime._on_render_scale_changed(0.50)
    runtime._apply_graphics_settings()
    assert_eq(runtime.render_scale, 0.75)
```

Use a small in-test `QualitySettingsStore` that implements only `load_document` and `save_document`, tracks calls, and returns the complete SettingsStore envelope. Add assertions that startup applies persisted 0.75 to `get_viewport().scaling_3d_scale`, slider/reset do not write, and button `pressed.emit()` reaches the same Apply callback.

Add this headed acceptance flow before production code exists, so it proves the real Controls are missing rather than merely re-testing an already-built UI:

```gdscript
var graphics_button: Button = runtime.get_node_or_null("MainMenu/SettingsPanel/Rows/Graphics")
_expect(graphics_button != null, "Settings exposes Graphics")
_click(graphics_button)
await _settle(2)
_expect(runtime.screen == "graphics", "Graphics entry opens Graphics")
var scale_slider: HSlider = runtime.get_node_or_null("MainMenu/GraphicsPanel/Rows/RenderScale")
var apply_button: Button = runtime.get_node_or_null("MainMenu/GraphicsPanel/Rows/Apply")
_expect(scale_slider != null and apply_button != null, "Graphics exposes scale and Apply")
```

Continue the flow by setting 0.75, asserting immediate `root.scaling_3d_scale`, emitting Apply, reading `settings_store.load_document().document.quality.render_scale`, selecting 0.50, pressing Back, and asserting it restores 0.75.

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
GODOT_BIN=/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 scripts/run_gut.sh -gtest=test_flight_runtime_load.gd
GODOT_BIN=/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 scripts/run_headed_acceptance.sh --output build/headed-135
```

Expected: FAIL because Graphics methods/nodes/runtime `render_scale` do not exist and the headed Settings flow cannot find `Graphics`.

- [ ] **Step 3: Implement only the runtime state and Controls required by the tests**

```gdscript
func _preview_render_scale(value: float) -> void:
    render_scale = value
    var viewport := get_viewport()
    if viewport != null:
        viewport.scaling_3d_scale = render_scale

func _close_graphics_panel() -> void:
    _preview_render_scale(graphics_committed_scale)
    show_settings()
```

Load `quality` during `_load_player_settings`, default to 1.00, and apply it through `_preview_render_scale`. Build one compact `GraphicsPanel` with the HSlider/current label/three buttons, add a `GRAPHICS` button to `SettingsPanel`, and include the screen in `_refresh_flight_hud` visibility lists. Capture `graphics_committed_scale` in `show_graphics`; Apply validates then saves once, changes that captured value only on success, and restores it on failure. `RESET DEFAULTS` calls `_preview_render_scale(1.0)` without saving. Extend global `factory_reset_player_settings` to preview 1.00 only after its existing `settings_store.factory_reset()` success.

- [ ] **Step 4: Run test to verify it passes**

Run:

```bash
GODOT_BIN=/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 scripts/run_gut.sh -gtest=test_flight_runtime_load.gd
GODOT_BIN=/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 scripts/run_headed_acceptance.sh --output build/headed-135
```

Expected: PASS; one explicit Apply persists, preview rollback works, and the root viewport has the active scale.

- [ ] **Step 5: Commit**

```bash
git add common/flight/flight_runtime.gd tests/gut/test_flight_runtime_load.gd tests/headed/headed_acceptance.gd
git commit -m "feat: add #135 render scale controls"
```

### Task 3: Exercise the headed settings flow and run the repository gates

**Files:**
- No source-file changes; the headed Graphics flow was added in Task 2 before implementation.

**Interfaces:**
- The existing headed Settings flow uses actual `Button` signals and an `HSlider`, rather than a parallel UI harness. It must now pass as part of the repository gates.

- [ ] **Step 1: Run all required checks**

Run:

```bash
GODOT_BIN=/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 scripts/run_gut.sh
scripts/test_native.sh
scripts/check_hardcoded_airframe_constants.sh
scripts/test_license_scan.sh
GODOT_BIN=/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 scripts/run_headless_smoke.sh --output build/headless_smoke.json --frames 5
GODOT_BIN=/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 scripts/run_headed_acceptance.sh --output build/headed-135
```

Expected: every command exits 0 and the smoke JSON reports `completed: true`.

