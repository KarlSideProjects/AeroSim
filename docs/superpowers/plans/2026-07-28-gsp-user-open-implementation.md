# GSP User-Initiated Opening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give a ready GSP session a user-initiated browser-open and URL-copy entry point in Godot's pause menu.

**Architecture:** `GspLauncher` retains the current authenticated panel URL and exposes small readiness/open/copy methods. `FlightRuntime` discovers the sibling launcher while constructing the existing pause panel and adds controls only when that launcher is ready; no browser, renderer, or GPU-specific path is introduced.

**Tech Stack:** Godot 4.7 GDScript, existing GSP launcher, Godot Control UI, existing headless and headed GDScript checks.

## Global Constraints

- Target Ubuntu 26.04+ GNOME Wayland; `OS.shell_open()` is best-effort and must not be treated as a foreground guarantee.
- Preserve the existing `127.0.0.1` listener, per-run token, and token-bearing URL fragment.
- Never render the token-bearing URL in the HUD or logs beyond the existing launcher output.
- Controls are development-only, shown only for a ready GSP, and belong outside the in-flight control path.
- Do not introduce browser, GPU vendor, renderer, or device restrictions.

---

### Task 1: Expose safe user actions from the GSP launcher

**Files:**

- Modify: `common/gsp/gsp_launcher.gd:10-130`
- Test: `tests/headless/gsp_launch_contract.gd`

**Interfaces:**

- Produces: `is_panel_ready() -> bool`, `request_panel_open() -> Dictionary`, and `copy_panel_url() -> Dictionary` on `GspLauncher`.
- Consumes: the existing `open_panel(url: String) -> bool` and `OS.shell_open()` implementation.

- [ ] **Step 1: Write the failing launcher contract assertions**

Add a test harness subclass that seeds a ready URL and counts calls to `open_panel`, then assert the public operations:

```gdscript
var launcher := LauncherHarness.new()
launcher.seed_panel_url("file:///tmp/panel.html#port=8765&token=0123456789abcdef0123456789abcdef")
if not launcher.is_panel_ready():
    failures.append("ready launcher must expose panel actions")
var opened := launcher.request_panel_open()
if not bool(opened.get("ok", false)) or launcher.open_calls != 1:
    failures.append("user open must call the panel opener once")
var copied := launcher.copy_panel_url()
if not bool(copied.get("ok", false)):
    failures.append("ready launcher must copy its panel URL")
```

Also assert that a fresh launcher rejects both actions without returning the URL or token in its error text.

- [ ] **Step 2: Run the launcher contract and verify it fails**

Run:

```bash
"$GODOT_BIN" --headless --path . --script res://tests/headless/gsp_launch_contract.gd
```

Expected: FAIL because the three public action methods do not exist.

- [ ] **Step 3: Implement the smallest launcher state and actions**

Store the URL only after `start()` and `install_panel()` both succeed. Clear it in `_exit_tree()`. Implement methods with this shape:

```gdscript
func is_panel_ready() -> bool:
    return _server != null and not _panel_url.is_empty()

func request_panel_open() -> Dictionary:
    if not is_panel_ready():
        return {"ok": false, "error": "GSP panel is unavailable"}
    return shell_open_result(true, open_panel(_panel_url), _panel_url)

func copy_panel_url() -> Dictionary:
    if not is_panel_ready():
        return {"ok": false, "error": "GSP panel is unavailable"}
    DisplayServer.clipboard_set(_panel_url)
    return {"ok": true}
```

Do not return `_panel_url` from either action result. Keep the existing startup auto-open behavior unchanged.

- [ ] **Step 4: Run the launcher contract and verify it passes**

Run:

```bash
"$GODOT_BIN" --headless --path . --script res://tests/headless/gsp_launch_contract.gd
```

Expected: `GSP launch contract: PASS`.

- [ ] **Step 5: Commit the launcher action boundary**

```bash
git add common/gsp/gsp_launcher.gd tests/headless/gsp_launch_contract.gd
git commit -m "feat: expose GSP user open actions"
```

### Task 2: Add ready-only pause-menu controls

**Files:**

- Modify: `common/flight/flight_runtime.gd:4620-4690`
- Modify: `common/flight/flight_runtime.gd:3570-3620`
- Test: `tests/headed/headed_acceptance.gd:470-490`

**Interfaces:**

- Consumes: `GspLauncher.is_panel_ready()`, `request_panel_open()`, and `copy_panel_url()` from Task 1.
- Produces: `FlightHud/PausePanel/Rows/OpenGspPanel`, `CopyGspUrl`, and `GspPanelStatus` when the launcher is ready.

- [ ] **Step 1: Write failing headed assertions for the ready-only controls**

