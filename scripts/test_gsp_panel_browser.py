#!/usr/bin/env python3
"""Run the production GSP panel in a real Chrome page and save timing evidence."""

from __future__ import annotations

import base64
import hashlib
import json
import os
import re
import secrets
import select
import socket
import struct
import subprocess
import tempfile
import time
import urllib.request
from pathlib import Path

from test_gsp_transport import receive_frame


ROOT = Path(__file__).resolve().parents[1]
GODOT = os.environ.get("GODOT_BIN", "godot")
CHROME = os.environ.get("CHROME_BIN", "/usr/bin/google-chrome")
URL_PATTERN = re.compile(r"GSP panel URL: (?P<url>file://[^\s]+#port=(?P<port>\d+)&token=(?P<token>[0-9a-f]{32}))")
PORTRAIT_SIZES = [(480, 854), (560, 996), (640, 1138)]


def cdp_frame(value: str) -> bytes:
    payload = value.encode("utf-8")
    mask = secrets.token_bytes(4)
    masked = bytes(byte ^ mask[index % 4] for index, byte in enumerate(payload))
    if len(payload) < 126:
        header = bytes([0x81, 0x80 | len(payload)])
    elif len(payload) < 65536:
        header = bytes([0x81, 0x80 | 126]) + struct.pack("!H", len(payload))
    else:
        header = bytes([0x81, 0x80 | 127]) + struct.pack("!Q", len(payload))
    return header + mask + masked


class Cdp:
    def __init__(self, websocket_url: str) -> None:
        url = websocket_url.removeprefix("ws://")
        host_port, path = url.split("/", 1)
        host, port_text = host_port.rsplit(":", 1)
        self.sock = socket.create_connection((host, int(port_text)), timeout=5.0)
        key = base64.b64encode(secrets.token_bytes(16)).decode("ascii")
        self.sock.sendall(
            (
                f"GET /{path} HTTP/1.1\r\nHost: {host_port}\r\nUpgrade: websocket\r\n"
                f"Connection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: {key}\r\n\r\n"
            ).encode("ascii")
        )
        response = bytearray()
        while b"\r\n\r\n" not in response:
            response.extend(self.sock.recv(4096))
        if not response.startswith(b"HTTP/1.1 101 "):
            raise RuntimeError("Chrome CDP WebSocket handshake failed")
        expected = base64.b64encode(hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode("ascii")).digest()).decode("ascii")
        if f"Sec-WebSocket-Accept: {expected}".encode("ascii") not in response:
            raise RuntimeError("Chrome CDP accept key did not match")
        self.sock.settimeout(30.0)
        self.command_id = 0

    def command(self, method: str, params: dict | None = None) -> dict:
        self.command_id += 1
        command_id = self.command_id
        self.sock.sendall(cdp_frame(json.dumps({"id": command_id, "method": method, "params": params or {}})))
        while True:
            opcode, payload = receive_frame(self.sock)
            if opcode == 8:
                raise RuntimeError("Chrome CDP page closed")
            message = json.loads(payload.decode("utf-8"))
            if message.get("id") == command_id:
                if "error" in message:
                    raise RuntimeError(f"Chrome CDP {method} failed: {message['error']}")
                return message.get("result", {})

    def evaluate(self, expression: str) -> object:
        result = self.command("Runtime.evaluate", {"expression": expression, "awaitPromise": True, "returnByValue": True})
        if result.get("exceptionDetails"):
            raise RuntimeError(f"Chrome page evaluation failed: {result['exceptionDetails']}")
        remote = result.get("result", {})
        if remote.get("subtype") == "error" or remote.get("type") == "object" and remote.get("value") is None and remote.get("description"):
            raise RuntimeError(f"Chrome page evaluation failed: {remote}")
        return remote.get("value")

    def close(self) -> None:
        self.sock.close()


