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


def main() -> int:
    output_path = Path(os.environ.get("AEROSIM_GSP_BROWSER_OUTPUT", "build/gsp-browser/performance.raw.json"))
    output_path.parent.mkdir(parents=True, exist_ok=True)
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
                [GODOT, "--display-driver", "wayland", "--path", str(ROOT), "--", "--aerosim-gsp", "--aerosim-gsp-no-open"],
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
            cdp.command("Page.bringToFront")
            cdp.command("Page.navigate", {"url": panel_url})
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