In the existing pause-menu assertion block, require the controls only when the acceptance fixture starts GSP. Invoke each button's `pressed` signal and assert that the status label changes without exposing `file://`, `token=`, or the token value:

```gdscript
var open_gsp: Button = runtime.get_node_or_null("FlightHud/PausePanel/Rows/OpenGspPanel")
var copy_gsp: Button = runtime.get_node_or_null("FlightHud/PausePanel/Rows/CopyGspUrl")
var gsp_status: Label = runtime.get_node_or_null("FlightHud/PausePanel/Rows/GspPanelStatus")
_expect(open_gsp != null and copy_gsp != null and gsp_status != null, "ready GSP exposes pause controls")
open_gsp.pressed.emit()
copy_gsp.pressed.emit()
_expect(not gsp_status.text.contains("token=") and not gsp_status.text.contains("file://"), "GSP status never exposes the session URL")
```

Use a non-ready launcher fixture to assert all three nodes are absent.

- [ ] **Step 2: Run headed acceptance and verify it fails**

Run:

```bash
GODOT_BIN="$GODOT_BIN" scripts/run_headed_acceptance.sh --xvfb
```

Expected: FAIL because the named GSP controls are absent.

- [ ] **Step 3: Add the controls to the existing pause-panel builder**

Use `get_node_or_null("GspLauncher")` from `FlightRuntime`. If it is a `GspLauncher` and `is_panel_ready()` is true, append a label and two buttons after the existing diagnostics controls:

```gdscript
open_gsp.pressed.connect(func() -> void:
    var result := launcher.request_panel_open()
    gsp_status.text = "GSP open requested" if bool(result.get("ok", false)) else "GSP unavailable"
)
copy_gsp.pressed.connect(func() -> void:
    var result := launcher.copy_panel_url()
    gsp_status.text = "GSP URL copied" if bool(result.get("ok", false)) else "GSP unavailable"
)
```

Set each button's `name` exactly as listed in this task. Add static English strings through the existing localization refresh map rather than embedding token-bearing data.

- [ ] **Step 4: Run headed acceptance and verify it passes**

Run:

```bash
GODOT_BIN="$GODOT_BIN" scripts/run_headed_acceptance.sh --xvfb
```

Expected: the structured headed report succeeds and includes the existing pause-menu evidence.

- [ ] **Step 5: Commit the pause-menu entry point**

```bash
git add common/flight/flight_runtime.gd tests/headed/headed_acceptance.gd
git commit -m "feat: add GSP pause menu actions"
```

### Task 3: Document and validate the supported fallback

**Files:**

- Modify: `README.md:82-116`
- Test: `tests/headless/gsp_launch_contract.gd`

**Interfaces:**

- Consumes: the button names and status behavior produced in Task 2.
- Produces: user instructions that distinguish best-effort browser opening from the user-initiated fallback.

- [ ] **Step 1: Write the documentation expectation into the launcher contract**

Read `README.md` in the existing script and fail if it lacks both `OPEN GSP PANEL` and `COPY GSP URL` while claiming browser focus is guaranteed:

```gdscript
var readme := FileAccess.get_file_as_string("res://README.md")
if not readme.contains("OPEN GSP PANEL") or not readme.contains("COPY GSP URL"):
    failures.append("README must document the GSP user actions")
if readme.contains("guaranteed browser focus"):
    failures.append("README must not promise browser focus on Wayland")
```

- [ ] **Step 2: Run the launcher contract and verify it fails**

Run:

```bash
"$GODOT_BIN" --headless --path . --script res://tests/headless/gsp_launch_contract.gd
```

Expected: FAIL until the README names both actions.

- [ ] **Step 3: Update the README with the user-initiated workflow**

State that automatic opening is best-effort on Wayland. Direct users to pause the simulator, click `OPEN GSP PANEL`, and use `COPY GSP URL` plus paste into the browser address bar when the compositor leaves the browser hidden. Do not add browser-specific configuration commands.

- [ ] **Step 4: Run focused checks and inspect the diff**

Run:

```bash
"$GODOT_BIN" --headless --path . --script res://tests/headless/gsp_launch_contract.gd
git diff --check
```

Expected: `GSP launch contract: PASS` and no whitespace errors.

- [ ] **Step 5: Commit the documentation and contract**

```bash
git add README.md tests/headless/gsp_launch_contract.gd
git commit -m "docs: describe GSP user open fallback"
```

## Self-Review

- Spec coverage: Task 1 owns ready/open/copy behavior and token-safe errors; Task 2 owns visible ready-only controls and status; Task 3 owns the Wayland fallback documentation.
- Placeholder scan: no `TODO`, `TBD`, or deferred implementation steps are present.
- Type consistency: Task 1 defines every `GspLauncher` method consumed by Task 2; Task 2's named nodes are the only UI names consumed by Task 3.
