#!/usr/bin/env python3
"""Run the frozen four-process issue-251 GSP qualification."""

from __future__ import annotations

import json
import math
import os
import select
import socket
import statistics
import subprocess
import sys
import time
from pathlib import Path

from test_gsp_transport import GODOT, receive_frame, read_ready, send_text, websocket_connect


ROOT = Path(__file__).resolve().parents[1]
RUN_ORDER = ["disabled", "authenticated-idle", "authenticated-idle", "disabled"]
RUN_LABELS = ["D_a", "I_a", "I_b", "D_b"]
WARMUP_SECONDS = 10
MEASURED_SECONDS = 60
PHYSICS_HZ = 240
SAMPLE_COUNT = MEASURED_SECONDS * PHYSICS_HZ
PROCESS_TIMEOUT_SECONDS = 240


class ExternalIdleClient:
    """Authenticated 30 Hz client that continuously drains the server socket."""

    def __init__(self, sock: socket.socket) -> None:
        self.sock = sock
        self.buffer = bytearray()
        self.telemetry_received = 0
        self.hello_received = False
        self.drained_frames = 0
        self.poll_iterations = 0
        self.socket_eof = False
        self.premature_eof = False

    def _frames(self) -> list[tuple[int, bytes]]:
        frames: list[tuple[int, bytes]] = []
        while len(self.buffer) >= 2:
            first, second = self.buffer[0], self.buffer[1]
            length = second & 0x7F
            header_size = 2
            if length == 126:
                header_size = 4
                if len(self.buffer) < header_size:
                    break
                length = int.from_bytes(self.buffer[2:4], "big")
            elif length == 127:
                header_size = 10
                if len(self.buffer) < header_size:
                    break
                length = int.from_bytes(self.buffer[2:10], "big")
            mask_size = 4 if second & 0x80 else 0
            frame_size = header_size + mask_size + length
            if len(self.buffer) < frame_size:
                break
            payload_start = header_size
            mask = self.buffer[payload_start:payload_start + mask_size]
            payload_start += mask_size
            payload = bytes(self.buffer[payload_start:payload_start + length])
            del self.buffer[:frame_size]
            if mask:
                payload = bytes(byte ^ mask[index % 4] for index, byte in enumerate(payload))
            frames.append((first & 0x0F, payload))
        return frames

    def drain(self) -> None:
        while True:
            try:
                chunk = self.sock.recv(65536)
            except BlockingIOError:
                break
            if not chunk:
                self.socket_eof = True
                break
            self.buffer.extend(chunk)
        for opcode, payload in self._frames():
            self.drained_frames += 1
            if opcode == 1:
                try:
                    message = json.loads(payload.decode("utf-8"))
                except (UnicodeDecodeError, json.JSONDecodeError):
                    continue
                if message.get("t") == "telemetry":
                    self.telemetry_received += 1
                elif message.get("t") == "hello":
                    self.hello_received = True
            elif opcode == 8:
                self.socket_eof = True

    def run_until_exit(self, process: subprocess.Popen[bytes], completion_path: Path) -> None:
        self.sock.setblocking(False)
        deadline = time.monotonic() + PROCESS_TIMEOUT_SECONDS
        while process.poll() is None:
            if time.monotonic() >= deadline:
                raise RuntimeError("authenticated-idle Godot process exceeded 240 seconds")
            self.poll_iterations += 1
            self.drain()
            if self.socket_eof:
                if completion_path.exists():
                    time.sleep(0.01)
                    continue
                self.premature_eof = True
                raise RuntimeError("authenticated-idle client socket closed before the Godot run completed")
            select.select([self.sock], [], [], 0.01)
        self.drain()


def percentile(values: list[float], fraction: float) -> float:
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, math.ceil(len(ordered) * fraction) - 1)]


