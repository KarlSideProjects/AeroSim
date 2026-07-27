#!/usr/bin/env python3
"""Run the frozen four-process issue-251 GSP qualification."""

from __future__ import annotations

import json
import math
import os
import glob
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
RUN_SEQUENCE = "D-I-I-D"
WARMUP_SECONDS = 10
MEASURED_SECONDS = 60
PHYSICS_HZ = 240
SAMPLE_COUNT = MEASURED_SECONDS * PHYSICS_HZ
CONDITIONING_SECONDS = 300
CONDITIONING_SAMPLE_COUNT = CONDITIONING_SECONDS * PHYSICS_HZ
PROCESS_TIMEOUT_SECONDS = 330
MEASUREMENT_MIN_SECONDS = 59.5
MEASUREMENT_MAX_SECONDS = 60.5
CONDITIONING_MIN_SECONDS = 299.5
CONDITIONING_MAX_SECONDS = 300.5
MIN_TELEMETRY_FRAMES = 1800
MIN_TELEMETRY_SPAN_SECONDS = 59.5
MAX_TELEMETRY_GAP_SECONDS = 2.0


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
        self.telemetry_frame_times: list[float] = []

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
                    self.telemetry_frame_times.append(time.monotonic())
                elif message.get("t") == "hello":
                    self.hello_received = True
            elif opcode == 8:
                self.socket_eof = True

    def run_until_exit(self, process: subprocess.Popen[bytes], completion_path: Path, sample_callback=None) -> None:
        self.sock.setblocking(False)
        deadline = time.monotonic() + PROCESS_TIMEOUT_SECONDS
        while process.poll() is None:
            if time.monotonic() >= deadline:
                raise RuntimeError("authenticated-idle Godot process exceeded 240 seconds")
            if sample_callback is not None:
                sample_callback()
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

    def evidence(self) -> dict[str, object]:
        gaps = [
            later - earlier
            for earlier, later in zip(self.telemetry_frame_times, self.telemetry_frame_times[1:])
        ]
        return {
            "hello_received": self.hello_received,
            "telemetry_received": self.telemetry_received,
            "drained_frames": self.drained_frames,
            "poll_iterations": self.poll_iterations,
            "socket_eof": self.socket_eof,
            "open_throughout": not self.premature_eof,
            "telemetry_frame_times": self.telemetry_frame_times,
            "telemetry_span_seconds": (
                self.telemetry_frame_times[-1] - self.telemetry_frame_times[0]
                if len(self.telemetry_frame_times) >= 2 else 0.0
            ),
            "max_telemetry_gap_seconds": max(gaps, default=0.0),
        }


def percentile(values: list[float], fraction: float) -> float:
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, math.ceil(len(ordered) * fraction) - 1)]


def benchmark_command(output_path: Path, mode: str, commit_sha: str, warmup_seconds: int, seconds: int, ready_path: Path | None = None, benchmark_mode: str | None = None) -> list[str]:
    command = [
        GODOT,
        "--headless",
        "--remote-debug",
        "local://",
        "--path",
        str(ROOT),
        "--script",
        "res://tests/performance/physics_benchmark.gd",
        "--",
        "--benchmark-mode",
        benchmark_mode or ("reference" if mode != "disabled" or seconds == MEASURED_SECONDS else "smoke"),
        "--gsp-mode",
        mode,
        "--output",
        str(output_path),
        "--effects",
        "off",
        "--warmup-seconds",
        str(warmup_seconds),
        "--seconds",
        str(seconds),
        "--commit-sha",
        commit_sha,
    ]
    if ready_path is not None:
        command.extend(["--ready-file", str(ready_path), "--external-client"])
    return command