def wait_for_target(debug_port: int, deadline: float) -> dict:
    while time.monotonic() < deadline:
        try:
            with urllib.request.urlopen(f"http://127.0.0.1:{debug_port}/json/list", timeout=1.0) as response:
                targets = json.load(response)
            for target in targets:
                if target.get("type") == "page" and target.get("webSocketDebuggerUrl"):
                    return target
        except (OSError, ValueError):
            pass
        time.sleep(0.1)
    raise RuntimeError("Chrome CDP page target did not become available")


def read_panel_url(process: subprocess.Popen[bytes], deadline: float) -> str:
    if process.stdout is None:
        raise RuntimeError("Godot did not expose stdout")
    output = bytearray()
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError(f"Godot exited before GSP URL: {process.returncode}: {output.decode(errors='replace')[-2000:]}")
        readable, _, _ = select.select([process.stdout], [], [], 0.1)
        if not readable:
            continue
        chunk = os.read(process.stdout.fileno(), 4096)
        if not chunk:
            continue
        output.extend(chunk)
        match = URL_PATTERN.search(output.decode(errors="replace"))
        if match:
            return match.group("url")
    raise RuntimeError(f"timed out waiting for GSP URL: {output.decode(errors='replace')[-2000:]}")


def check_portrait_console(cdp: Cdp) -> list[dict]:
    """Exercise the installed file:// panel; never substitute a DOM fake here."""
    checks = []
    for width, height in PORTRAIT_SIZES:
        cdp.command("Emulation.setDeviceMetricsOverride", {"width": width, "height": height, "deviceScaleFactor": 1, "mobile": False})
        check = cdp.evaluate(
            """(() => {
                const live = document.getElementById('live-console');
                const controls = [...live.querySelectorAll('button,input')];
                const before = document.activeElement && document.activeElement.id;
                document.getElementById('language-en').click();
                const english = document.documentElement.lang === 'en' || document.body.textContent.includes('Ground Station');
                document.getElementById('language-zh').click();
                controls[0] && controls[0].focus();
                const keyboard = document.activeElement === controls[0] && controls.every(control => control.getBoundingClientRect().width > 0);
                const bounds = [...live.querySelectorAll('*')].every(node => {
                  const rect = node.getBoundingClientRect();
                  return rect.left >= -0.5 && rect.right <= innerWidth + 0.5 && rect.top >= -0.5 && rect.bottom <= innerHeight + 0.5;
                });
                const resources = performance.getEntriesByType('resource').map(entry => entry.name);
                const offline = location.protocol === 'file:' && resources.every(name => name.startsWith('file:') || name.startsWith('data:'));
                window.__AEROSIM_PANEL_TEST__.renderLiveConsole({ fresh: true, px4_mavlink: { hil_actuator_controls: { stale: true, age_seconds: 1, sample: { mapping_verified: true, command_normalized: { m1: .2, m2: .2, m3: .2, m4: .2 } } } } }, { tick: 1 });
                const sourceText = document.getElementById('source-commanded').textContent;
                const staleSource = sourceText.includes('Stale') || sourceText.includes('過期');
                return { scroll: document.documentElement.scrollHeight <= innerHeight && live.scrollHeight <= innerHeight, bounds, keyboard, english, offline, stale_source: staleSource, before };
            })()"""
        )
        if not isinstance(check, dict) or not all(check.get(key) for key in ("scroll", "bounds", "keyboard", "english", "offline", "stale_source")):
            raise RuntimeError(f"portrait layout scroll/bounds failure at {width}x{height}: {check!r}; keyboard traversal failed or offline fallback/stale-source check failed")
        checks.append({"size": [width, height], **check})
    cdp.command("Emulation.clearDeviceMetricsOverride")
    return checks


