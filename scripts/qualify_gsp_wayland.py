#!/usr/bin/env python3
"""Collect and evaluate explicit GSP Wayland qualification evidence."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import platform
import re
import shutil
import subprocess
from pathlib import Path
from typing import Any, Callable


ROOT = Path(__file__).resolve().parents[1]
GSP_SUITE_KIND = "aerosim.gsp_p0_p4_suite"
PLATFORM_KIND = "aerosim.gsp_wayland_platform"
PERFORMANCE_KIND = "aerosim.gsp_performance"
REQUIRED_GSP_PHASES = ("GS-P0", "GS-P1", "GS-P2", "GS-P3", "GS-P4")
REQUIRED_PLATFORM_CHECKS = (
    "native_wayland",
    "hidpi_2x",
    "cursor_focus_roundtrip",
    "same_monitor",
    "side_by_side",
    "cross_monitor",
    "focus_physics_tick",
    "firefox_file_panel_lna",
    "chromium_file_panel_lna",
    "pipewire_recording_no_black_frames",
    "codex_visual_verification",
)
REQUIRED_ENVIRONMENT = (
    "ubuntu",
    "gnome",
    "kernel",
    "godot",
    "firefox",
    "chromium",
    "display_topology",
    "scaling",
    "wayland",
    "pipewire_portal",
)
GPU_REQUIRED_FIELDS = ("vendor", "model", "driver")
ISSUE_251_FAILURE = Path("build/gsp-idle-qualification-7310191/qualification.failure.json")
HEX40 = re.compile(r"^[0-9a-fA-F]{40}$")
HEX64 = re.compile(r"^[0-9a-fA-F]{64}$")
STATUSES = {"pass", "fail", "blocked", "unavailable", "not_run"}
_VALIDATION_TOKEN = object()


class _ValidatedEvidence(dict):
    __slots__ = ("_validation_token",)

    def __init__(self, payload: dict[str, Any]) -> None:
        super().__init__(payload)
        self._validation_token = _VALIDATION_TOKEN


def _validated(payload: dict[str, Any]) -> _ValidatedEvidence:
    return _ValidatedEvidence(payload)


def _is_validated(value: Any) -> bool:
    return isinstance(value, _ValidatedEvidence) and getattr(value, "_validation_token", None) is _VALIDATION_TOKEN


def _git_commit(repo_root: Path) -> str | None:
    try:
        return subprocess.check_output(["git", "-C", str(repo_root), "rev-parse", "HEAD"], text=True, timeout=5).strip()
    except (OSError, subprocess.SubprocessError):
        return None


def browser_observation(command: str, lookup: Callable[[str], str | None] = shutil.which) -> dict[str, Any]:
    executable = lookup(command)
    if executable is None:
        return {"status": "unavailable", "command": command}
    try:
        version = subprocess.check_output([executable, "--version"], stderr=subprocess.STDOUT, text=True, timeout=5).strip()
    except (OSError, subprocess.SubprocessError) as error:
        return {"status": "unavailable", "command": command, "path": executable, "error": str(error)}
    return {"status": "available", "command": command, "path": executable, "version": version}


def _command_version(command: str) -> str | None:
    executable = shutil.which(command)
    if executable is None:
        return None
    try:
        return subprocess.check_output([executable, "--version"], stderr=subprocess.STDOUT, text=True, timeout=5).strip()
    except (OSError, subprocess.SubprocessError):
        return None


def _gsettings(key: str) -> str | None:
    schema, name = key.rsplit(" ", 1)
    try:
        return subprocess.check_output(["gsettings", "get", schema, name], text=True, timeout=5).strip()
    except (OSError, subprocess.SubprocessError):
        return None


def _service_status(service: str) -> str:
    try:
        return subprocess.run(["systemctl", "--user", "is-active", service], capture_output=True, text=True, timeout=5).stdout.strip() or "unknown"
    except (OSError, subprocess.SubprocessError):
        return "unavailable"


def scale_observation(raw: str | None) -> dict[str, Any]:
    """Classify only the GNOME setting; effective compositor evidence is separate."""
    try:
        value = float((raw or "").split()[-1])
    except (ValueError, IndexError):
        return {"status": "unavailable", "observed": raw, "reason": "scale is not numeric"}
    if value == 0:
        return {"status": "unavailable", "observed": raw, "reason": "GNOME automatic scaling; effective scale not observed"}
    return {"status": "pass" if value >= 2.0 else "fail", "observed": raw, "value": value, "source": "GNOME setting only"}


def _effective_scale_is_valid(value: Any) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value) and value >= 2.0


def gpu_metadata(sys_root: Path = Path("/sys")) -> dict[str, Any]:
    """Read DRM card metadata without importing the benchmark runner."""
    devices: list[dict[str, str]] = []
    try:
        entries = sorted((sys_root / "class" / "drm").iterdir(), key=lambda path: path.name)
    except OSError:
        return {"status": "unavailable", "devices": []}
    for entry in entries:
        if re.fullmatch(r"card\d+", entry.name) is None:
            continue
        device = entry / "device"
        record: dict[str, str] = {"card_name": entry.name, "path": str(device.resolve())}
        for field in ("vendor", "device", "subsystem_vendor", "subsystem_device"):
            try:
                record[field] = (device / field).read_text(encoding="utf-8").strip()
            except OSError:
                pass
        driver = device / "driver"
        try:
            record["driver"] = str(driver.resolve()).rsplit("/", 1)[-1]
        except OSError:
            pass
        devices.append(record)
    return {"status": "available" if devices else "unavailable", "devices": devices}


def _vulkan_observation() -> dict[str, Any]:
    executable = shutil.which("vulkaninfo")
    if executable is None:
        return {"status": "unavailable", "devices": []}
    try:
        output = subprocess.check_output([executable, "--summary"], stderr=subprocess.STDOUT, text=True, timeout=10)
    except (OSError, subprocess.SubprocessError) as error:
        return {"status": "unavailable", "devices": [], "error": str(error)}
    devices: list[dict[str, str]] = []
    current: dict[str, str] | None = None
    fields = {"deviceType": "type", "deviceName": "model", "driverName": "driver", "driverInfo": "driver_info"}
    for line in output.splitlines():
        stripped = line.strip()
        if stripped.startswith("GPU") and stripped.endswith(":"):
            if current:
                devices.append(current)
            current = {}
        elif current is not None and "=" in stripped:
            key, value = (part.strip() for part in stripped.split("=", 1))
            if key in fields:
                current[fields[key]] = value
    if current:
        devices.append(current)
    return {"status": "available" if devices else "unavailable", "devices": devices}


def _godot_observation(binary: str | None) -> dict[str, Any]:
    requested = binary or os.environ.get("GODOT_BIN") or "godot"
    executable = requested if Path(requested).is_file() else shutil.which(requested)
    if executable is None:
        return {"status": "unavailable", "requested": requested}
    version = _command_version(executable)
    if version is None:
        return {"status": "unavailable", "requested": requested, "path": executable}
    return {"status": "available", "requested": requested, "path": str(Path(executable).resolve()), "version": version}


def collect_environment(godot_binary: str | None = None) -> dict[str, Any]:
    os_release: dict[str, str] = {}
    try:
        for line in Path("/etc/os-release").read_text(encoding="utf-8").splitlines():
            if "=" in line:
                key, value = line.split("=", 1)
                os_release[key] = value.strip('"')
    except OSError:
        pass
    scaling = _gsettings("org.gnome.desktop.interface scaling-factor")
    browsers = {name: browser_observation(command) for name, command in {"firefox": "firefox", "chromium": "chromium", "google_chrome_observation_only": "google-chrome"}.items()}
    for browser in browsers.values():
        browser["file_panel_startup"] = "not_run"
        browser["local_network_access"] = "not_run"
    return {
        "os": {"release": os_release, "platform": platform.platform(), "uname": platform.uname()._asdict()},
        "desktop": {"desktop": os.environ.get("XDG_CURRENT_DESKTOP"), "session_desktop": os.environ.get("XDG_SESSION_DESKTOP"), "gnome_shell": _command_version("gnome-shell")},
        "godot": _godot_observation(godot_binary),
        "browsers": browsers,
        "display": {
            "session_type": os.environ.get("XDG_SESSION_TYPE"),
            "wayland_display": os.environ.get("WAYLAND_DISPLAY"),
            "x11_display_observed": os.environ.get("DISPLAY"),
            "gnome_scaling_factor": scaling,
            "scale_observation": scale_observation(scaling),
            "topology": {"status": "unavailable", "reason": "no compositor topology evidence was collected"},
        },
        "gpu": {"pci": gpu_metadata(), "vulkan": _vulkan_observation()},
        "pipewire_portal": {
            "pipewire": _service_status("pipewire"),
            "wireplumber": _service_status("wireplumber"),
            "xdg_desktop_portal": _service_status("xdg-desktop-portal"),
            "xdg_desktop_portal_gnome": _service_status("xdg-desktop-portal-gnome"),
            "recording": {"status": "unavailable", "black_frame_check": "unavailable"},
        },
    }


def _blocked(reason: str) -> dict[str, Any]:
    return _validated({"status": "blocked", "reason": reason})


def _verify_artifact(record: Any, manifest_path: Path) -> dict[str, str] | None:
    if not isinstance(record, dict) or not isinstance(record.get("path"), str) or not HEX64.fullmatch(str(record.get("sha256", ""))):
        return None
    raw_path = Path(record["path"])
    resolved = (raw_path if raw_path.is_absolute() else manifest_path.parent / raw_path).resolve()
    if not resolved.is_file():
        return None
    actual = hashlib.sha256(resolved.read_bytes()).hexdigest()
    if actual.lower() != record["sha256"].lower():
        return None
    return {"path": record["path"], "sha256": actual}


def _provenance_valid(value: Any, commit: str) -> bool:
    return isinstance(value, dict) and all(isinstance(value.get(key), str) and value[key] for key in ("source", "verifier")) and value.get("commit_sha") == commit


def _environment_complete(value: Any) -> bool:
    return isinstance(value, dict) and all(key in value and value[key] not in (None, "") for key in REQUIRED_ENVIRONMENT)


def _gpu_metadata_is_complete(value: Any) -> bool:
    if not isinstance(value, list) or not value:
        return False
    return all(
        isinstance(observation, dict)
        and all(isinstance(observation.get(field), str) and observation[field] for field in GPU_REQUIRED_FIELDS)
        for observation in value
    )


def _topology_is_complete(value: Any) -> bool:
    return (
        isinstance(value, dict)
        and isinstance(value.get("monitor_count"), int)
        and not isinstance(value.get("monitor_count"), bool)
        and value["monitor_count"] >= 2
        and isinstance(value.get("arrangement"), str)
        and bool(value["arrangement"].strip())
    )


def _platform_environment_complete(value: Any) -> bool:
    return _environment_complete(value) and _topology_is_complete(value.get("display_topology")) and _gpu_metadata_is_complete(value.get("gpu"))


def _platform_semantics(checks: Any, environment: Any) -> str | None:
    if not _platform_environment_complete(environment):
        return "platform environment/version metadata is incomplete"
    if not isinstance(checks, dict):
        return "platform checks are malformed"
    native_check = checks.get("native_wayland")
    native = native_check.get("evidence") if isinstance(native_check, dict) else None
    if not isinstance(native, dict) or native.get("display_server") != "Wayland" or "Godot DisplayServer" not in str(native.get("source", "")):
        return "native_wayland requires Godot DisplayServer evidence"
    hidpi_check = checks.get("hidpi_2x")
    hidpi = hidpi_check.get("evidence") if isinstance(hidpi_check, dict) else None
    if not isinstance(hidpi, dict) or "effective" not in str(hidpi.get("source", "")).lower() or not _effective_scale_is_valid(hidpi.get("effective_scale")):
        return "hidpi_2x requires effective compositor/per-monitor scale >= 2"
    cross_monitor_check = checks.get("cross_monitor")
    topology = cross_monitor_check.get("evidence") if isinstance(cross_monitor_check, dict) else None
    topology = topology.get("topology") if isinstance(topology, dict) else None
    environment_topology = environment["display_topology"]
    if not _topology_is_complete(topology):
        return "cross_monitor requires at least two monitors and arrangement evidence"
    if topology["monitor_count"] != environment_topology["monitor_count"] or topology["arrangement"] != environment_topology["arrangement"]:
        return "cross_monitor topology must match environment display_topology"
    codex_check = checks.get("codex_visual_verification")
    codex = codex_check.get("evidence") if isinstance(codex_check, dict) else None
    if not isinstance(codex, dict) or codex.get("verifier") != "Codex" or codex.get("provisional") is not True:
        return "codex_visual_verification is required and must remain provisional"
    return None


def load_evidence_manifest(path: Path, kind: str, required_keys: tuple[str, ...], repo_root: Path) -> dict[str, Any]:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        return _blocked(f"unreadable manifest: {error}")
    commit = _git_commit(repo_root)
    if not isinstance(data, dict) or data.get("schema_version") != 1 or data.get("kind") != kind or not isinstance(data.get("commit_sha"), str) or not HEX40.fullmatch(data["commit_sha"]):
        return _blocked("manifest schema, kind, or commit is invalid")
    if commit is None or data["commit_sha"].lower() != commit.lower() or not _provenance_valid(data.get("provenance"), data["commit_sha"]):
        return _blocked("manifest commit or provenance is stale")
    mapping_key = "phases" if kind == GSP_SUITE_KIND else "checks"
    mapping = data.get(mapping_key)
    if not isinstance(mapping, dict) or set(mapping) != set(required_keys):
        return _blocked(f"{mapping_key} keys must exactly match the required set")
    normalized: dict[str, Any] = {}
    for key in required_keys:
        check = mapping[key]
        if not isinstance(check, dict) or check.get("status") not in STATUSES:
            return _blocked(f"{key} has an invalid status")
        normalized[key] = dict(check)
        if check["status"] == "pass":
            artifact = _verify_artifact(check.get("artifact"), path)
            if artifact is None:
                return _blocked(f"{key} has missing or mismatched artifact evidence")
            normalized[key]["artifact"] = artifact
    if kind == PLATFORM_KIND:
        if not _platform_environment_complete(data.get("environment")):
            return _blocked("platform environment/version metadata is incomplete")
        if any(check["status"] == "pass" for check in normalized.values()):
            semantic_error = _platform_semantics(normalized, data["environment"])
            if semantic_error:
                return _blocked(semantic_error)
    status = "pass" if all(check["status"] == "pass" for check in normalized.values()) else "fail" if any(check["status"] == "fail" for check in normalized.values()) else "blocked"
    result = {"status": status, "kind": kind, "commit_sha": data["commit_sha"], "provenance": data["provenance"], mapping_key: normalized, "source": str(path)}
    if kind == PLATFORM_KIND:
        result["environment"] = data["environment"]
    return _validated(result)


def load_performance_evidence(path: Path | None, repo_root: Path) -> dict[str, Any]:
    if path is None:
        return _validated({"status": "unavailable", "reason": "--performance-evidence was not provided"})
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        source_hash = hashlib.sha256(path.resolve().read_bytes()).hexdigest()
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        return _blocked(f"unreadable performance evidence: {error}")
    source = {"path": str(path), "sha256": source_hash}
    if not isinstance(data, dict):
        return _blocked("performance evidence must be a JSON object")
    status = data.get("status")
    failure_kind = data.get("failure_kind")
    if not isinstance(status, str) or ("failure_kind" in data and not isinstance(failure_kind, str)) or ("commit_sha" in data and not isinstance(data["commit_sha"], str)):
        return _blocked("performance evidence has invalid field types")
    if path.resolve() == (repo_root / ISSUE_251_FAILURE).resolve() and status == "fail" and failure_kind == "conditioning_sample_count":
        failure_commit = data.get("commit_sha")
        if not isinstance(failure_commit, str) or not HEX40.fullmatch(failure_commit) or not isinstance(data.get("observed_sample_count"), int) or isinstance(data.get("observed_sample_count"), bool) or not isinstance(data.get("required_sample_count"), int) or isinstance(data.get("required_sample_count"), bool):
            return _blocked("known issue-251 failure has invalid field types")
        return _validated({"status": "fail", "failure_kind": failure_kind, "source": source, "commit_sha": failure_commit, "observed_sample_count": data["observed_sample_count"], "required_sample_count": data["required_sample_count"]})
    if status != "pass":
        return _validated({"status": "fail", "source": source, "failure_kind": failure_kind if isinstance(failure_kind, str) else "performance_evidence_not_pass"})
    commit = _git_commit(repo_root)
    performance_commit = data.get("commit_sha")
    if not isinstance(performance_commit, str) or not HEX40.fullmatch(performance_commit) or data.get("schema_version") != 1 or data.get("kind") != PERFORMANCE_KIND or commit is None or performance_commit.lower() != commit.lower() or not _provenance_valid(data.get("provenance"), performance_commit) or not isinstance(data.get("reference"), str) or not data["reference"]:
        return _blocked("performance PASS lacks trusted schema, reference, commit, or provenance")
    artifact = _verify_artifact(data.get("artifact"), path)
    if artifact is None:
        return _blocked("performance PASS has missing or mismatched artifact evidence")
    return _validated({"status": "pass", "kind": PERFORMANCE_KIND, "commit_sha": performance_commit, "provenance": data["provenance"], "reference": data["reference"], "artifact": artifact, "source": source})


def evaluate_qualification(manifest: dict[str, Any]) -> dict[str, Any]:
    prerequisites = manifest.get("prerequisites", {}) if isinstance(manifest, dict) else {}
    suite = prerequisites.get("gsp_p0_p4_suite", {}) if isinstance(prerequisites, dict) else {}
    performance = prerequisites.get("issue_251_performance", {}) if isinstance(prerequisites, dict) else {}
    platform = manifest.get("platform_checks", {}) if isinstance(manifest, dict) else {}
    if not _is_validated(suite):
        suite = {}
    if not _is_validated(performance):
        performance = {}
    if not _is_validated(platform):
        platform = {}
    phase_results = suite.get("phases", {})
    check_results = platform.get("checks", {})
    if not isinstance(phase_results, dict):
        phase_results = {}
    if not isinstance(check_results, dict):
        check_results = {}
    entry_status = lambda mapping, key: mapping.get(key, {}).get("status") if isinstance(mapping.get(key, {}), dict) else None
    nonpassing_phases = [phase for phase in REQUIRED_GSP_PHASES if entry_status(phase_results, phase) != "pass"]
    nonpassing_checks = [check for check in REQUIRED_PLATFORM_CHECKS if entry_status(check_results, check) != "pass"]
    reasons = [f"{phase}:{entry_status(phase_results, phase) or suite.get('status', 'missing')}" for phase in nonpassing_phases]
    reasons.extend(f"{check}:{entry_status(check_results, check) or platform.get('status', 'missing')}" for check in nonpassing_checks)
    if suite.get("status") != "pass" and not nonpassing_phases:
        reasons.append(f"gsp_p0_p4_suite:{suite.get('status', 'missing')}")
    if platform.get("status") != "pass" and not nonpassing_checks:
        reasons.append(f"platform_checks:{platform.get('status', 'missing')}")
    if performance.get("status") != "pass":
        reasons.append(f"issue_251_performance:{performance.get('status', 'missing')}:{performance.get('failure_kind', '')}")
    if not _platform_environment_complete(platform.get("environment")):
        reasons.append("platform_environment:missing_required_metadata")
    semantic_error = _platform_semantics(check_results, platform.get("environment"))
    if semantic_error:
        reasons.append(f"platform_semantics:{semantic_error}")
    accepted = suite.get("status") == "pass" and platform.get("status") == "pass" and not nonpassing_phases and not nonpassing_checks and performance.get("status") == "pass" and _platform_environment_complete(platform.get("environment")) and semantic_error is None
    return {"status": "pass" if accepted else "blocked", "accepted": accepted, "required_gsp_phases": list(REQUIRED_GSP_PHASES), "required_platform_checks": list(REQUIRED_PLATFORM_CHECKS), "missing_or_nonpassing_phases": nonpassing_phases, "missing_or_nonpassing_checks": nonpassing_checks, "blocking_reasons": reasons}


def build_report(repo_root: Path = ROOT, godot_binary: str | None = None, gsp_suite_evidence: Path | None = None, performance_evidence: Path | None = None, platform_evidence: Path | None = None) -> dict[str, Any]:
    suite = load_evidence_manifest(gsp_suite_evidence, GSP_SUITE_KIND, REQUIRED_GSP_PHASES, repo_root) if gsp_suite_evidence else _validated({"status": "unavailable", "reason": "--gsp-suite-evidence was not provided"})
    platform = load_evidence_manifest(platform_evidence, PLATFORM_KIND, REQUIRED_PLATFORM_CHECKS, repo_root) if platform_evidence else _validated({"status": "unavailable", "reason": "--platform-evidence was not provided"})
    report = {
        "schema_version": 1,
        "kind": "aerosim.gsp_wayland_qualification",
        "commit_sha": _git_commit(repo_root),
        "environment": collect_environment(godot_binary),
        "prerequisites": {"gsp_p0_p4_suite": suite, "issue_251_performance": load_performance_evidence(performance_evidence, repo_root)},
        "platform_checks": platform,
        "human_visual_review": {"status": "deferred", "until": "CAP-006", "substitute": "none; Codex evidence is a separate required platform check"},
    }
    report["qualification"] = evaluate_qualification(report)
    return report


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--repo-root", type=Path, default=ROOT)
    parser.add_argument("--godot-bin")
    parser.add_argument("--gsp-suite-evidence", type=Path)
    parser.add_argument("--performance-evidence", type=Path)
    parser.add_argument("--platform-evidence", type=Path)
    args = parser.parse_args()
    report = build_report(args.repo_root.resolve(), args.godot_bin, args.gsp_suite_evidence, args.performance_evidence, args.platform_evidence)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"GSP Wayland qualification: {report['qualification']['status'].upper()} ({args.output})")
    return 0 if report["qualification"]["accepted"] else 2


if __name__ == "__main__":
    raise SystemExit(main())
