#!/usr/bin/env python3
"""Exercise the native transport boundary under real socket backpressure."""

from __future__ import annotations

import json
import re
import select
import socket
import subprocess
import struct
import tempfile
import time
from collections.abc import Callable
from pathlib import Path

from test_gsp_transport import GODOT, receive_frame, read_ready, send_text, websocket_connect


ROOT = Path(__file__).resolve().parents[1]
LAUNCHER_URL = re.compile(r"GSP panel URL: (?P<url>file://[^\s]+#port=(?P<port>\d+)&token=(?P<token>[0-9a-f]{32}))")


class ProbePublicationTimeout(RuntimeError):
    pass


def wait_for_eof(sock: socket.socket, timeout: float) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        remaining = max(0.0, deadline - time.monotonic())
        readable, _, _ = select.select([sock], [], [], min(0.1, remaining))
        if not readable:
            continue
        try:
            if sock.recv(1) == b"":
                return True
        except ConnectionResetError:
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


def encode_text_frame(value: str) -> bytes:
    payload = value.encode("utf-8")
    mask = b"\x00\x00\x00\x00"
    masked = bytes(byte ^ mask[index % 4] for index, byte in enumerate(payload))
    if len(payload) < 126:
        header = bytes([0x81, 0x80 | len(payload)])
    elif len(payload) < 65536:
        header = bytes([0x81, 0x80 | 126]) + struct.pack("!H", len(payload))
    else:
        header = bytes([0x81, 0x80 | 127]) + struct.pack("!Q", len(payload))
    return header + mask + masked


def harness_command(ready: Path, stop: Path, status: Path, probe: Path, large_identity: bool, telemetry: bool = False) -> list[str]:
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
        "--probe-file",
        str(probe),
    ]
    if large_identity:
        command.append("--large-identity")
    if telemetry:
        command.append("--telemetry")
    return command


