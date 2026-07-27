#!/usr/bin/env python3
"""Exercise the native transport boundary under real socket backpressure."""

from __future__ import annotations

import json
import socket
import subprocess
import tempfile
import time
from pathlib import Path

from test_gsp_transport import GODOT, receive_frame, read_ready, send_text, websocket_connect


ROOT = Path(__file__).resolve().parents[1]


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="aerosim-gsp-boundary-") as temp_dir:
        temp = Path(temp_dir)
        ready = temp / "ready.json"
        stop = temp / "stop"
        status = temp / "status.json"
        command = [
            GODOT,
            "--headless",
            "--fixed-fps",
            "30",
            "--path",
            str(ROOT),
            "--script",
            "res://tests/headless/gsp_server_harness.gd",
            "--",
            "--ready-file",
            str(ready),
            "--stop-file",
            str(stop),
            "--status-file",
            str(status),
            "--large-identity",
        ]
        process = subprocess.Popen(command, cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        sock: socket.socket | None = None
        observed_close = False
        boundary_ok = False
        sent = 0
        try:
            identity = read_ready(ready, process)
            sock = websocket_connect("127.0.0.1", int(identity["port"]))
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4096)
            send_text(sock, json.dumps({"v": 2, "t": "auth", "seq": 0, "d": {"token": identity["token"]}}))
            opcode, payload = receive_frame(sock)
            hello = json.loads(payload.decode("utf-8"))
            if opcode != 1 or hello.get("t") != "hello":
                raise RuntimeError(f"invalid boundary hello: {hello!r}")

            sock.settimeout(1.0)
            for sequence in range(1, 101):
                try:
                    send_text(sock, json.dumps({"v": 2, "t": "ping", "seq": sequence, "d": {"request": sequence}}, separators=(",", ":")))
                    sent += 1
                except (BrokenPipeError, ConnectionResetError, TimeoutError, socket.timeout, OSError):
                    break
            if sent == 0:
                raise RuntimeError("backpressure fixture sent no application packets")

            deadline = time.monotonic() + 3.0
            sock.settimeout(1.0)
            pong_requests: list[int] = []
            close_code: int | None = None
            while time.monotonic() < deadline:
                try:
                    opcode, payload = receive_frame(sock)
                    if opcode == 1:
                        message = json.loads(payload.decode("utf-8"))
                        if message.get("t") == "pong":
                            pong_requests.append(int(message["d"]["echo"]["request"]))
                    if opcode == 8:
                        observed_close = True
                        close_code = int.from_bytes(payload[:2], "big") if len(payload) >= 2 else None
                        break
                except socket.timeout:
                    continue
                except (ConnectionResetError, OSError):
                    break
            if not observed_close:
                raise RuntimeError("backpressure peer did not observe a WebSocket close")
            if not pong_requests or pong_requests != list(range(1, len(pong_requests) + 1)):
                raise RuntimeError(f"pong prefix was not contiguous: {pong_requests!r}")
            if close_code != 1008:
                raise RuntimeError(f"unexpected reliable close code: {close_code!r}")
            boundary_ok = True
            time.sleep(1.2)
        finally:
            if sock is not None:
                sock.close()
            stop.touch()
            try:
                output, _ = process.communicate(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                output, _ = process.communicate()
                raise RuntimeError("GSP boundary harness did not stop")
            if process.returncode not in (0, None):
                raise RuntimeError(f"GSP boundary harness failed: {output.decode(errors='replace')}")
            if not status.exists():
                raise RuntimeError("GSP boundary harness did not publish status")
            diagnostics = json.loads(status.read_text(encoding="utf-8"))
            if diagnostics["reliable_overflow_count"] == 0 and diagnostics["reliable_send_failure_count"] == 0:
                raise RuntimeError(f"reliable backpressure was not recorded after sent={sent}: {diagnostics!r}")
            if diagnostics["reliable_overflow_count"] == 0 or diagnostics["reliable_send_failure_count"] != 0:
                raise RuntimeError(f"reliable overflow was not isolated from send failure: {diagnostics!r}")
            if not diagnostics["last_reliable_error"]:
                raise RuntimeError(f"reliable backpressure had no observable error: {diagnostics!r}")
            if diagnostics["max_closing_peer_count"] == 0 or diagnostics["closing_peer_count"] != 0 or diagnostics["after_stop_live_peer_count"] != 0:
                raise RuntimeError(f"reliable peer was not retained then reclaimed by deadline: {diagnostics!r}")
            if boundary_ok:
                print("GSP transport boundary backpressure: PASS sent=%d diagnostics=%s" % (sent, diagnostics))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
