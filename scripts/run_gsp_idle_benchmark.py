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
CPPC_DRIFT_MAX_PERCENT = 1.0
TCTL_DRIFT_MAX_C = 1.0


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


def combine_protocol_results(*results: dict[str, object]) -> dict[str, object]:
    """Combine evidence without allowing missing data to mask a proven failure."""
    if any(result.get("status") == "FAIL" for result in results):
        failure_kind = next(
            (result.get("failure_kind") for result in results if result.get("status") == "FAIL" and result.get("failure_kind")),
            "protocol_failure",
        )
        return {"status": "FAIL", "failure_kind": failure_kind}
    if any(result.get("status") == "UNAVAILABLE" for result in results):
        return {"status": "UNAVAILABLE", "failure_kind": "missing_evidence"}
    return {"status": "PASS", "failure_kind": None}


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
    configuration_start = read_cpu_configuration()
    sources = environment_sources()
    initial_sample = sample_environment(sources, process_started)
    environment_samples: list[dict[str, object]] = [initial_sample]
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
        final_sample = sample_environment(sources, process_started)
        configuration_end = read_cpu_configuration()
        environment_path.write_text(json.dumps({
            "commit_sha": commit_sha,
            "sample_hz": 1,
            "process_duration_seconds": client_evidence["process_duration_seconds"],
            "governor": {path: _read_text(path) for path in sources["governor_paths"]},
            "boost": _read_text(sources["boost_path"]) if sources["boost_path"] else None,
            "configuration_start": configuration_start,
            "configuration_end": configuration_end,
            "boundary_snapshots": {"initial": initial_sample, "final": final_sample},
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


def parse_cppc_snapshot(feedback_raw: str | None, reference_raw: str | None) -> dict[str, object] | None:
    if feedback_raw is None or reference_raw is None or not reference_raw.strip().isdigit():
        return None
    counters: dict[str, int] = {}
    for field in feedback_raw.split():
        name, separator, value = field.partition(":")
        if not separator or name not in {"ref", "del"} or name in counters or not value.isdigit():
            return None
        counters[name] = int(value)
    if set(counters) != {"ref", "del"}:
        return None
    return {
        "raw": {"feedback_ctrs": feedback_raw, "reference_perf": reference_raw},
        "feedback_ctrs": counters,
        "reference_perf": int(reference_raw),
    }


def cppc_performance(before: dict[str, object] | None, after: dict[str, object] | None) -> float | None:
    if before is None or after is None or before.get("reference_perf") != after.get("reference_perf"):
        return None
    before_counters = before.get("feedback_ctrs", {})
    after_counters = after.get("feedback_ctrs", {})
    reference_delta = int(after_counters.get("ref", -1)) - int(before_counters.get("ref", -1))
    delivered_delta = int(after_counters.get("del", -1)) - int(before_counters.get("del", -1))
    if reference_delta <= 0 or delivered_delta < 0:
        return None
    return float(before["reference_perf"]) * delivered_delta / reference_delta


def parse_cpu_set(raw: str | None) -> set[int] | None:
    if raw is None or not raw.strip():
        return None
    result: set[int] = set()
    try:
        for item in raw.split(","):
            if "-" in item:
                start, end = (int(value) for value in item.split("-", 1))
                if start > end:
                    return None
                result.update(range(start, end + 1))
            else:
                result.add(int(item))
    except ValueError:
        return None
    return result


def compare_cpu_configuration(before: dict[str, object], after: dict[str, object]) -> dict[str, object]:
    if not before or not after or "online_cpus" not in before or "policies" not in before or "boost" not in before:
        return {"status": "UNAVAILABLE", "failure_kind": "missing_evidence", "exact": False}
    required = {"scaling_driver", "scaling_governor", "energy_performance_preference", "scaling_min_freq", "scaling_max_freq"}
    configurations = (before, after)
    if any(
        not _configuration_complete(config, required)
        for config in configurations
    ) or set(before["policies"]) != set(after["policies"]):
        return {"status": "UNAVAILABLE", "failure_kind": "missing_evidence", "exact": False}
    equal = before == after
    return {
        "status": "PASS" if equal else "FAIL",
        "failure_kind": None if equal else "configuration_drift",
        "exact": equal,
    }


def _configuration_complete(config: dict[str, object], required: set[str]) -> bool:
    online = parse_cpu_set(config.get("online_cpus"))
    policies = config.get("policies")
    cppc_cpu_set = config.get("cppc_cpu_set")
    return bool(
        isinstance(policies, dict)
        and policies
        and online is not None
        and config.get("online_cpu_set") == sorted(online)
        and isinstance(cppc_cpu_set, list)
        and set(cppc_cpu_set) == online
        and config.get("boost") is not None
        and all(set(policy) == required and all(value is not None for value in policy.values()) for policy in policies.values())
    )


def evaluate_cooling_sequence(samples: list[dict[str, object]], devices: list[dict[str, object]]) -> dict[str, object]:
    if not devices or not samples:
        return {"status": "UNAVAILABLE", "failure_kind": "missing_evidence"}
    device_ids = [device["stable_id"] for device in devices]
    parsed_samples = [sample.get("processor_cooling_samples") if "processor_cooling_samples" in sample else sample for sample in samples]
    if any(
        not isinstance(sample, dict)
        or set(sample) != set(device_ids)
        or any(
            not isinstance(sample[device_id], dict)
            or any(sample[device_id].get(key) is None for key in ("cur_state", "max_state", "total_trans", "time_in_state_ms"))
            or "0" not in sample[device_id].get("time_in_state_ms", {})
            for device_id in device_ids
        )
        for sample in parsed_samples
    ):
        return {"status": "UNAVAILABLE", "failure_kind": "missing_evidence"}
    max_state_values = {
        device_id: {sample[device_id]["max_state"] for sample in parsed_samples}
        for device_id in device_ids
    }
    if any(len(values) != 1 for values in max_state_values.values()):
        return {"status": "FAIL", "failure_kind": "cooling_reset", "max_state_values": max_state_values}
    if any(sample[device_id]["cur_state"] != 0 for sample in parsed_samples for device_id in device_ids):
        return {"status": "FAIL", "failure_kind": "cooling_state"}
    for previous, current in zip(parsed_samples, parsed_samples[1:]):
        for device_id in device_ids:
            if current[device_id]["total_trans"] < previous[device_id]["total_trans"]:
                return {"status": "UNAVAILABLE", "failure_kind": "counter_rollback"}
            if current[device_id]["time_in_state_ms"]["0"] <= previous[device_id]["time_in_state_ms"]["0"]:
                return {"status": "UNAVAILABLE", "failure_kind": "cooling_state0_reset"}
            for state in set(previous[device_id]["time_in_state_ms"]) | set(current[device_id]["time_in_state_ms"]):
                if current[device_id]["time_in_state_ms"].get(state, -1) < previous[device_id]["time_in_state_ms"].get(state, -1):
                    return {"status": "UNAVAILABLE", "failure_kind": "counter_rollback"}
    transition_increments = {
        device_id: parsed_samples[-1][device_id]["total_trans"] - parsed_samples[0][device_id]["total_trans"]
        for device_id in device_ids
    }
    if any(value < 0 for value in transition_increments.values()):
        return {"status": "UNAVAILABLE", "failure_kind": "counter_rollback", "transition_increments": transition_increments}
    time_deltas: dict[str, dict[str, int]] = {}
    for device_id in device_ids:
        first = parsed_samples[0][device_id]["time_in_state_ms"]
        last = parsed_samples[-1][device_id]["time_in_state_ms"]
        states = set(first) | set(last)
        if any(state not in first or state not in last for state in states):
            return {"status": "UNAVAILABLE", "failure_kind": "missing_evidence"}
        deltas = {state: last[state] - first[state] for state in states}
        if any(value < 0 for value in deltas.values()):
            return {"status": "UNAVAILABLE", "failure_kind": "counter_rollback", "time_deltas": {device_id: deltas}}
        time_deltas[device_id] = deltas
    if any(value > 0 for value in transition_increments.values()) or any(
        delta > 0 for deltas in time_deltas.values() for state, delta in deltas.items() if state != "0"
    ):
        return {
            "status": "FAIL",
            "failure_kind": "thermal_throttle",
            "transition_increments": transition_increments,
            "time_deltas": time_deltas,
        }
    return {
        "status": "PASS",
        "failure_kind": None,
        "transition_increments": transition_increments,
        "time_deltas": time_deltas,
        "max_state": {device_id: next(iter(values)) for device_id, values in max_state_values.items()},
    }


def evaluate_environment_protocol(
    conditioning: dict[str, object],
    run_payloads: dict[str, dict[str, object]],
    pre_configuration: dict[str, object],
    post_configuration: dict[str, object],
) -> dict[str, object]:
    configuration = compare_cpu_configuration(pre_configuration, post_configuration)
    if conditioning.get("status") != "PASS" or conditioning.get("admitted") is False:
        return combine_protocol_results(
            configuration,
            {
                "status": conditioning.get("status", "UNAVAILABLE"),
                "failure_kind": conditioning.get("failure_kind", "missing_evidence"),
            },
        )
    sources = conditioning.get("sources", {})
    expected_phases = ["conditioning", *RUN_LABELS]
    boundary_payloads = {"conditioning": conditioning, **run_payloads}
    if any(
        not isinstance(boundary_payloads.get(phase, {}).get("boundary_snapshots"), dict)
        or set(boundary_payloads[phase]["boundary_snapshots"]) != {"initial", "final"}
        for phase in expected_phases
    ):
        return combine_protocol_results(configuration, {"status": "UNAVAILABLE", "failure_kind": "missing_evidence"})
    all_samples = ordered_cooling_samples(conditioning, run_payloads)
    cooling = evaluate_cooling_sequence(all_samples, sources.get("processor_cooling_devices", []))
    d_drift = evaluate_d_a_d_b_drift(run_payloads)
    combined = combine_protocol_results(configuration, cooling, d_drift)
    return {
        "status": combined["status"],
        "failure_kind": combined["failure_kind"],
        "configuration": configuration,
        "cooling": cooling,
        "boundary_snapshots": {
            "conditioning": conditioning.get("boundary_snapshots", {}),
            **{label: payload.get("boundary_snapshots", {}) for label, payload in run_payloads.items()},
        },
        "D_a_D_b": d_drift,
        "aggregate_formula": "sum(reference_perf_cpu*delta_del_cpu)/sum(delta_ref_cpu)",
    }


def _read_processor_cooling_device(device_path: str) -> dict[str, object]:
    paths = {
        "cur_state": f"{device_path}/cur_state",
        "max_state": f"{device_path}/max_state",
        "total_trans": f"{device_path}/stats/total_trans",
        "time_in_state_ms": f"{device_path}/stats/time_in_state_ms",
    }
    raw = {name: _read_text(path) for name, path in paths.items()}
    parsed: dict[str, object] = {"path": device_path, "type": _read_text(f"{device_path}/type")}
    parsed["cur_state"] = int(raw["cur_state"]) if raw["cur_state"] is not None and raw["cur_state"].lstrip("-").isdigit() else None
    parsed["max_state"] = int(raw["max_state"]) if raw["max_state"] is not None and raw["max_state"].lstrip("-").isdigit() else None
    parsed["total_trans"] = int(raw["total_trans"]) if raw["total_trans"] is not None and raw["total_trans"].lstrip("-").isdigit() else None
    time_in_state: dict[str, int] = {}
    if raw["time_in_state_ms"] is not None:
        for line in raw["time_in_state_ms"].splitlines():
            fields = line.split()
            if len(fields) != 2 or not fields[0].startswith("state") or not fields[0][5:].isdigit() or not fields[1].isdigit():
                time_in_state = {}
                break
            time_in_state[fields[0][5:]] = int(fields[1])
        if parsed["max_state"] is not None and set(time_in_state) != {str(state) for state in range(parsed["max_state"] + 1)}:
            time_in_state = {}
    parsed["time_in_state_ms"] = time_in_state or None
    parsed["raw"] = raw
    return parsed


def _read_cppc_device(device: dict[str, str]) -> dict[str, object] | None:
    snapshot = parse_cppc_snapshot(_read_text(device["feedback_path"]), _read_text(device["reference_path"]))
    if snapshot is None:
        return None
    return {"stable_id": device["stable_id"], "path": device["path"], **snapshot}


def read_cpu_configuration() -> dict[str, object]:
    policies: dict[str, dict[str, str | None]] = {}
    for policy_path in sorted(glob.glob("/sys/devices/system/cpu/cpufreq/policy*")):
        resolved = Path(policy_path).resolve()
        stable_id = resolved.name
        policies[stable_id] = {
            "scaling_driver": _read_text(str(resolved / "scaling_driver")),
            "scaling_governor": _read_text(str(resolved / "scaling_governor")),
            "energy_performance_preference": _read_text(str(resolved / "energy_performance_preference")),
            "scaling_min_freq": _read_text(str(resolved / "scaling_min_freq")),
            "scaling_max_freq": _read_text(str(resolved / "scaling_max_freq")),
        }
    online_cpus = _read_text("/sys/devices/system/cpu/online")
    cppc_cpu_set = sorted(
        int(Path(path).resolve().parent.name[3:])
        for path in glob.glob("/sys/devices/system/cpu/cpu[0-9]*/acpi_cppc")
        if Path(path).resolve().parent.name[3:].isdigit()
    )
    return {
        "online_cpus": online_cpus,
        "online_cpu_set": sorted(parse_cpu_set(online_cpus)) if parse_cpu_set(online_cpus) is not None else None,
        "cppc_cpu_set": cppc_cpu_set,
        "boost": _read_text("/sys/devices/system/cpu/cpufreq/boost"),
        "policies": policies,
    }


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
    processor_cooling_devices = []
    for device_path in sorted(glob.glob("/sys/class/thermal/cooling_device*")):
        if _read_text(f"{device_path}/type") == "Processor":
            resolved = Path(device_path).resolve()
            device = _read_processor_cooling_device(str(resolved))
            device["stable_id"] = str(resolved)
            device["display_name"] = resolved.name
            device["path"] = str(resolved)
            processor_cooling_devices.append(device)
    processor_cooling_available = bool(processor_cooling_devices) and all(
        device["cur_state"] is not None
        and device["max_state"] is not None
        and device["total_trans"] is not None
        and device["time_in_state_ms"] is not None
        for device in processor_cooling_devices
    )
    cppc_devices = []
    for cppc_path in sorted(glob.glob("/sys/devices/system/cpu/cpu[0-9]*/acpi_cppc")):
        resolved = Path(cppc_path).resolve()
        cpu_id = resolved.parent.name
        cppc_devices.append({
            "stable_id": cpu_id,
            "path": str(resolved),
            "feedback_path": str(resolved / "feedback_ctrs"),
            "reference_path": str(resolved / "reference_perf"),
        })
    online_cpu_set = parse_cpu_set(_read_text("/sys/devices/system/cpu/online"))
    cppc_cpu_set = {int(device["stable_id"][3:]) for device in cppc_devices if device["stable_id"][3:].isdigit()}
    cppc_available = bool(cppc_devices) and online_cpu_set is not None and cppc_cpu_set == online_cpu_set and all(_read_cppc_device(device) is not None for device in cppc_devices)
    return {
        "cpu_frequency_paths": frequency_paths,
        "governor_paths": governor_paths,
        "boost_path": boost_path if Path(boost_path).is_file() else None,
        "package_temperature_path": temperature_path,
        "package_temperature_label": temperature_candidates[0][2] if temperature_candidates else None,
        "thermal_throttle_paths": throttle_paths,
        "package_temperature_status": "available" if temperature_path else "unavailable",
        "thermal_throttle_status": "available" if throttle_paths else "unavailable",
        "processor_cooling_devices": processor_cooling_devices,
        "processor_cooling_protocol": "available" if processor_cooling_available else "unavailable",
        "cppc_devices": cppc_devices,
        "cppc_cpu_set": sorted(cppc_cpu_set),
        "cppc_protocol": "available" if cppc_available else "unavailable",
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
    processor_cooling_samples = {
        device["stable_id"]: _read_processor_cooling_device(device["path"])
        for device in sources["processor_cooling_devices"]
    }
    for device in sources["processor_cooling_devices"]:
        processor_cooling_samples[device["stable_id"]]["stable_id"] = device["stable_id"]
    cppc_samples = {
        device["stable_id"]: _read_cppc_device(device)
        for device in sources["cppc_devices"]
    }
    return {
        "elapsed_seconds": time.monotonic() - started,
        "cpu_frequency_khz": statistics.median(frequencies) if frequencies else None,
        "package_temperature_c": float(temperature_raw) / 1000.0 if temperature_raw and temperature_raw.lstrip("-").isdigit() else None,
        "thermal_throttle_counters": throttles if throttles else None,
        "processor_cooling_samples": processor_cooling_samples if processor_cooling_samples else None,
        "cppc_samples": cppc_samples if cppc_samples else None,
    }


def cppc_window_performance(samples: list[dict[str, object]], lower: float, upper: float) -> float | None:
    window = [sample for sample in samples if lower <= float(sample.get("elapsed_seconds", -1.0)) <= upper]
    if len(window) < 2:
        return None
    first = window[0].get("cppc_samples") or {}
    last = window[-1].get("cppc_samples") or {}
    if set(first) != set(last) or not first:
        return None
    numerator = 0.0
    denominator = 0
    for cpu_id in first:
        before = first[cpu_id]
        after = last[cpu_id]
        if before is None or after is None or before.get("reference_perf") != after.get("reference_perf"):
            return None
        before_counters = before.get("feedback_ctrs", {})
        after_counters = after.get("feedback_ctrs", {})
        reference_delta = int(after_counters.get("ref", -1)) - int(before_counters.get("ref", -1))
        delivered_delta = int(after_counters.get("del", -1)) - int(before_counters.get("del", -1))
        if reference_delta <= 0 or delivered_delta < 0:
            return None
        numerator += float(before["reference_perf"]) * delivered_delta
        denominator += reference_delta
    return numerator / denominator if denominator else None


def ordered_cooling_samples(conditioning: dict[str, object], run_payloads: dict[str, dict[str, object]]) -> list[dict[str, object]]:
    ordered: list[dict[str, object]] = []
    phases = [("conditioning", conditioning), *[(label, run_payloads[label]) for label in RUN_LABELS]]
    for _label, payload in phases:
        boundaries = payload.get("boundary_snapshots", {})
        ordered.append(boundaries["initial"])
        ordered.extend(payload.get("samples", []))
        ordered.append(boundaries["final"])
    return ordered


def evaluate_d_a_d_b_drift(run_payloads: dict[str, dict[str, object]]) -> dict[str, object]:
    d_a = run_payloads.get("D_a", {}).get("samples", [])
    d_b = run_payloads.get("D_b", {}).get("samples", [])
    cppc_a = cppc_window_performance(d_a, 0.0, float("inf"))
    cppc_b = cppc_window_performance(d_b, 0.0, float("inf"))
    tctl_a = [sample["package_temperature_c"] for sample in d_a if sample.get("package_temperature_c") is not None]
    tctl_b = [sample["package_temperature_c"] for sample in d_b if sample.get("package_temperature_c") is not None]
    tctl_a_median = statistics.median(tctl_a) if tctl_a else None
    tctl_b_median = statistics.median(tctl_b) if tctl_b else None
    cppc_delta = abs(cppc_b - cppc_a) / cppc_a * 100.0 if cppc_a and cppc_b else None
    tctl_delta = abs(tctl_b_median - tctl_a_median) if tctl_a_median is not None and tctl_b_median is not None else None
    combined = combine_protocol_results(
        {
            "status": "UNAVAILABLE" if cppc_delta is None else "FAIL" if cppc_delta > CPPC_DRIFT_MAX_PERCENT else "PASS",
            "failure_kind": "missing_evidence" if cppc_delta is None else "run_environment_drift",
        },
        {
            "status": "UNAVAILABLE" if tctl_delta is None else "FAIL" if tctl_delta > TCTL_DRIFT_MAX_C else "PASS",
            "failure_kind": "missing_evidence" if tctl_delta is None else "run_environment_drift",
        },
    )
    status = combined["status"]
    return {
        "status": status,
        "failure_kind": combined["failure_kind"],
        "cppc_P_D_a": cppc_a,
        "cppc_P_D_b": cppc_b,
        "cppc_drift_percent": cppc_delta,
        "tctl_median_D_a_c": tctl_a_median,
        "tctl_median_D_b_c": tctl_b_median,
        "tctl_drift_c": tctl_delta,
        "cppc_threshold_percent": CPPC_DRIFT_MAX_PERCENT,
        "tctl_threshold_c": TCTL_DRIFT_MAX_C,
    }


def write_qualification_failure(
    output_dir: Path, commit_sha: str, environment_status: str, failure_kind: str
) -> Path:
    path = output_dir / "qualification.failure.json"
    path.write_text(json.dumps({
        "status": "fail",
        "environment_status": environment_status,
        "failure_kind": "environment_evidence_unavailable" if environment_status == "UNAVAILABLE" else failure_kind,
        "commit_sha": commit_sha,
    }, indent=2) + "\n", encoding="utf-8")
    return path


def record_environment_evidence_failure(output_dir: Path, commit_sha: str) -> Path:
    return write_qualification_failure(output_dir, commit_sha, "UNAVAILABLE", "environment_evidence_unavailable")


def run_conditioning(output_dir: Path, commit_sha: str, configuration_start: dict[str, object] | None = None) -> dict[str, object]:
    output_path = output_dir / "conditioning.raw.json"
    environment_path = output_dir / "conditioning.environment.raw.json"
    log_path = output_dir / "conditioning.godot.log"
    sources = environment_sources()
    configuration_start = configuration_start or read_cpu_configuration()
    command = benchmark_command(output_path, "disabled", commit_sha, 0, CONDITIONING_SECONDS)
    process_started = time.monotonic()
    initial_sample = sample_environment(sources, process_started)
    samples: list[dict[str, object]] = [initial_sample]
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
    final_sample = sample_environment(sources, process_started)
    configuration_end = read_cpu_configuration()
    environment_path.write_text(json.dumps({
        "commit_sha": commit_sha,
        "sample_hz": 1,
        "process_duration_seconds": process_duration,
        "governor": {path: _read_text(path) for path in sources["governor_paths"]},
        "boost": _read_text(sources["boost_path"]) if sources["boost_path"] else None,
        "configuration_start": configuration_start,
        "configuration_end": configuration_end,
        "boundary_snapshots": {"initial": initial_sample, "final": final_sample},
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
    first_window = [sample for sample in samples if 180.0 <= sample["elapsed_seconds"] < 240.0]
    second_window = [sample for sample in samples if 240.0 <= sample["elapsed_seconds"] <= 300.1]
    temperatures_a = [sample["package_temperature_c"] for sample in first_window if sample["package_temperature_c"] is not None]
    temperatures_b = [sample["package_temperature_c"] for sample in second_window if sample["package_temperature_c"] is not None]
    frequencies_a = [sample["cpu_frequency_khz"] for sample in first_window if sample["cpu_frequency_khz"] is not None]
    frequencies_b = [sample["cpu_frequency_khz"] for sample in second_window if sample["cpu_frequency_khz"] is not None]
    temperature_delta = abs(statistics.median(temperatures_b) - statistics.median(temperatures_a)) if temperatures_a and temperatures_b else None
    frequency_delta_percent = (
        abs(statistics.median(frequencies_b) - statistics.median(frequencies_a)) / statistics.median(frequencies_a) * 100.0
        if frequencies_a and frequencies_b and statistics.median(frequencies_a) else None
    )
    cooling = evaluate_cooling_sequence(samples, sources["processor_cooling_devices"])
    cppc_w1 = cppc_window_performance(samples, 180.0, 240.0)
    cppc_w2 = cppc_window_performance(samples, 240.0, 300.1)
    cppc_delta_percent = abs(cppc_w2 - cppc_w1) / cppc_w1 * 100.0 if cppc_w1 and cppc_w2 else None
    configuration = compare_cpu_configuration(payload.get("configuration_start", {}), payload.get("configuration_end", {}))
    temperature_status = (
        {"status": "UNAVAILABLE", "failure_kind": "missing_evidence"}
        if not temperatures_a or not temperatures_b or temperature_delta is None
        else {"status": "FAIL", "failure_kind": "conditioning_drift"}
        if temperature_delta > 1.0
        else {"status": "PASS", "failure_kind": None}
    )
    cppc_status = (
        {"status": "UNAVAILABLE", "failure_kind": "missing_evidence"}
        if sources.get("cppc_protocol") != "available" or cppc_delta_percent is None
        else {"status": "FAIL", "failure_kind": "conditioning_drift"}
        if cppc_delta_percent > 1.0
        else {"status": "PASS", "failure_kind": None}
    )
    cooling_status = combine_protocol_results(
        {"status": "UNAVAILABLE", "failure_kind": "missing_evidence"}
        if sources.get("processor_cooling_protocol") != "available"
        else cooling,
    )
    combined = combine_protocol_results(cooling_status, configuration, cppc_status, temperature_status)
    status = combined["status"]
    failure_kind = combined["failure_kind"]
    checks = {
        "status": status,
        "failure_kind": failure_kind,
        "package_temperature_delta_c": temperature_delta,
        "package_temperature_stable": temperature_delta is not None and temperature_delta <= 1.0,
        "frequency_diagnostic_delta_percent": frequency_delta_percent,
        "cppc_w1": cppc_w1,
        "cppc_w2": cppc_w2,
        "cppc_window_delta_percent": cppc_delta_percent,
        "cppc_window_stable": cppc_delta_percent is not None and cppc_delta_percent <= 1.0,
        "cooling": cooling,
        "configuration": configuration,
        "aggregate_formula": "sum(reference_perf_cpu*delta_del_cpu)/sum(delta_ref_cpu)",
    }
    payload["protocol"] = checks
    payload["status"] = status
    payload["failure_kind"] = failure_kind
    payload["admitted"] = status == "PASS"
    environment_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
    if not payload["admitted"]:
        write_qualification_failure(environment_path.parent, commit_sha, status, failure_kind or "conditioning_drift")
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


def read_gpu_metadata(sys_root: Path = Path("/sys")) -> dict[str, object]:
    devices: list[dict[str, object]] = []
    for card_device in sorted((sys_root / "class" / "drm").glob("card[0-9]*/device")):
        resolved = card_device.resolve()
        device = {
            "card_name": card_device.parent.name,
            "path": str(resolved),
            "vendor": _read_text(str(resolved / "vendor")),
            "device": _read_text(str(resolved / "device")),
            "subsystem_vendor": _read_text(str(resolved / "subsystem_vendor")),
            "subsystem_device": _read_text(str(resolved / "subsystem_device")),
            "driver": resolved.joinpath("driver").resolve().name if resolved.joinpath("driver").exists() else None,
        }
        devices.append(device)
    return {"status": "available", "devices": devices} if devices else {"status": "unavailable", "devices": []}


def compare_payloads(
    payloads: dict[str, dict[str, object]],
    output_dir: Path,
    commit_sha: str,
    gpu_metadata: dict[str, object] | None = None,
) -> dict[str, object]:
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
    gpu_metadata = gpu_metadata or read_gpu_metadata()
    return {
        "status": "pass" if abs(aggregate_percent) < 1.0 else "fail",
        "run_order": RUN_ORDER,
        "run_sequence": RUN_SEQUENCE,
        "run_labels": RUN_LABELS,
        "warmup_seconds": WARMUP_SECONDS,
        "measured_seconds": MEASURED_SECONDS,
        "sample_count_per_run": SAMPLE_COUNT,
        "metric": "production PhysicsFrameProfiler physics_time_ms",
        "environment_metric_formula": "sum(reference_perf_cpu*delta_del_cpu)/sum(delta_ref_cpu)",
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
        "provenance": {
            "commit_sha": commit_sha,
            "gpu_metadata": gpu_metadata,
            "gpu_recorded_by_process": gpu_metadata.get("status") == "available",
            "gpu_is_gate": False,
        },
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
    pre_configuration = read_cpu_configuration()
    try:
        conditioning = run_conditioning(output_dir, commit_sha, pre_configuration)
    except (KeyError, TypeError, ValueError, json.JSONDecodeError):
        record_environment_evidence_failure(output_dir, commit_sha)
        raise
    for label, mode in zip(RUN_LABELS, RUN_ORDER):
        run_one(output_dir, label, mode, commit_sha)
    payloads = {label: validate_raw(output_dir, label, mode, commit_sha) for label, mode in zip(RUN_LABELS, RUN_ORDER)}
    comparison = compare_payloads(payloads, output_dir, commit_sha)
    post_configuration = read_cpu_configuration()
    try:
        environment_payloads = {
            label: json.loads((output_dir / f"{label}.environment.raw.json").read_text(encoding="utf-8"))
            for label in RUN_LABELS
        }
        environment_protocol = evaluate_environment_protocol(conditioning, environment_payloads, pre_configuration, post_configuration)
    except (KeyError, TypeError, ValueError, json.JSONDecodeError):
        record_environment_evidence_failure(output_dir, commit_sha)
        raise
    comparison["environment_protocol"] = environment_protocol
    comparison["status"] = "pass" if comparison["status"] == "pass" and environment_protocol["status"] == "PASS" else "fail"
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