def run_one(output_dir: Path, label: str, mode: str, commit_sha: str) -> None:
    ready_path = output_dir / f"{label}.ready.json"
    output_path = output_dir / f"{label}.raw.json"
    client_path = output_dir / f"{label}.external.raw.json"
    log_path = output_dir / f"{label}.godot.log"
    command = [
        GODOT,
        "--headless",
        "--fixed-fps",
        str(PHYSICS_HZ),
        "--remote-debug",
        "local://",
        "--path",
        str(ROOT),
        "--script",
        "res://tests/performance/physics_benchmark.gd",
        "--",
        "--benchmark-mode",
        "reference",
        "--gsp-mode",
        mode,
        "--output",
        str(output_path),
        "--effects",
        "off",
        "--warmup-seconds",
        str(WARMUP_SECONDS),
        "--seconds",
        str(MEASURED_SECONDS),
        "--commit-sha",
        commit_sha,
    ]
    if mode == "authenticated-idle":
        command.extend(["--ready-file", str(ready_path), "--external-client"])
    with log_path.open("wb") as log:
        process = subprocess.Popen(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT)
        client_evidence: dict[str, object] = {
            "mode": mode,
            "external_client": mode == "authenticated-idle",
            "open_throughout": False,
        }
        try:
            if mode == "authenticated-idle":
                identity = read_ready(ready_path, process)
                with websocket_connect("127.0.0.1", int(identity["port"])) as sock:
                    send_text(sock, json.dumps({"v": 2, "t": "auth", "seq": 0, "d": {"token": identity["token"]}}))
                    opcode, payload = receive_frame(sock)
                    hello = json.loads(payload.decode("utf-8"))
                    if opcode != 1 or hello.get("t") != "hello":
                        raise RuntimeError(f"invalid authenticated-idle hello: {hello!r}")
                    client = ExternalIdleClient(sock)
                    client.hello_received = True
                    send_text(sock, json.dumps({"v": 2, "t": "set_telemetry", "seq": 1, "d": {"hz": 30, "extra": []}}))
                    client.run_until_exit(process, output_path)
                    client_evidence.update({
                        "hello_received": client.hello_received,
                        "telemetry_received": client.telemetry_received,
                        "drained_frames": client.drained_frames,
                        "poll_iterations": client.poll_iterations,
                        "socket_eof": client.socket_eof,
                        "open_throughout": not client.premature_eof,
                    })
            else:
                try:
                    process.wait(timeout=PROCESS_TIMEOUT_SECONDS)
                except subprocess.TimeoutExpired as error:
                    raise RuntimeError(f"disabled Godot process exceeded {PROCESS_TIMEOUT_SECONDS} seconds") from error
        finally:
            if process.poll() is None:
                process.kill()
            process.wait()
        if process.returncode != 0:
            raise RuntimeError(f"{label} Godot process failed; see {log_path}")
        client_path.write_text(json.dumps(client_evidence, indent=2) + "\n", encoding="utf-8")


def validate_raw(output_dir: Path, label: str, mode: str, commit_sha: str) -> dict[str, object]:
    payload = json.loads((output_dir / f"{label}.raw.json").read_text(encoding="utf-8"))
    samples = payload.get("samples_ms", [])
    if payload.get("sample_count") != SAMPLE_COUNT or len(samples) != SAMPLE_COUNT:
        raise RuntimeError(f"{label} did not produce exactly {SAMPLE_COUNT} physics samples")
    if payload.get("commit_sha") != commit_sha or payload.get("gsp_mode") != mode:
        raise RuntimeError(f"{label} provenance or mode is invalid")
    if payload.get("sampling_source") != "PhysicsFrameProfiler._tick" or payload.get("physics_ticks_per_second") != PHYSICS_HZ:
        raise RuntimeError(f"{label} lacks production PhysicsFrameProfiler provenance")
    if not all(isinstance(item, (int, float)) and math.isfinite(item) and item > 0 for item in samples):
        raise RuntimeError(f"{label} contains invalid physics samples")
    evidence = payload.get("gsp_server_evidence", {})
    if mode == "authenticated-idle":
        expected_phase_samples = (WARMUP_SECONDS + MEASURED_SECONDS) * PHYSICS_HZ
        if evidence.get("sample_count") != expected_phase_samples or evidence.get("not_open_samples") != 0:
            raise RuntimeError(f"{label} authenticated server was not OPEN throughout: {evidence}")
        if evidence.get("suppression_observed") or evidence.get("reliable_overflow_count") or evidence.get("hard_close_count"):
            raise RuntimeError(f"{label} observed GSP pressure/failure: {evidence}")
        if int(evidence.get("telemetry_send_count", 0)) <= 0:
            raise RuntimeError(f"{label} produced no server telemetry: {evidence}")
        client = json.loads((output_dir / f"{label}.external.raw.json").read_text(encoding="utf-8"))
        if not client.get("hello_received") or int(client.get("telemetry_received", 0)) <= 0:
            raise RuntimeError(f"{label} external client did not receive telemetry: {client}")
        if not client.get("open_throughout"):
            raise RuntimeError(f"{label} external client observed an early close: {client}")
    return payload


