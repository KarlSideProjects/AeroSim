#!/usr/bin/env python3
"""Exercise the native transport boundary under real socket backpressure."""

from __future__ import annotations

import json
import select
import socket
import subprocess
import tempfile
import time
from pathlib import Path

from test_gsp_transport import GODOT, receive_frame, read_ready, send_text, websocket_connect


ROOT = Path(__file__).resolve().parents[1]


def wait_for_eof(sock: socket.socket, timeout: float) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        remaining = max(0.0, deadline - time.monotonic())
        readable, _, _ = select.select([sock], [], [], min(0.1, remaining))
        if not readable:
            continue
        if sock.recv(1) == b"":
            return True
    return False


def assert_stays_open(sock: socket.socket, timeout: float) -> None:
    readable, _, _ = select.select([sock], [], [], timeout)
    if readable and sock.recv(1) == b"":
        raise RuntimeError("replacement pending peer was reclaimed before the timeout")


def send_close(sock: socket.socket, payload: bytes) -> None:
    mask = b"\x00\x00\x00\x00"
    masked = bytes(byte ^ mask[index % 4] for index, byte in enumerate(payload))
    sock.sendall(bytes([0x88, 0x80 | len(payload)]) + mask + masked)


def harness_command(ready: Path, stop: Path, status: Path, large_identity: bool) -> list[str]:
    command = [
        GODOT,
        "--headless",
        "--fixed-fps",
        "240",
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
    ]
    if large_identity:
        command.append("--large-identity")
    return command


def start_harness(temp: Path, large_identity: bool) -> tuple[subprocess.Popen[bytes], dict[str, object], Path, Path, Path]:
    ready = temp / "ready.json"
    stop = temp / "stop"
    status = temp / "status.json"
    process = subprocess.Popen(
        harness_command(ready, stop, status, large_identity),
        cwd=ROOT,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    return process, read_ready(ready, process), stop, status, ready


def finish_harness(process: subprocess.Popen[bytes], stop: Path, status: Path) -> dict[str, object]:
    if process.poll() is None:
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
    return json.loads(status.read_text(encoding="utf-8"))


def run_pending_handshake_boundary(temp: Path) -> None:
    process, identity, stop, status, _ = start_harness(temp, False)
    held: list[socket.socket] = []
    rejected: socket.socket | None = None
    replacement: socket.socket | None = None
    try:
        address = ("127.0.0.1", int(identity["port"]))
        pending_limit = int(identity["max_pending_handshakes"])
        for _ in range(pending_limit):
            held.append(socket.create_connection(address, timeout=1.0))
        time.sleep(0.5)

        rejected = socket.create_connection(address, timeout=1.0)
        if not wait_for_eof(rejected, 1.5):
            raise RuntimeError("ninth incomplete handshake was not rejected")

        timeout_seconds = 7.0
        time.sleep(timeout_seconds)

        for index, peer in enumerate(held, start=1):
            if not wait_for_eof(peer, 1.0):
                raise RuntimeError(f"held incomplete handshake {index} was not reclaimed by the server")

        replacement = socket.create_connection(address, timeout=1.0)
        assert_stays_open(replacement, 0.5)
        print("GSP pending handshake boundary: PASS peers=%d all_reclaimed=true capacity_reused=true" % pending_limit)
    finally:
        for peer in held:
            peer.close()
        if rejected is not None:
            rejected.close()
        if replacement is not None:
            replacement.close()
        diagnostics = finish_harness(process, stop, status)
        if diagnostics["live_peer_count"] != 0 or diagnostics["closing_peer_count"] != 0:
            raise RuntimeError(f"pending handshake peers remained at snapshot: {diagnostics!r}")


def authenticate(sock: socket.socket, identity: dict[str, object]) -> None:
    send_text(sock, json.dumps({"v": 2, "t": "auth", "seq": 0, "d": {"token": identity["token"]}}))
    opcode, payload = receive_frame(sock)
    hello = json.loads(payload.decode("utf-8"))
    if opcode != 1 or hello.get("t") != "hello":
        raise RuntimeError(f"invalid boundary hello: {hello!r}")


def run_graceful_case(temp: Path) -> None:
    process, identity, stop, status, _ = start_harness(temp, True)
    sock: socket.socket | None = None
    try:
        sock = websocket_connect("127.0.0.1", int(identity["port"]))
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 262144)
        authenticate(sock, identity)
        sock.settimeout(1.0)
        sent = 0
        for sequence in range(1, 101):
            send_text(sock, json.dumps({"v": 2, "t": "ping", "seq": sequence, "d": {"request": sequence}}, separators=(",", ":")))
            sent += 1
        pongs: list[int] = []
        close_payload: bytes | None = None
        deadline = time.monotonic() + 3.0
        while time.monotonic() < deadline:
            opcode, payload = receive_frame(sock)
            if opcode == 1:
                message = json.loads(payload.decode("utf-8"))
                if message.get("t") == "pong":
                    pongs.append(int(message["d"]["echo"]["request"]))
            elif opcode == 8:
                close_payload = payload
                if payload:
                    send_close(sock, payload)
                break
        if not close_payload or len(close_payload) < 2:
            raise RuntimeError("graceful boundary did not receive a close frame")
        close_code = int.from_bytes(close_payload[:2], "big")
        if close_code != 1008:
            raise RuntimeError(f"unexpected graceful close code: {close_code!r}")
        if not pongs or pongs != list(range(1, len(pongs) + 1)):
            raise RuntimeError(f"graceful pong prefix was not contiguous: {pongs!r}")
        stop.touch()
        diagnostics = finish_harness(process, stop, status)
        if diagnostics["reliable_overflow_count"] != 1 or diagnostics["reliable_send_failure_count"] != 0:
            raise RuntimeError(f"graceful reliable diagnostics were wrong after sent={sent}: {diagnostics!r}")
        print("GSP graceful boundary: PASS pongs=%d close_code=1008" % len(pongs))
    finally:
        if sock is not None:
            sock.close()