def run_one(output_dir: Path, label: str, mode: str, commit_sha: str, warmup_seconds: int = WARMUP_SECONDS, seconds: int = MEASURED_SECONDS, benchmark_mode: str = "reference") -> None:
    ready_path = output_dir / f"{label}.ready.json"
    output_path = output_dir / f"{label}.raw.json"
    client_path = output_dir / f"{label}.external.raw.json"
    environment_path = output_dir / f"{label}.environment.raw.json"
    log_path = output_dir / f"{label}.godot.log"
    command = benchmark_command(output_path, mode, commit_sha, warmup_seconds, seconds, ready_path if mode == "authenticated-idle" else None, benchmark_mode)
    process_started = time.monotonic()
    sources = environment_sources()
    environment_samples: list[dict[str, object]] = []
    next_environment_sample = process_started

    def capture_environment() -> None:
        nonlocal next_environment_sample
        now = time.monotonic()
        if now >= next_environment_sample:
            environment_samples.append(sample_environment(sources, process_started))
            next_environment_sample += 1.0

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
                    client.run_until_exit(process, output_path, capture_environment)
                    client_evidence.update(client.evidence())
            else:
                deadline = time.monotonic() + PROCESS_TIMEOUT_SECONDS
                while process.poll() is None:
                    if time.monotonic() >= deadline:
                        raise RuntimeError(f"disabled Godot process exceeded {PROCESS_TIMEOUT_SECONDS} seconds")
                    capture_environment()
                    time.sleep(0.05)
        finally:
            if process.poll() is None:
                process.kill()
            process.wait()
        client_evidence["process_duration_seconds"] = time.monotonic() - process_started
        environment_path.write_text(json.dumps({
            "commit_sha": commit_sha,
            "sample_hz": 1,
            "process_duration_seconds": client_evidence["process_duration_seconds"],
            "governor": {path: _read_text(path) for path in sources["governor_paths"]},
            "boost": _read_text(sources["boost_path"]) if sources["boost_path"] else None,
            "sources": sources,
            "samples": environment_samples,
        }, indent=2) + "\n", encoding="utf-8")
        if process.returncode != 0:
            raise RuntimeError(f"{label} Godot process failed; see {log_path}")
        client_path.write_text(json.dumps(client_evidence, indent=2) + "\n", encoding="utf-8")


def _read_text(path: str) -> str | None:
    try:
        return Path(path).read_text(encoding="utf-8").strip()
    except (OSError, UnicodeDecodeError):
        return None


def environment_sources() -> dict[str, object]:
    frequency_paths = sorted(glob.glob("/sys/devices/system/cpu/cpufreq/policy*/scaling_cur_freq"))
    governor_paths = sorted(glob.glob("/sys/devices/system/cpu/cpufreq/policy*/scaling_governor"))
    boost_path = "/sys/devices/system/cpu/cpufreq/boost"
    temperature_candidates: list[tuple[int, str, str]] = []
    for hwmon in sorted(glob.glob("/sys/class/hwmon/hwmon*")):
        name = (_read_text(f"{hwmon}/name") or "").lower()
        for input_path in sorted(glob.glob(f"{hwmon}/temp*_input")):
            stem = Path(input_path).stem
            label = (_read_text(f"{hwmon}/{stem.replace('_input', '_label')}") or "").lower()
            priority = 0 if "package" in label else 1 if label == "tctl" else 2
            if "package" in label or label == "tctl":
                temperature_candidates.append((priority, input_path, label))
            elif name == "k10temp" and stem == "temp1_input":
                temperature_candidates.append((3, input_path, label or name))
    temperature_candidates.sort()
    temperature_path = temperature_candidates[0][1] if temperature_candidates else None
    throttle_paths = sorted(glob.glob("/sys/devices/system/cpu/cpu[0-9]*/thermal_throttle/*_count"))
    return {
        "cpu_frequency_paths": frequency_paths,
        "governor_paths": governor_paths,
        "boost_path": boost_path if Path(boost_path).is_file() else None,
        "package_temperature_path": temperature_path,
        "package_temperature_label": temperature_candidates[0][2] if temperature_candidates else None,
        "thermal_throttle_paths": throttle_paths,
        "package_temperature_status": "available" if temperature_path else "unavailable",
        "thermal_throttle_status": "available" if throttle_paths else "unavailable",
    }


