#!/usr/bin/env python3
"""Run fixed-runner GSP transport and raw-handshake evidence."""

from __future__ import annotations

import base64
import hashlib
import json
import math
import os
import secrets
import socket
import struct
import subprocess
import tempfile
import time
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
GODOT = os.environ.get("GODOT_BIN", "godot")


def recv_exact(sock: socket.socket, size: int) -> bytes:
    result = bytearray()
    while len(result) < size:
        chunk = sock.recv(size - len(result))
        if not chunk:
            raise RuntimeError("peer closed while reading a WebSocket frame")
        result.extend(chunk)
    return bytes(result)


def send_text(sock: socket.socket, value: str) -> None:
    payload = value.encode("utf-8")
    mask = secrets.token_bytes(4)
    masked = bytes(byte ^ mask[index % 4] for index, byte in enumerate(payload))
    if len(payload) < 126:
        header = bytes([0x81, 0x80 | len(payload)])
    elif len(payload) < 65536:
        header = bytes([0x81, 0x80 | 126]) + struct.pack("!H", len(payload))
    else:
        header = bytes([0x81, 0x80 | 127]) + struct.pack("!Q", len(payload))
    sock.sendall(header + mask + masked)


def receive_frame(sock: socket.socket) -> tuple[int, bytes]:
    first, second = recv_exact(sock, 2)
    opcode = first & 0x0F
    length = second & 0x7F
    if length == 126:
        length = struct.unpack("!H", recv_exact(sock, 2))[0]
    elif length == 127:
        length = struct.unpack("!Q", recv_exact(sock, 8))[0]
    if second & 0x80:
        mask = recv_exact(sock, 4)
        payload = recv_exact(sock, length)
        payload = bytes(byte ^ mask[index % 4] for index, byte in enumerate(payload))
    else:
        payload = recv_exact(sock, length)
    return opcode, payload


def websocket_connect(host: str, port: int) -> socket.socket:
    sock = socket.create_connection((host, port), timeout=5.0)
    key = base64.b64encode(secrets.token_bytes(16)).decode("ascii")
    request = (
        f"GET / HTTP/1.1\r\nHost: {host}:{port}\r\n"
        "Upgrade: websocket\r\nConnection: Upgrade\r\n"
        f"Origin: null\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: {key}\r\n\r\n"
    ).encode("ascii")
    sock.sendall(request)
    response = bytearray()
    while b"\r\n\r\n" not in response:
        response.extend(sock.recv(4096))
        if len(response) > 8192:
            raise RuntimeError("oversized WebSocket handshake response")
    if not response.startswith(b"HTTP/1.1 101 "):
        raise RuntimeError(f"unexpected WebSocket handshake response: {response[:80]!r}")
    expected = base64.b64encode(hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode("ascii")).digest()).decode("ascii")
    if f"Sec-WebSocket-Accept: {expected}".encode("ascii") not in response:
        raise RuntimeError("WebSocket handshake accept key did not match")
    return sock


def malformed_request_probe(host: str, port: int) -> None:
    requests = [
        b"GET /\r\nHost: 127.0.0.1\r\n\r\n",
        b"GET / extra HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n",
        b"GET / HTTP/1.1 EXTRA\r\nHost: 127.0.0.1\r\n\r\n",
    ]
    for request in requests:
        with socket.create_connection((host, port), timeout=2.0) as sock:
            sock.sendall(request)
            sock.settimeout(0.2)
            try:
                sock.recv(128)
            except (socket.timeout, ConnectionResetError):
                pass


def read_ready(path: Path, process: subprocess.Popen[bytes]) -> dict:
    deadline = time.monotonic() + 10.0
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError(f"Godot harness exited with status {process.returncode}")
        if path.exists():
            try:
                return json.loads(path.read_text(encoding="utf-8"))
            except json.JSONDecodeError:
                time.sleep(0.01)
                continue
        time.sleep(0.01)
    raise RuntimeError("timed out waiting for GSP harness")


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="aerosim-gsp-") as temp_dir:
        temp = Path(temp_dir)
        ready = temp / "ready.json"
        stop = temp / "stop"
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
        ]
        process = subprocess.Popen(command, cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        try:
            identity = read_ready(ready, process)
            host = "127.0.0.1"
            port = int(identity["port"])
            token = str(identity["token"])
            malformed_request_probe(host, port)
            with websocket_connect(host, port) as sock:
                send_text(sock, json.dumps({"v": 2, "t": "auth", "seq": 0, "d": {"token": token}}))
                opcode, payload = receive_frame(sock)
                hello = json.loads(payload.decode("utf-8"))
                if opcode != 1 or hello.get("v") != 2 or hello.get("t") != "hello":
                    raise RuntimeError(f"invalid hello envelope: {hello!r}")
                samples_ns: list[int] = []
                for sequence in range(1000):
                    request = {"client_timestamp_ns": time.perf_counter_ns(), "request": sequence}
                    started_ns = time.perf_counter_ns()
                    send_text(sock, json.dumps({"v": 2, "t": "ping", "seq": sequence + 1, "d": request}, separators=(",", ":")))
                    opcode, payload = receive_frame(sock)
                    elapsed_ns = time.perf_counter_ns() - started_ns
                    pong = json.loads(payload.decode("utf-8"))
                    if opcode != 1 or pong.get("v") != 2 or pong.get("t") != "pong" or pong.get("d", {}).get("echo") != request:
                        raise RuntimeError(f"invalid pong envelope at {sequence}: {pong!r}")
                    samples_ns.append(elapsed_ns)
            samples_ns.sort()
            p99_ns = samples_ns[math.ceil(len(samples_ns) * 0.99) - 1]
            p99_ms = p99_ns / 1_000_000.0
            print(f"GSP fixed-runner transport: PASS samples=1000 p99_ms={p99_ms:.3f}")
            if p99_ms >= 5.0:
                raise RuntimeError(f"fixed-runner localhost RTT p99 was {p99_ms:.3f} ms")
            return 0
        finally:
            stop.touch()
            try:
                output, _ = process.communicate(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                output, _ = process.communicate()
                raise RuntimeError("GSP server harness did not stop")
            if process.returncode not in (0, None):
                raise RuntimeError(f"GSP server harness failed: {output.decode(errors='replace')}")


if __name__ == "__main__":
    raise SystemExit(main())
