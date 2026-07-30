#!/usr/bin/env python3
"""Load the installed GSP bundle in real Chrome and inspect the drone geometry.

The bundle is staged exactly as `GspLauncher.install_panel` installs it, opened
over `file://`, and fed one telemetry sample built from a hardware configuration
preset. The check then proves, in a real WebGL page, that

* the versioned bundle is complete and every request stayed on `file://`,
* the model was built and is scaled to the configured real-world size,
* M1-M4 map to the configured motor layout and spin directions, and the labels
  are drawn at those rotors,
* the reported geometry classification matches the recorded provenance.

Chrome runs headless by default. Pass --headed --hold to leave a window open for
visual inspection.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_gsp_panel_browser import Cdp, wait_for_target  # noqa: E402


ROOT = Path(__file__).resolve().parents[1]
CHROME = os.environ.get("CHROME_BIN", "/usr/bin/google-chrome")
PANEL = ROOT / "common/gsp/gsp_panel.html"
LAUNCHER = ROOT / "common/gsp/gsp_launcher.gd"
ASSET_PATH_RE = re.compile(r'"res://(common/gsp/assets/[^"]+)"')
TOLERANCE_M = 0.004


def free_port() -> int:
    """Pick an unused loopback port so parallel runs cannot collide."""
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return int(probe.getsockname()[1])


def stage_bundle(target: Path) -> list[str]:
    """Mirror GspLauncher.install_panel: panel.html plus every declared asset."""
    assets = ASSET_PATH_RE.findall(LAUNCHER.read_text(encoding="utf-8"))
    if not assets:
        raise RuntimeError("GspLauncher declares no panel assets")
    (target / "assets").mkdir(parents=True, exist_ok=True)
    shutil.copyfile(PANEL, target / "panel.html")
    for asset in assets:
        source = ROOT / asset
        if not source.is_file():
            raise RuntimeError(f"declared panel asset is missing: {asset}")
        shutil.copyfile(source, target / "assets" / source.name)
    return assets


def wait_for_bundle(page: Cdp, deadline: float) -> None:
    """The panel loads three scripts from disk; wait until all of them ran."""
    ready = (
        "document.readyState === 'complete' && typeof window.THREE !== 'undefined'"
        " && typeof window.__AEROSIM_GSP_DRONE_GEOMETRY__ !== 'undefined'"
        " && typeof window.__AEROSIM_GSP_VISUAL__ !== 'undefined'"
        " && !!(window.__AEROSIM_PANEL_TEST__ && window.__AEROSIM_PANEL_TEST__.displayTelemetry)"
    )
    while time.monotonic() < deadline:
        if page.evaluate(ready) is True:
            return
        time.sleep(0.1)
    raise RuntimeError("the staged GSP bundle did not finish loading")


def telemetry_sample(configuration: dict) -> dict:
    motors = [
        {"thrust_newtons": 4.1, "current_a": 9.0, "speed_rad_s": 1100.0, "saturated": False},
        {"thrust_newtons": 4.4, "current_a": 9.6, "speed_rad_s": 1150.0, "saturated": False},
        {"thrust_newtons": 4.3, "current_a": 9.4, "speed_rad_s": 1140.0, "saturated": False},
        {"thrust_newtons": 4.0, "current_a": 8.8, "speed_rad_s": 1090.0, "saturated": False},
    ]
    return {
        "fresh": True,
        "sample_seq": 1,
        "config_hash": "browser-geometry-check",
        "motor_order": configuration["motor_order"],
        "motors": motors,
        "rpm": [10500, 10980, 10890, 10410],
        "hardware_configuration": configuration,
        "hardware_power_model": {"max_total_thrust_newtons": 64.8, "max_total_current_a": 108.0},
        "wind_body_mps": {"x_val": 4.0, "y_val": 1.5, "z_val": 0.0},
        "air_density_kg_m3": 1.225,
    }


def check(page: Cdp, configuration: dict, requests: list[str]) -> list[str]:
    errors: list[str] = []
    report = page.evaluate("JSON.stringify(window.__AEROSIM_GSP_VISUAL__.geometry())")
    geometry = json.loads(report)
    if not geometry.get("available"):
        return [f"geometry unavailable in the browser: {geometry.get('reason')}"]
    if not geometry.get("rendered"):
        errors.append("the geometry package did not build a model in the page")
    status = json.loads(page.evaluate("JSON.stringify(window.__AEROSIM_GSP_VISUAL__.status())"))
    if not status.get("available") or status.get("rotor_count") != len(configuration["motor_order"]):
        errors.append(f"visualization status does not report a live model: {status}")

    expected_diameter = configuration["propeller"]["diameter_in"] * 0.0254
    if abs(geometry["propeller"]["diameter_m"] - expected_diameter) > 1e-9:
        errors.append(
            f"propeller diameter {geometry['propeller']['diameter_m']} does not match "
            f"the configured {expected_diameter}"
        )
    if abs(geometry["scale"]["wheelbase_m"] - configuration["frame"]["wheelbase_m"]) > 1e-9:
        errors.append("rendered wheelbase does not match frame.wheelbase_m")
    if geometry["identity"]["designation"] != configuration["geometry"]["identity"]["designation"]:
        errors.append("rendered airframe identity does not match the configuration")

    layout = configuration["aircraft"]["motor_layout"]
    order = configuration["motor_order"]
    spin = configuration["spin_direction"]
    for index, motor in enumerate(geometry["motors"]):
        label = f"M{index + 1}"
        if motor["label"] != label or motor["id"] != order[index]:
            errors.append(f"motor {index} is {motor['label']}/{motor['id']}, expected {label}/{order[index]}")
        if motor["spin_direction"] != spin[index]:
            errors.append(f"{label} spins {motor['spin_direction']}, configured {spin[index]}")
        for axis in ("x", "y", "z"):
            if abs(motor["frd"][axis] - layout[index][axis]) > 1e-9:
                errors.append(f"{label} {axis} is {motor['frd'][axis]}, configured {layout[index][axis]}")

    rendered_labels = {entry["label"]: entry for entry in geometry["rendered_labels"]}
    for index, motor in enumerate(geometry["motors"]):
        label = f"M{index + 1}"
        drawn = rendered_labels.get(label)
        if not drawn:
            errors.append(f"{label} has no label drawn in the render")
            continue
        if drawn["motor_id"] != motor["id"]:
            errors.append(f"{label} label is pinned to {drawn['motor_id']}, expected {motor['id']}")
        if abs(drawn["position"][0] - motor["scene"][0]) > 1e-6 or abs(drawn["position"][2] - motor["scene"][2]) > 1e-6:
            errors.append(f"{label} label is not above its rotor")
        if drawn["position"][1] <= motor["scene"][1]:
            errors.append(f"{label} label is not above the airframe")

    # The rendered airframe must measure the configured span in metres.
    measured = json.loads(page.evaluate(
        "(function () {"
        "  var THREE = window.THREE;"
        "  var group = null;"
        "  var rotor = window.__AEROSIM_GSP_VISUAL__.rotor(" + json.dumps(order[0]) + ");"
        "  group = rotor.group.parent;"
        "  var box = new THREE.Box3().setFromObject(group);"
        "  var size = box.getSize(new THREE.Vector3());"
        "  return JSON.stringify({ x: size.x, y: size.y, z: size.z });"
        "}())"
    ))
    span = geometry["scale"]["span_m"]
    for axis in ("x", "z"):
        if abs(measured[axis] - span) > TOLERANCE_M:
            errors.append(f"rendered {axis} extent {measured[axis]:.4f} m does not match span {span:.4f} m")
    if not 0.02 < measured["y"] < 0.16:
        errors.append(f"rendered height {measured['y']:.4f} m is outside the 5-inch airframe range")

    classification = page.evaluate("document.getElementById('geometry-classification').dataset.classification")
    badge = page.evaluate("document.getElementById('geometry-classification').textContent")
    if classification != geometry["classification"]:
        errors.append(f"panel badge reports {classification}, geometry is {geometry['classification']}")
    if geometry["classification"] == "nominal" and badge not in ("名義幾何", "Nominal geometry"):
        errors.append(f"nominal geometry must be labelled as such, got {badge!r}")
    if geometry["classification"] == "real" and not geometry["classification_reasons"] == []:
        errors.append("real geometry cannot carry classification reasons")

    live = page.evaluate("document.getElementById('visualization-status').textContent")
    if live not in ("即時遙測", "Live telemetry"):
        errors.append(f"the panel reports no live visualization while a model is rendered: {live!r}")
    mapping = page.evaluate("document.getElementById('geometry-motors').textContent")
    for index in range(len(order)):
        if f"M{index + 1}" not in mapping:
            errors.append(f"panel mapping does not list M{index + 1}")
    provenance = page.evaluate("document.getElementById('geometry-provenance').textContent")
    if "redistribution = release" not in provenance:
        errors.append("panel does not report the redistribution disposition")

    # Chrome runs with name resolution blocked, so a working page proves the
    # bundle loaded without network access.
    if page.evaluate("location.protocol") != "file:":
        errors.append("the panel was not loaded from the local bundle over file://")
    for global_name in ("THREE", "__AEROSIM_GSP_DRONE_GEOMETRY__", "__AEROSIM_GSP_VISUAL__"):
        if not page.evaluate(f"typeof window[{json.dumps(global_name)}] !== 'undefined'"):
            errors.append(f"bundle asset did not load: window.{global_name} is missing")
    remote = [url for url in requests if url.startswith(("http://", "https://", "ws://", "wss://"))]
    if remote:
        errors.append(f"the bundle requested non-local resources: {remote}")

    print(json.dumps({
        "preset_url": page.evaluate("location.protocol"),
        "classification": geometry["classification"],
        "classification_reasons": geometry["classification_reasons"],
        "identity": geometry["identity"],
        "scale": geometry["scale"],
        "motors": [
            {"label": motor["label"], "id": motor["id"], "spin": motor["spin_direction"], "frd": motor["frd"]}
            for motor in geometry["motors"]
        ],
        "rendered_extent_m": measured,
        "name_resolution": "blocked",
        "remote_resource_requests": len(remote),
    }, ensure_ascii=False, indent=2))
    return errors


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--preset", default="config/drones/5_inch_6s.json")
    parser.add_argument("--headed", action="store_true", help="run Chrome with a visible window")
    parser.add_argument("--hold", type=float, default=0.0,
                        help="keep the browser open for this many seconds after checking")
    parser.add_argument("--screenshot", default=None, help="write a PNG of the page to this path")
    arguments = parser.parse_args()

    configuration = json.loads((ROOT / arguments.preset).read_text(encoding="utf-8"))
    if not Path(CHROME).exists():
        print(f"Chrome is unavailable at {CHROME}; set CHROME_BIN", file=sys.stderr)
        return 1

    with tempfile.TemporaryDirectory(prefix="aerosim-gsp-geometry-") as workspace:
        root = Path(workspace)
        bundle = root / "bundle"
        assets = stage_bundle(bundle)
        profile = root / "profile"
        debug_port = free_port()
        command = [
            CHROME, "--no-first-run", "--no-default-browser-check",
            f"--user-data-dir={profile}", f"--remote-debugging-port={debug_port}",
            "--window-size=900,1200", "--enable-unsafe-swiftshader",
            # Block every name lookup: the bundle must run entirely offline.
            "--host-resolver-rules=MAP * ~NOTFOUND",
            f"file://{bundle / 'panel.html'}#port=1&token={'0' * 32}",
        ]
        if not arguments.headed:
            command.insert(1, "--headless=new")
        chrome = subprocess.Popen(command, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            target = wait_for_target(debug_port, time.monotonic() + 30.0)
            page = Cdp(target["webSocketDebuggerUrl"])
            page.command("Runtime.enable")
            page.command("Page.enable")
            # The panel only exposes its render hooks when the object already
            # exists, so install it before the document scripts run and reload.
            page.command("Page.addScriptToEvaluateOnNewDocument",
                         {"source": "window.__AEROSIM_PANEL_TEST__ = window.__AEROSIM_PANEL_TEST__ || {};"})
            page.command("Page.reload", {"ignoreCache": True})
            wait_for_bundle(page, time.monotonic() + 30.0)
            requests = json.loads(page.evaluate(
                "(function () {"
                "  return JSON.stringify(performance.getEntriesByType('resource').map(function (entry) {"
                "    return entry.name;"
                "  }));"
                "}())"
            ))
            print(f"staged bundle assets: {', '.join(Path(asset).name for asset in assets)}")

            # Drive the panel's own telemetry path, which renders the geometry
            # card and hands the sample to the visual layer.
            page.evaluate(
                "window.__AEROSIM_PANEL_TEST__.displayTelemetry({ d: "
                + json.dumps(telemetry_sample(configuration))
                + " }), 'displayed'"
            )
            # Let the render loop rebuild the model from the new configuration.
            page.evaluate(
                "new Promise(function (resolve) {"
                "  var frames = 0;"
                "  function tick() { frames += 1; if (frames > 6) resolve(frames); else requestAnimationFrame(tick); }"
                "  requestAnimationFrame(tick);"
                "})"
            )
            errors = check(page, configuration, requests)

            if arguments.screenshot:
                shot = page.command("Page.captureScreenshot", {"format": "png"})
                Path(arguments.screenshot).write_bytes(__import__("base64").b64decode(shot["data"]))
                print(f"screenshot written: {arguments.screenshot}")
            if arguments.hold > 0:
                print(f"holding the browser open for {arguments.hold:.0f}s")
                time.sleep(arguments.hold)
            page.close()
        finally:
            chrome.terminate()
            try:
                chrome.wait(timeout=10)
            except subprocess.TimeoutExpired:
                chrome.kill()

    if errors:
        for error in errors:
            print(error, file=sys.stderr)
        return 1
    print("GSP drone geometry browser check passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