def start_harness(temp: Path, large_identity: bool, telemetry: bool = False) -> tuple[subprocess.Popen[bytes], dict[str, object], Path, Path, Path, Path]:
    ready = temp / "ready.json"
    stop = temp / "stop"
    status = temp / "status.json"
    probe = temp / "probe"
    process = subprocess.Popen(
        harness_command(ready, stop, status, probe, large_identity, telemetry),
        cwd=ROOT,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    return process, read_ready(ready, process), stop, status, ready, probe


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


def delayed_probe_harness_command(temp: Path) -> tuple[list[str], Path, Path, Path, Path]:
    ready = temp / "ready.json"
    stop = temp / "stop"
    status = temp / "status.json"
    probe = temp / "probe"
    return [
        GODOT,
        "--headless",
        "--fixed-fps",
        "240",
        "--path",
        str(ROOT),
        "--script",
        "res://tests/headless/gsp_delayed_probe_harness.gd",
        "--",
        "--ready-file",
        str(ready),
        "--stop-file",
        str(stop),
        "--status-file",
        str(status),
        "--probe-file",
        str(probe),
        "--probe-delay-ms",
        "700",
    ], ready, stop, status, probe


def start_delayed_probe_harness(temp: Path) -> tuple[subprocess.Popen[bytes], dict[str, object], Path, Path, Path, Path]:
    command, ready, stop, status, probe = delayed_probe_harness_command(temp)
    process = subprocess.Popen(command, cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    return process, read_ready(ready, process), stop, status, ready, probe


def launcher_command(stop: Path) -> list[str]:
    return [
        GODOT,
        "--headless",
        "--path",
        str(ROOT),
        "--script",
        "res://tests/headless/gsp_launcher_harness.gd",
        "--",
        "--stop-file",
        str(stop),
    ]


def stop_launcher_harness(process: subprocess.Popen[bytes], stop: Path) -> str:
    if process.poll() is None:
        stop.touch()
    try:
        output, _ = process.communicate(timeout=2)
    except subprocess.TimeoutExpired:
        process.kill()
        try:
            output, _ = process.communicate(timeout=2)
        except subprocess.TimeoutExpired as error:
            raise RuntimeError("GSP launcher harness could not be stopped") from error
    return output.decode(errors="replace")


def start_launcher_harness(temp: Path) -> tuple[subprocess.Popen[bytes], dict[str, object], Path, list[str]]:
    stop = temp / "stop"
    process = subprocess.Popen(
        launcher_command(stop),
        cwd=ROOT,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    if process.stdout is None:
        stop_launcher_harness(process, stop)
        raise RuntimeError("GSP launcher harness did not expose stdout")
    deadline = time.monotonic() + 5.0
    output: list[str] = []
    while time.monotonic() < deadline:
        readable, _, _ = select.select([process.stdout], [], [], 0.1)
        if not readable:
            if process.poll() is not None:
                break
            continue
        line = process.stdout.readline().decode(errors="replace")
        output.append(line)
        match = LAUNCHER_URL.search(line)
        if match:
            return process, {"port": int(match["port"]), "token": match["token"], "url": match["url"]}, stop, output
    output.append(stop_launcher_harness(process, stop))
    raise RuntimeError(f"GSP launcher harness did not print a launch URL: {''.join(output)}")


def finish_launcher_harness(process: subprocess.Popen[bytes], stop: Path, output: list[str]) -> None:
    output.append(stop_launcher_harness(process, stop))
    if process.returncode not in (0, None):
        raise RuntimeError(f"GSP launcher harness failed: {''.join(output)}")
    if len(list(LAUNCHER_URL.finditer("".join(output)))) != 1:
        raise RuntimeError(f"GSP launcher stdout must contain exactly one panel URL record: {''.join(output)}")


def poll_until_reclaimed(
    probe: Callable[[int, float], dict[str, object]],
    process_exited: Callable[[], bool],
    deadline: float,
    sequence: int,
) -> tuple[dict[str, object], int]:
    while time.monotonic() < deadline:
        if process_exited():
            raise RuntimeError("GSP boundary harness exited during abrupt reclaim")
        remaining = deadline - time.monotonic()
        try:
            snapshot = probe(sequence, min(0.25, remaining))
        except ProbePublicationTimeout:
            continue
        if (snapshot["live_peer_count"], snapshot["authenticated_peer_count"], snapshot["closing_peer_count"]) == (0, 0, 0):
            return snapshot, sequence + 1
        sequence += 1
    raise RuntimeError("abruptly lost peer was not reclaimed within five seconds")


def run_probe_delayed_consumption_regression(temp: Path) -> None:
    process, identity, stop, status, _, probe = start_delayed_probe_harness(temp)
    peer: socket.socket | None = None
    try:
        peer = websocket_connect("127.0.0.1", int(identity["port"]))
        authenticate(peer, identity)
        peer.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
        peer.close()
        peer = None
        try:
            probe_status(process, probe, status, 1, 0.25)
        except ProbePublicationTimeout:
            pass
        else:
            raise RuntimeError("delayed probe unexpectedly published inside the 250 ms timeout")
        snapshot, next_sequence = poll_until_reclaimed(
            lambda sequence, timeout: probe_status(process, probe, status, sequence, timeout),
            lambda: process.poll() is not None,
            time.monotonic() + 5.0,
            1,
        )
        if snapshot["probe_sequence"] != 1 or next_sequence != 2:
            raise RuntimeError(f"delayed probe did not publish the same sequence: {snapshot!r}, next={next_sequence!r}")
        print("GSP probe retry regression: PASS delayed_timeout_retry=true same_sequence=true")
    finally:
        if peer is not None:
            peer.close()
        stop.touch()
        finish_harness(process, stop, status)


def probe_status(process: subprocess.Popen[bytes], probe: Path, status: Path, sequence: int, timeout: float = 5.0) -> dict[str, object]:
    probe.touch()
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError("GSP boundary harness stopped before publishing probe status")
        if status.exists():
            try:
                snapshot = json.loads(status.read_text(encoding="utf-8"))
            except json.JSONDecodeError:
                snapshot = None
            if snapshot is not None and int(snapshot.get("probe_sequence", 0)) >= sequence:
                return snapshot
        time.sleep(0.05)
    raise ProbePublicationTimeout(f"GSP boundary harness did not publish probe status {sequence}")


def run_pending_handshake_boundary(temp: Path) -> None:
    process, identity, stop, status, _, _ = start_harness(temp, False)
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


def authenticate_rejected(sock: socket.socket, token: str) -> None:
    send_text(sock, json.dumps({"v": 2, "t": "auth", "seq": 0, "d": {"token": token}}))
    opcode, payload = receive_frame(sock)
    if opcode == 1:
        raise RuntimeError(f"stale token unexpectedly authenticated: {payload!r}")


def close_websocket(sock: socket.socket) -> None:
    send_close(sock, (1000).to_bytes(2, "big"))
    if not wait_for_eof(sock, 3.0):
        raise RuntimeError("graceful WebSocket close was not reclaimed")


def run_same_process_replacement_case(temp: Path) -> None:
    process, identity, stop, status, _, probe = start_harness(temp, False)
    peers: list[socket.socket] = []
    try:
        first = websocket_connect("127.0.0.1", int(identity["port"]))
        peers.append(first)
        authenticate(first, identity)
        before_close = probe_status(process, probe, status, 1)
        if (before_close["live_peer_count"], before_close["authenticated_peer_count"], before_close["closing_peer_count"]) != (1, 1, 0):
            raise RuntimeError(f"replacement pre-stop peer counts were wrong: {before_close!r}")
        close_websocket(first)
        reclaimed = probe_status(process, probe, status, 2)
        if (reclaimed["live_peer_count"], reclaimed["authenticated_peer_count"], reclaimed["closing_peer_count"]) != (0, 0, 0):
            raise RuntimeError(f"same-process refresh did not reclaim the first peer before replacement: {reclaimed!r}")
        replacement = websocket_connect("127.0.0.1", int(identity["port"]))
        peers.append(replacement)
        authenticate(replacement, identity)
        observer = websocket_connect("127.0.0.1", int(identity["port"]))
        peers.append(observer)
        authenticate(observer, identity)
        replacement_snapshot = probe_status(process, probe, status, 3)
        if (replacement_snapshot["live_peer_count"], replacement_snapshot["authenticated_peer_count"], replacement_snapshot["closing_peer_count"]) != (2, 2, 0):
            raise RuntimeError(f"replacement capacity was not available after reclaim: {replacement_snapshot!r}")
        print("GSP same-process replacement: PASS pre_stop=1/1/0 reclaimed=0/0/0 replacement=2/2/0")
    finally:
        for peer in peers:
            peer.close()
        stop.touch()
        diagnostics = finish_harness(process, stop, status)
        if diagnostics["after_stop_live_peer_count"] != 0:
            raise RuntimeError(f"replacement left peers behind: {diagnostics!r}")


def run_abrupt_reclaim_case(temp: Path) -> None:
    process, identity, stop, status, _, probe = start_harness(temp, False)
    peers: list[socket.socket] = []
    try:
        lost = websocket_connect("127.0.0.1", int(identity["port"]))
        authenticate(lost, identity)
        before_loss = probe_status(process, probe, status, 1)
        if (before_loss["live_peer_count"], before_loss["authenticated_peer_count"], before_loss["closing_peer_count"]) != (1, 1, 0):
            raise RuntimeError(f"abrupt loss pre-stop peer counts were wrong: {before_loss!r}")
        loss_started = time.monotonic()
        lost.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
        lost.close()
        reclaimed, sequence = poll_until_reclaimed(
            lambda current_sequence, timeout: probe_status(process, probe, status, current_sequence, timeout),
            lambda: process.poll() is not None,
            loss_started + 5.0,
            2,
        )
        if time.monotonic() - loss_started > 5.0:
            raise RuntimeError("abruptly lost peer was reclaimed after five seconds")
        if reclaimed["timestamp_ms"] <= before_loss["timestamp_ms"]:
            raise RuntimeError(f"reclaim probe timestamp did not advance: {before_loss!r} -> {reclaimed!r}")
        if reclaimed["process_ticks"] <= before_loss["process_ticks"] or reclaimed["physics_ticks"] <= before_loss["physics_ticks"]:
            raise RuntimeError(f"simulation did not advance while reclaiming abrupt loss: {before_loss!r} -> {reclaimed!r}")
        replacement = websocket_connect("127.0.0.1", int(identity["port"]))
        peers.append(replacement)
        authenticate(replacement, identity)
        observer = websocket_connect("127.0.0.1", int(identity["port"]))
        peers.append(observer)
        authenticate(observer, identity)
        replacement_snapshot = probe_status(process, probe, status, sequence)
        if (replacement_snapshot["live_peer_count"], replacement_snapshot["authenticated_peer_count"], replacement_snapshot["closing_peer_count"]) != (2, 2, 0):
            raise RuntimeError(f"abrupt reclaim replacement capacity was wrong: {replacement_snapshot!r}")
        print("GSP abrupt reclaim: PASS reclaimed_within=%.3fs tick_delta=%d/%d replacement=2/2/0" % (
            time.monotonic() - loss_started,
            reclaimed["process_ticks"] - before_loss["process_ticks"],
            reclaimed["physics_ticks"] - before_loss["physics_ticks"],
        ))
    finally:
        for peer in peers:
            peer.close()
        stop.touch()
        diagnostics = finish_harness(process, stop, status)
        if diagnostics["after_stop_live_peer_count"] != 0 or diagnostics["physics_ticks"] <= 0:
            raise RuntimeError(f"abrupt reclaim did not preserve bounded cleanup/ticks: {diagnostics!r}")


def run_restart_token_case(temp: Path) -> None:
    first_dir = temp / "first"
    second_dir = temp / "second"
    first_dir.mkdir()
    second_dir.mkdir()
    first_process, first_identity, first_stop, first_status, _, _ = start_harness(first_dir, False)
    first_stop.touch()
    finish_harness(first_process, first_stop, first_status)
    second_process, second_identity, second_stop, launcher_output = start_launcher_harness(second_dir)
    stale = None
    fresh = None
    try:
        if first_identity["token"] == second_identity["token"]:
            raise RuntimeError("server restart reused the GSP token")
        stale = websocket_connect("127.0.0.1", int(second_identity["port"]))
        stale.settimeout(2.0)
        authenticate_rejected(stale, str(first_identity["token"]))
        fresh = websocket_connect("127.0.0.1", int(second_identity["port"]))
        authenticate(fresh, second_identity)
        print("GSP restart token: PASS stale_rejected=true fresh_printed_url=true fresh_token_authenticated=true")
    finally:
        if stale is not None:
            stale.close()
        if fresh is not None:
            fresh.close()
        finish_launcher_harness(second_process, second_stop, launcher_output)


def run_graceful_case(temp: Path) -> None:
    process, identity, stop, status, _, _ = start_harness(temp, True)
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
        overflow_error: dict[str, object] | None = None
        close_payload: bytes | None = None
        deadline = time.monotonic() + 3.0
        while time.monotonic() < deadline:
            opcode, payload = receive_frame(sock)
            if opcode == 1:
                message = json.loads(payload.decode("utf-8"))
                if message.get("t") == "pong":
                    pongs.append(int(message["d"]["echo"]["request"]))
                elif message.get("t") == "error" and message.get("d", {}).get("code") == "overflow":
                    overflow_error = message
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
        if diagnostics["reliable_overflow_error_attempt_count"] != 1:
            raise RuntimeError(f"overflow error attempt was not bounded to one local attempt: {diagnostics!r}")
        accepted = int(diagnostics["reliable_overflow_error_accepted_count"])
        if accepted not in (0, 1):
            raise RuntimeError(f"overflow error local acceptance was not boolean: {diagnostics!r}")
        if accepted == 1 and overflow_error is None:
            raise RuntimeError("accepted overflow error was not observed as a WebSocket frame")
        print("GSP graceful boundary: PASS pongs=%d close_code=1008 overflow_error_accepted=%s" % (len(pongs), bool(accepted)))
    finally:
        if sock is not None:
            sock.close()


def run_slow_overflow_case(temp: Path) -> None:
    process, identity, stop, status, _, _ = start_harness(temp, True)
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
            raise RuntimeError(f"slow-peer reliable diagnostics were wrong after sent={sent}: {diagnostics!r}")
        if diagnostics["max_closing_peer_count"] < 1 or diagnostics["live_peer_count"] != 0 or diagnostics["closing_peer_count"] != 0:
            raise RuntimeError(f"slow peer was not retained then reclaimed: {diagnostics!r}")
        print("GSP slow-peer overflow: PASS max_closing=%d" % diagnostics["max_closing_peer_count"])
    finally:
        if sock is not None:
            sock.close()


def run_packet_overload_no_overflow_case(temp: Path) -> None:
    process, identity, stop, status, _, _ = start_harness(temp, False)
    sock: socket.socket | None = None
    try:
        sock = websocket_connect("127.0.0.1", int(identity["port"]))
        authenticate(sock, identity)
        sock.sendall(b"".join(encode_text_frame(json.dumps({"v": 2, "t": "ping", "seq": sequence, "d": {"request": sequence}}, separators=(",", ":"))) for sequence in range(1, 66)))
        time.sleep(0.25)
        stop.touch()
        diagnostics = finish_harness(process, stop, status)
        if diagnostics["reliable_send_failure_count"] != 1 or diagnostics["reliable_overflow_count"] != 0:
            raise RuntimeError(f"packet-count rejection was not an ordinary send failure: {diagnostics!r}")
        if diagnostics["reliable_overflow_error_attempt_count"] != 0:
            raise RuntimeError(f"ordinary packet-count rejection attempted an overflow error: {diagnostics!r}")
        print("GSP packet-count rejection: PASS overflow_error_attempted=false")
    finally:
        if sock is not None:
            sock.close()


def run_peer_isolation_case(temp: Path) -> None:
    process, identity, stop, status, _, probe = start_harness(temp, True, True)
    slow: socket.socket | None = None
    healthy: socket.socket | None = None
    try:
        slow = websocket_connect("127.0.0.1", int(identity["port"]), receive_buffer_bytes=1024)
        authenticate(slow, identity)
        healthy = websocket_connect("127.0.0.1", int(identity["port"]))
        authenticate(healthy, identity)
        suppression_snapshot = None
        max_native_buffered = 0
        suppression_deadline = time.monotonic() + 5.0
        while time.monotonic() < suppression_deadline:
            suppression_snapshot = probe_status(process, probe, status, int(suppression_snapshot["probe_sequence"]) + 1 if suppression_snapshot else 1)
            slow_diagnostics = [item for item in suppression_snapshot["peer_transport_diagnostics"] if int(item.get("peer_id", -1)) == 1]
            max_native_buffered = max(max_native_buffered, *(int(item.get("outbound_buffered_bytes", 0)) for item in slow_diagnostics)) if slow_diagnostics else max_native_buffered
            if any(
                int(item.get("telemetry_slot_sample_seq", 0)) > 0
                and int(item.get("outbound_buffered_bytes", 0)) >= int(identity["telemetry_suppression_threshold_bytes"])
                for item in slow_diagnostics
            ):
                break
        else:
            processing = suppression_snapshot.get("telemetry_processing", {}) if suppression_snapshot else {}
            print(
                "GSP peer isolation: DEFERRED authenticated_slow_peer_native_buffer=%d/%d "
                "telemetry_sends=%d suppression_threshold=%d platform_socket_backpressure_unobservable=true"
                % (
                    max_native_buffered,
                    int(identity["native_outbound_capacity_bytes"]),
                    int(processing.get("send_count", 0)),
                    int(identity["telemetry_suppression_threshold_bytes"]),
                )
            )
            return
        healthy.settimeout(1.0)
        healthy_pongs = 0
        for sequence in range(1, 101):
            send_text(slow, json.dumps({"v": 2, "t": "ping", "seq": sequence, "d": {"request": sequence}}, separators=(",", ":")))
            send_text(healthy, json.dumps({"v": 2, "t": "ping", "seq": sequence, "d": {"request": sequence}}, separators=(",", ":")))
            deadline = time.monotonic() + 1.0
            while time.monotonic() < deadline:
                opcode, payload = receive_frame(healthy)
                if opcode != 1:
                    continue
                message = json.loads(payload.decode("utf-8"))
                if message.get("t") == "pong" and message.get("d", {}).get("echo", {}).get("request") == sequence:
                    healthy_pongs += 1
                    break
        if healthy_pongs < 20:
            raise RuntimeError(f"healthy peer did not continue receiving reliable ACKs: {healthy_pongs}")
        if not wait_for_eof(slow, 3.0):
            raise RuntimeError("hard-pressure peer was not closed")
        snapshot = probe_status(process, probe, status, int(suppression_snapshot["probe_sequence"]) + 1)
        if int(snapshot["hard_close_count"]) < 1:
            raise RuntimeError(f"hard-pressure close was not recorded locally: {snapshot!r}")
        if int(snapshot["authenticated_peer_count"]) != 1 or int(snapshot["closing_peer_count"]) > 1:
            raise RuntimeError(f"hard-pressure close affected the healthy peer set: {snapshot!r}")
        if int(snapshot["authenticated_peer_count"]) != 1:
            raise RuntimeError(f"healthy authenticated peer did not remain isolated: {snapshot!r}")
        print("GSP peer isolation: PASS telemetry_suppressed=true healthy_pongs=%d hard_close_count=%d" % (healthy_pongs, snapshot["hard_close_count"]))
    finally:
        if slow is not None:
            slow.close()
        if healthy is not None:
            healthy.close()
        stop.touch()
        finish_harness(process, stop, status)


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="aerosim-gsp-probe-delay-") as temp_dir:
        run_probe_delayed_consumption_regression(Path(temp_dir))
    with tempfile.TemporaryDirectory(prefix="aerosim-gsp-pending-") as temp_dir:
        run_pending_handshake_boundary(Path(temp_dir))
    with tempfile.TemporaryDirectory(prefix="aerosim-gsp-graceful-") as temp_dir:
        run_graceful_case(Path(temp_dir))
    with tempfile.TemporaryDirectory(prefix="aerosim-gsp-slow-") as temp_dir:
        run_slow_overflow_case(Path(temp_dir))
    with tempfile.TemporaryDirectory(prefix="aerosim-gsp-packet-overload-") as temp_dir:
        run_packet_overload_no_overflow_case(Path(temp_dir))
    with tempfile.TemporaryDirectory(prefix="aerosim-gsp-isolation-") as temp_dir:
        run_peer_isolation_case(Path(temp_dir))
    with tempfile.TemporaryDirectory(prefix="aerosim-gsp-replacement-") as temp_dir:
        run_same_process_replacement_case(Path(temp_dir))
    with tempfile.TemporaryDirectory(prefix="aerosim-gsp-abrupt-") as temp_dir:
        run_abrupt_reclaim_case(Path(temp_dir))
    with tempfile.TemporaryDirectory(prefix="aerosim-gsp-restart-") as temp_dir:
        run_restart_token_case(Path(temp_dir))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