def compare_payloads(payloads: dict[str, dict[str, object]], output_dir: Path, commit_sha: str) -> dict[str, object]:
    means = {label: statistics.fmean(payload["samples_ms"]) for label, payload in payloads.items()}
    pair_a_percent = (means["I_a"] - means["D_a"]) / means["D_a"] * 100.0
    pair_b_percent = (means["I_b"] - means["D_b"]) / means["D_b"] * 100.0
    aggregate_percent = (pair_a_percent + pair_b_percent) / 2.0
    diagnostics = {
        label: {
            "run_mean_physics_time_ms": means[label],
            "p50_ms": percentile(payload["samples_ms"], 0.50),
            "p95_ms": percentile(payload["samples_ms"], 0.95),
            "p99_ms": percentile(payload["samples_ms"], 0.99),
        }
        for label, payload in payloads.items()
    }
    return {
        "status": "pass" if all(abs(value) < 1.0 for value in (pair_a_percent, pair_b_percent, aggregate_percent)) else "fail",
        "run_order": RUN_ORDER,
        "run_labels": RUN_LABELS,
        "warmup_seconds": WARMUP_SECONDS,
        "measured_seconds": MEASURED_SECONDS,
        "sample_count_per_run": SAMPLE_COUNT,
        "metric": "production PhysicsFrameProfiler physics_time_ms",
        "primary": {
            "pair_deltas_percent": {
                "(I_a-D_a)/D_a": pair_a_percent,
                "(I_b-D_b)/D_b": pair_b_percent,
            },
            "aggregate_pair_delta_percent": aggregate_percent,
            "threshold_percent": 1.0,
            "formula": "pair_a=(mean(I_a)-mean(D_a))/mean(D_a); pair_b=(mean(I_b)-mean(D_b))/mean(D_b); aggregate=(pair_a+pair_b)/2",
            "experimental_unit": "one fresh Godot process per run; no frame-index pairing",
        },
        "percentiles_are_diagnostic_only": True,
        "diagnostics": diagnostics,
        "provenance": {"commit_sha": commit_sha, "gpu_recorded_by_process": True, "gpu_is_gate": False},
        "raw_artifacts": {
            label: {
                "physics": str(output_dir / f"{label}.raw.json"),
                "external_client": str(output_dir / f"{label}.external.raw.json"),
                "godot_log": str(output_dir / f"{label}.godot.log"),
            }
            for label in RUN_LABELS
        },
    }


def main() -> int:
    output_dir = Path(os.environ.get("AEROSIM_GSP_IDLE_OUTPUT_DIR", "build/gsp-idle-benchmark"))
    output_dir.mkdir(parents=True, exist_ok=True)
    commit_sha = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
    if len(commit_sha) != 40:
        raise RuntimeError("commit provenance is required")
    for label, mode in zip(RUN_LABELS, RUN_ORDER):
        run_one(output_dir, label, mode, commit_sha)
    payloads = {label: validate_raw(output_dir, label, mode, commit_sha) for label, mode in zip(RUN_LABELS, RUN_ORDER)}
    comparison = compare_payloads(payloads, output_dir, commit_sha)
    comparison_path = output_dir / "comparison.json"
    comparison_path.write_text(json.dumps(comparison, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(comparison, sort_keys=True))
    return 0 if comparison["status"] == "pass" else 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError, ValueError, json.JSONDecodeError) as error:
        print(f"GSP idle qualification: FAIL {error}", file=sys.stderr)
        raise SystemExit(1) from error