def run_forced_case(temp: Path) -> None:
    process, identity, stop, status, _ = start_harness(temp, True)
    sock: socket.socket | None = None
    try:
        sock = websocket_connect("127.0.0.1", int(identity["port"]))
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4096)
        authenticate(sock, identity)
        sent = 0
        for sequence in range(1, 101):
            send_text(sock, json.dumps({"v": 2, "t": "ping", "seq": sequence, "d": {"request": sequence}}, separators=(",", ":")))
            sent += 1
        time.sleep(int(identity["closing_peer_timeout_ms"]) / 1000.0 + 1.0)
        stop.touch()
        diagnostics = finish_harness(process, stop, status)
        if diagnostics["reliable_overflow_count"] != 1 or diagnostics["reliable_send_failure_count"] != 0:
            raise RuntimeError(f"forced reliable diagnostics were wrong after sent={sent}: {diagnostics!r}")
        if diagnostics["max_closing_peer_count"] < 1 or diagnostics["live_peer_count"] != 0 or diagnostics["closing_peer_count"] != 0:
            raise RuntimeError(f"forced peer was not retained then reclaimed: {diagnostics!r}")
        print("GSP forced boundary: PASS max_closing=%d" % diagnostics["max_closing_peer_count"])
    finally:
        if sock is not None:
            sock.close()


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="aerosim-gsp-pending-") as temp_dir:
        run_pending_handshake_boundary(Path(temp_dir))
    with tempfile.TemporaryDirectory(prefix="aerosim-gsp-graceful-") as temp_dir:
        run_graceful_case(Path(temp_dir))
    with tempfile.TemporaryDirectory(prefix="aerosim-gsp-forced-") as temp_dir:
        run_forced_case(Path(temp_dir))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