def run_headless_scene_smoke(output_path: Path) -> int:
    result: dict = {"status": "deferred", "runner": "google-chrome-cdp-headless", "output": str(output_path)}
    game: subprocess.Popen[bytes] | None = None
    chrome: subprocess.Popen[bytes] | None = None
    cdp: Cdp | None = None
    try:
        if not Path(CHROME).exists():
            raise RuntimeError(f"Chrome executable unavailable: {CHROME}")
        with tempfile.TemporaryDirectory(prefix="aerosim-gsp-webgl-") as temp_dir:
            stop_path = Path(temp_dir) / "stop"
            game = subprocess.Popen(
                [GODOT, "--headless", "--path", str(ROOT), "--script", "res://tests/headless/gsp_launcher_harness.gd", "--", "--stop-file", str(stop_path)],
                cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env=os.environ.copy(),
            )
            panel_url = read_panel_url(game, time.monotonic() + 20.0)
            debug_port = 9230
            chrome = subprocess.Popen(
                [CHROME, "--headless=new", "--use-angle=swiftshader", f"--remote-debugging-port={debug_port}", "--remote-debugging-address=127.0.0.1", f"--user-data-dir={temp_dir}", "--no-first-run", "--no-default-browser-check", "about:blank"],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, env=os.environ.copy(),
            )
            target = wait_for_target(debug_port, time.monotonic() + 15.0)
            cdp = Cdp(str(target["webSocketDebuggerUrl"]))
            cdp.command("Page.enable")
            cdp.command("Runtime.enable")
            cdp.command("Page.addScriptToEvaluateOnNewDocument", {"source": "window.__AEROSIM_PANEL_TEST__ = {};"})
            cdp.command("Page.navigate", {"url": panel_url})
            evidence = cdp.evaluate(
                """(async () => {
                    const deadline = performance.now() + 5000;
                    while (performance.now() < deadline) {
                      const visual = window.__AEROSIM_GSP_VISUAL__;
                      if (visual && visual.status().available) break;
                      await new Promise(requestAnimationFrame);
                    }
                    const canvas = document.getElementById('airframe-3d');
                    return {
                      three_revision: window.THREE && window.THREE.REVISION,
                      visual: window.__AEROSIM_GSP_VISUAL__ && window.__AEROSIM_GSP_VISUAL__.status(),
                      webgl: !!canvas && (!!canvas.getContext('webgl2') || !!canvas.getContext('webgl')),
                    };
                })()"""
            )
            if not isinstance(evidence, dict) or evidence.get("three_revision") != "180" or not evidence.get("webgl") or evidence.get("visual", {}).get("rotor_count") != 4 or evidence.get("visual", {}).get("available") is not True:
                result["evidence"] = evidence
                raise RuntimeError("installed file:// GSP bundle did not expose WebGL Three.js flight health")
            result.update({"status": "qualified", "panel_url": panel_url, "evidence": evidence, "portrait": check_portrait_console(cdp)})
            stop_path.touch()
    except Exception as error:
        result["reason"] = str(error)
    finally:
        if cdp is not None:
            cdp.close()
        if chrome is not None:
            chrome.terminate()
            try:
                chrome.wait(timeout=5)
            except subprocess.TimeoutExpired:
                chrome.kill()
        if game is not None:
            game.terminate()
            try:
                game.wait(timeout=5)
            except subprocess.TimeoutExpired:
                game.kill()
        output_path.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(result, sort_keys=True))
    return 0 if result["status"] == "qualified" else 1