def sample_environment(sources: dict[str, object], started: float) -> dict[str, object]:
    frequencies = [
        int(value)
        for path in sources["cpu_frequency_paths"]
        if (value := _read_text(path)) is not None and value.isdigit()
    ]
    temperature_path = sources.get("package_temperature_path")
    temperature_raw = _read_text(temperature_path) if temperature_path else None
    throttles = {
        path: int(value)
        for path in sources["thermal_throttle_paths"]
        if (value := _read_text(path)) is not None and value.isdigit()
    }
    return {
        "elapsed_seconds": time.monotonic() - started,
        "cpu_frequency_khz": statistics.median(frequencies) if frequencies else None,
        "package_temperature_c": float(temperature_raw) / 1000.0 if temperature_raw and temperature_raw.lstrip("-").isdigit() else None,
        "thermal_throttle_counters": throttles if throttles else None,
    }


def run_conditioning(output_dir: Path, commit_sha: str) -> dict[str, object]:
    output_path = output_dir / "conditioning.raw.json"
    environment_path = output_dir / "conditioning.environment.raw.json"
    log_path = output_dir / "conditioning.godot.log"
    sources = environment_sources()
    command = benchmark_command(output_path, "disabled", commit_sha, 0, CONDITIONING_SECONDS)
    process_started = time.monotonic()
    samples: list[dict[str, object]] = []
    with log_path.open("wb") as log:
        process = subprocess.Popen(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT)
        next_sample = process_started
        try:
            while process.poll() is None:
                now = time.monotonic()
                if now >= next_sample:
                    samples.append(sample_environment(sources, process_started))
                    next_sample += 1.0
                time.sleep(min(0.05, max(0.0, next_sample - time.monotonic())))
            process.wait(timeout=5)
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()
    process_duration = time.monotonic() - process_started
    environment_path.write_text(json.dumps({
        "commit_sha": commit_sha,
        "sample_hz": 1,
        "process_duration_seconds": process_duration,
        "governor": {path: _read_text(path) for path in sources["governor_paths"]},
        "boost": _read_text(sources["boost_path"]) if sources["boost_path"] else None,
        "sources": sources,
        "samples": samples,
    }, indent=2) + "\n", encoding="utf-8")
    if process.returncode != 0:
        raise RuntimeError(f"conditioning Godot process failed; see {log_path}")
    raw = json.loads(output_path.read_text(encoding="utf-8"))
    if raw.get("sample_count") != CONDITIONING_SAMPLE_COUNT or len(raw.get("samples_ms", [])) != CONDITIONING_SAMPLE_COUNT:
        raise RuntimeError("conditioning did not produce exactly 72000 physics samples")
    timing = raw.get("monotonic_timing", {})
    measurement_elapsed = float(timing.get("measurement_elapsed_monotonic_seconds", -1.0))
    if not CONDITIONING_MIN_SECONDS <= measurement_elapsed <= CONDITIONING_MAX_SECONDS:
        raise RuntimeError(f"conditioning measurement duration was {measurement_elapsed:.3f}s")
    return validate_conditioning(environment_path, samples, commit_sha)