def main() -> int:
    output_path = Path(os.environ.get("AEROSIM_GSP_BROWSER_OUTPUT", "build/gsp-browser/performance.raw.json"))
    output_path.parent.mkdir(parents=True, exist_ok=True)
    if os.environ.get("AEROSIM_GSP_BROWSER_HEADLESS") == "1":
        return run_headless_scene_smoke(output_path)
    result: dict = {"status": "deferred", "runner": "google-chrome-cdp", "output": str(output_path)}
    game: subprocess.Popen[bytes] | None = None
    chrome: subprocess.Popen[bytes] | None = None
    cdp: Cdp | None = None
    try:
        if not Path(CHROME).exists():
            raise RuntimeError(f"Chrome executable unavailable: {CHROME}")
        if not os.environ.get("DISPLAY") and not os.environ.get("WAYLAND_DISPLAY"):
            raise RuntimeError("real headed browser requires DISPLAY or WAYLAND_DISPLAY")
        with tempfile.TemporaryDirectory(prefix="aerosim-gsp-browser-") as temp_dir:
            game = subprocess.Popen(
                [GODOT, "--display-driver", "wayland", "--path", str(ROOT)],
                cwd=ROOT,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                env=os.environ.copy(),
            )
            panel_url = read_panel_url(game, time.monotonic() + 20.0)
            debug_port = 9229
            chrome = subprocess.Popen(
                [CHROME, f"--remote-debugging-port={debug_port}", "--remote-debugging-address=127.0.0.1", f"--user-data-dir={temp_dir}", "--no-first-run", "--no-default-browser-check", "about:blank"],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                env=os.environ.copy(),
            )
            target = wait_for_target(debug_port, time.monotonic() + 15.0)
            cdp = Cdp(str(target["webSocketDebuggerUrl"]))
            cdp.command("Page.enable")
            cdp.command("Runtime.enable")
            cdp.command("Page.addScriptToEvaluateOnNewDocument", {"source": "window.__AEROSIM_PANEL_TEST__ = {};"})
            cdp.command("Page.bringToFront")
            cdp.command("Page.navigate", {"url": panel_url})
            visual = cdp.evaluate(
                """(async () => {
                    const deadline = performance.now() + 5000;
                    while (performance.now() < deadline && !window.__AEROSIM_GSP_VISUAL__) await new Promise(requestAnimationFrame);
                    const canvas = document.getElementById('airframe-3d');
                    const sample = document.createElement('canvas'); sample.width = 96; sample.height = 48;
                    const context = sample.getContext('2d'); context.drawImage(canvas, 0, 0, sample.width, sample.height);
                    const pixels = context.getImageData(0, 0, sample.width, sample.height).data;
                    let visiblePixels = 0;
                    for (let index = 0; index < pixels.length; index += 4) {
                      if (pixels[index] > 12 || pixels[index + 1] > 12 || pixels[index + 2] > 12) visiblePixels += 1;
                    }
                    return { loaded: !!window.__AEROSIM_GSP_VISUAL__, visible_pixels: visiblePixels };
                })()"""
            )
            if not isinstance(visual, dict) or not visual.get("loaded") or not isinstance(visual.get("visible_pixels"), int) or visual["visible_pixels"] <= 0:
                result["visual"] = visual
                raise RuntimeError("production GSP visual module did not render visible pixels")
            result["portrait"] = check_portrait_console(cdp)
            layout = cdp.evaluate(
                """(() => {
                    const heights = () => [
                      document.getElementById('flight-diagnostics').closest('.card').getBoundingClientRect().height,
                      document.getElementById('hardware-configuration').closest('.card').getBoundingClientRect().height,
                      document.getElementById('telemetry-data').closest('.card').getBoundingClientRect().height,
                    ];
                    const before = heights();
                    document.getElementById('flight-diagnostics').textContent = 'diagnostic\\n'.repeat(200);
                    document.getElementById('hardware-configuration').textContent = 'hardware\\n'.repeat(200);
                    document.getElementById('hardware-derived').textContent = 'derived\\n'.repeat(200);
                    document.getElementById('telemetry-data').textContent = 'telemetry\\n'.repeat(400);
                    const after = heights();
                    return { before, after, stable: before.every((height, index) => Math.abs(height - after[index]) < 0.5) };
                })()"""
            )
            if not isinstance(layout, dict) or not layout.get("stable"):
                result["layout"] = layout
                raise RuntimeError("telemetry updates changed GSP card heights")
            samples = cdp.evaluate(
                """(async () => {
                    const deadline = performance.now() + 15000;
                    while (performance.now() < deadline) {
                      const button = document.querySelector('.tuning-row button');
                      const input = document.querySelector('.tuning-row input[type="number"]');
                      const perf = window.__AEROSIM_GSP_PERF__;
                      if (button && input && perf && !button.disabled && !input.disabled) {
                        for (let sampleIndex = 0; sampleIndex < 100; sampleIndex += 1) {
                          input.value = String(0.61 + (sampleIndex % 4) * 0.01);
                          button.click();
                          const sampleDeadline = performance.now() + 5000;
                          while (performance.now() < sampleDeadline) {
                            const snapshot = perf.snapshot();
                            if (snapshot.request_to_native_commit_ms.length > sampleIndex && snapshot.native_commit_to_rendered_ack_ms.length > sampleIndex) break;
                            await new Promise(requestAnimationFrame);
                          }
                          const completed = perf.snapshot();
                          if (completed.request_to_native_commit_ms.length <= sampleIndex || completed.native_commit_to_rendered_ack_ms.length <= sampleIndex) throw new Error('production panel did not produce a correlated timing sample');
                        }
                        return perf.snapshot();
                      }
                      await new Promise(requestAnimationFrame);
                    }
                    throw new Error('production panel did not authenticate and render tuning controls');
                  })()"""
            )
            if not isinstance(samples, dict):
                raise RuntimeError(f"production panel returned invalid performance payload: {samples!r}")
            request_samples = samples.get("request_to_native_commit_ms", [])
            rendered_samples = samples.get("native_commit_to_rendered_ack_ms", [])
            if len(request_samples) < 100 or len(rendered_samples) < 100:
                result.update({"panel_url": panel_url, "browser": "Google Chrome", "browser_version": cdp.command("Browser.getVersion").get("product", ""), "performance": samples, "sample_counts": {"request_to_native_commit": len(request_samples), "native_commit_to_rendered_ack": len(rendered_samples)}})
                raise RuntimeError("production panel returned fewer than 100 correlated samples")
            clock_sync = samples.get("clock_sync", {})
            if not isinstance(clock_sync, dict) or not isinstance(clock_sync.get("samples"), (int, float)) or clock_sync.get("samples", 0) < 1 or not all(isinstance(clock_sync.get(key), (int, float)) and clock_sync.get(key) >= 0 for key in ("best_rtt_ms", "error_bound_ms")):
                raise RuntimeError("production panel returned invalid monotonic clock-sync evidence")

            def percentile(values: list[float], fraction: float) -> float:
                ordered = sorted(values)
                return ordered[min(len(ordered) - 1, max(0, int((len(ordered) * fraction + 0.999999999) // 1) - 1))]

            timing_stats = {}
            for name, values in (("request_to_native_commit", request_samples), ("native_commit_to_rendered_ack", rendered_samples)):
                timing_stats[name] = {"p50_ms": percentile(values, 0.50), "p95_ms": percentile(values, 0.95), "p99_ms": percentile(values, 0.99)}
            request_p99 = timing_stats["request_to_native_commit"]["p99_ms"]
            rendered_p99 = timing_stats["native_commit_to_rendered_ack"]["p99_ms"]
            result.update({"status": "qualified" if request_p99 < 50.0 and rendered_p99 < 50.0 else "fail", "panel_url": panel_url, "browser": "Google Chrome", "browser_version": cdp.command("Browser.getVersion").get("product", ""), "performance": samples, "timing_stats": timing_stats, "p99_ms": {"request_to_native_commit": request_p99, "native_commit_to_rendered_ack": rendered_p99}})
            if result["status"] != "qualified":
                result["reason"] = "one or more production panel timing p99 values reached 50 ms"
    except Exception as error:
        result["reason"] = str(error)
        result["environment"] = {"DISPLAY": bool(os.environ.get("DISPLAY")), "WAYLAND_DISPLAY": bool(os.environ.get("WAYLAND_DISPLAY")), "chrome": CHROME}
    finally:
        if cdp is not None:
            cdp.close()
        if chrome is not None:
            chrome.terminate()
            try:
                chrome.wait(timeout=5)
            except subprocess.TimeoutExpired:
                chrome.kill()
        if game is not None:
            game.terminate()
            try:
                game.wait(timeout=5)
            except subprocess.TimeoutExpired:
                game.kill()
        output_path.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(result, sort_keys=True))
    return 0 if result["status"] == "qualified" else 1


if __name__ == "__main__":
    raise SystemExit(main())