def validate_conditioning(environment_path: Path, samples: list[dict[str, object]], commit_sha: str) -> dict[str, object]:
    payload = json.loads(environment_path.read_text(encoding="utf-8"))
    if payload.get("commit_sha") != commit_sha:
        raise RuntimeError("conditioning environment provenance is invalid")
    sources = payload["sources"]
    elapsed = lambda lower, upper: [sample for sample in samples if lower <= float(sample["elapsed_seconds"]) < upper]
    first_window = elapsed(180.0, 240.0)
    second_window = elapsed(240.0, 300.1)
    temperatures_a = [sample["package_temperature_c"] for sample in first_window if sample["package_temperature_c"] is not None]
    temperatures_b = [sample["package_temperature_c"] for sample in second_window if sample["package_temperature_c"] is not None]
    frequencies_a = [sample["cpu_frequency_khz"] for sample in first_window if sample["cpu_frequency_khz"] is not None]
    frequencies_b = [sample["cpu_frequency_khz"] for sample in second_window if sample["cpu_frequency_khz"] is not None]
    temperature_delta = abs(statistics.median(temperatures_b) - statistics.median(temperatures_a)) if temperatures_a and temperatures_b else None
    frequency_delta_percent = (
        abs(statistics.median(frequencies_b) - statistics.median(frequencies_a)) / statistics.median(frequencies_a) * 100.0
        if frequencies_a and frequencies_b and statistics.median(frequencies_a) else None
    )
    throttle_values = [sample["thermal_throttle_counters"] for sample in samples]
    throttle_available = sources.get("thermal_throttle_status") == "available" and all(value is not None for value in throttle_values)
    throttle_increment = None
    if throttle_available:
        throttle_increment = sum(throttle_values[-1].get(path, 0) - throttle_values[0].get(path, 0) for path in sources["thermal_throttle_paths"])
    checks = {
        "package_temperature_source": sources.get("package_temperature_status") == "available" and bool(temperatures_a and temperatures_b),
        "package_temperature_delta_c": temperature_delta,
        "package_temperature_stable": temperature_delta is not None and temperature_delta <= 1.0,
        "cpu_frequency_source": bool(frequencies_a and frequencies_b),
        "cpu_frequency_delta_percent": frequency_delta_percent,
        "cpu_frequency_stable": frequency_delta_percent is not None and frequency_delta_percent <= 1.0,
        "thermal_throttle_source": throttle_available,
        "thermal_throttle_increment": throttle_increment,
        "thermal_throttle_stable": throttle_increment is not None and throttle_increment == 0,
    }
    payload["protocol"] = checks
    payload["admitted"] = all(value is True for key, value in checks.items() if key.endswith("_source") or key.endswith("_stable"))
    environment_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
    if not payload["admitted"]:
        raise RuntimeError(f"conditioning protocol evidence is insufficient: {checks}")
    return payload


def validate_raw(output_dir: Path, label: str, mode: str, commit_sha: str) -> dict[str, object]:
    payload = json.loads((output_dir / f"{label}.raw.json").read_text(encoding="utf-8"))
    samples = payload.get("samples_ms", [])
    if payload.get("sample_count") != SAMPLE_COUNT or len(samples) != SAMPLE_COUNT:
        raise RuntimeError(f"{label} did not produce exactly {SAMPLE_COUNT} physics samples")
    if payload.get("commit_sha") != commit_sha or payload.get("gsp_mode") != mode:
        raise RuntimeError(f"{label} provenance or mode is invalid")
    if payload.get("sampling_source") != "PhysicsFrameProfiler._tick" or payload.get("physics_ticks_per_second") != PHYSICS_HZ:
        raise RuntimeError(f"{label} lacks production PhysicsFrameProfiler provenance")
    timing = payload.get("monotonic_timing", {})
    measurement_elapsed = float(timing.get("measurement_elapsed_monotonic_seconds", -1.0))
    if not MEASUREMENT_MIN_SECONDS <= measurement_elapsed <= MEASUREMENT_MAX_SECONDS:
        raise RuntimeError(f"{label} measurement duration was {measurement_elapsed:.3f}s")
    warmup_elapsed = float(timing.get("warmup_elapsed_monotonic_seconds", -1.0))
    if not 9.5 <= warmup_elapsed <= 10.5:
        raise RuntimeError(f"{label} warmup duration was {warmup_elapsed:.3f}s")
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
        if not client.get("hello_received") or int(client.get("telemetry_received", 0)) < MIN_TELEMETRY_FRAMES:
            raise RuntimeError(f"{label} external client did not receive telemetry: {client}")
        if not client.get("open_throughout"):
            raise RuntimeError(f"{label} external client observed an early close: {client}")
        if float(client.get("telemetry_span_seconds", 0.0)) < MIN_TELEMETRY_SPAN_SECONDS:
            raise RuntimeError(f"{label} external telemetry did not span the measurement: {client}")
        if float(client.get("max_telemetry_gap_seconds", float("inf"))) > MAX_TELEMETRY_GAP_SECONDS:
            raise RuntimeError(f"{label} external telemetry had an excessive drain gap: {client}")
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
        "status": "pass" if abs(aggregate_percent) < 1.0 else "fail",
        "run_order": RUN_ORDER,
        "run_sequence": RUN_SEQUENCE,
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
            "gate": "abs(aggregate_percent) < 1.0; pair deltas are diagnostic",
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
                "environment": str(output_dir / f"{label}.environment.raw.json"),
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
    run_conditioning(output_dir, commit_sha)
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
