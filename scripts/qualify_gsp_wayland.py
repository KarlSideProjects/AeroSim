#!/usr/bin/env python3
"""Collect and evaluate the non-human GSP Wayland qualification evidence."""

from __future__ import annotations

import argparse
import json
import os
import platform
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Any, Callable

try:
    from scripts.run_gsp_idle_benchmark import read_gpu_metadata
except ModuleNotFoundError:
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    from run_gsp_idle_benchmark import read_gpu_metadata


ROOT = Path(__file__).resolve().parents[1]
REQUIRED_GATES = ("GS-P0", "GS-P1", "GS-P2", "GS-P3", "GS-P4")
ISSUE_251_FAILURE = Path("build/gsp-idle-qualification-7310191/qualification.failure.json")


def browser_observation(command: str, lookup: Callable[[str], str | None] = shutil.which) -> dict[str, Any]:
    executable = lookup(command)
    if executable is None:
        return {"status": "unavailable", "command": command}
    try:
        version = subprocess.check_output(
            [executable, "--version"], stderr=subprocess.STDOUT, text=True, timeout=5
        ).strip()
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
    try:
        return subprocess.check_output(["gsettings", "get", key.rsplit(" ", 1)[0], key.rsplit(" ", 1)[1]], text=True, timeout=5).strip()
    except (OSError, subprocess.SubprocessError):
        return None


def _service_status(service: str) -> str:
    try:
        return subprocess.run(
            ["systemctl", "--user", "is-active", service], capture_output=True, text=True, timeout=5
        ).stdout.strip() or "unknown"
    except (OSError, subprocess.SubprocessError):
        return "unavailable"


def _scale_is_at_least_two(raw: str | None) -> bool:
    try:
        return float((raw or "").split()[-1]) >= 2.0
    except (ValueError, IndexError):
        return False


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


def collect_environment(repo_root: Path = ROOT, godot_binary: str | None = None) -> dict[str, Any]:
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
        "desktop": {
            "desktop": os.environ.get("XDG_CURRENT_DESKTOP"),
            "session_desktop": os.environ.get("XDG_SESSION_DESKTOP"),
            "gnome_shell": _command_version("gnome-shell"),
        },
        "godot": _godot_observation(godot_binary),
        "browsers": browsers,
        "display": {
            "session_type": os.environ.get("XDG_SESSION_TYPE"),
            "wayland_display": os.environ.get("WAYLAND_DISPLAY"),
            "x11_display_observed": os.environ.get("DISPLAY"),
            "gnome_scaling_factor": scaling,
            "topology": {"status": "not_run", "reason": "no compositor topology evidence was collected"},
        },
        "gpu": {"pci": _gpu_metadata(), "vulkan": _vulkan_observation()},
        "pipewire_portal": {
            "pipewire": _service_status("pipewire"),
            "wireplumber": _service_status("wireplumber"),
            "xdg_desktop_portal": _service_status("xdg-desktop-portal"),
            "xdg_desktop_portal_gnome": _service_status("xdg-desktop-portal-gnome"),
            "recording": {"status": "not_run", "black_frame_check": "not_run"},
        },
    }


def _gpu_metadata() -> dict[str, Any]:
    try:
        return read_gpu_metadata()
    except (OSError, ValueError):
        try:
            return read_gpu_metadata()
        except (OSError, ValueError):
            return {"status": "unavailable", "devices": []}


def _issue_251_prerequisite(repo_root: Path) -> dict[str, Any]:
    path = repo_root / ISSUE_251_FAILURE
    if not path.is_file():
        return {"status": "unavailable", "source": str(ISSUE_251_FAILURE)}
    try:
        failure = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {"status": "unavailable", "source": str(ISSUE_251_FAILURE)}
    return {
        "status": "pass" if failure.get("status") == "pass" else "fail",
        "source": str(ISSUE_251_FAILURE),
        "failure_kind": failure.get("failure_kind"),
        "commit_sha": failure.get("commit_sha"),
        "observed_sample_count": failure.get("observed_sample_count"),
        "required_sample_count": failure.get("required_sample_count"),
    }


def _initial_gates(environment: dict[str, Any]) -> dict[str, dict[str, Any]]:
    chromium = environment["browsers"]["chromium"]
    scale = environment["display"].get("gnome_scaling_factor") or ""
    hidpi_blocked = not _scale_is_at_least_two(scale)
    return {
        "GS-P0": {"status": "not_run", "evidence": "scripts/run_gsp_headed_acceptance.sh"},
        "GS-P1": {
            "status": "blocked" if hidpi_blocked else "not_run",
            "evidence": "tests/headed/gsp_headed_acceptance.gd",
            "reason": "2x compositor scaling evidence is unavailable",
        },
        "GS-P2": {
            "status": "blocked" if chromium["status"] != "available" else "not_run",
            "evidence": "scripts/test_gsp_panel_browser.py",
            "reason": "Chromium evidence is unavailable" if chromium["status"] != "available" else "browser workflow not run",
        },
        "GS-P3": {"status": "not_run", "evidence": "scripts/run_gsp_idle_benchmark.sh"},
        "GS-P4": {"status": "not_run", "evidence": "PipeWire/GNOME portal recording", "reason": "recording not run"},
    }


def evaluate_qualification(manifest: dict[str, Any]) -> dict[str, Any]:
    gates = manifest.get("gates", {})
    nonpassing = [gate for gate in REQUIRED_GATES if gates.get(gate, {}).get("status") != "pass"]
    prerequisite = manifest.get("prerequisites", {}).get("issue_251_performance", {})
    reasons = [f"{gate}:{gates.get(gate, {}).get('status', 'missing')}" for gate in nonpassing]
    if prerequisite.get("status") != "pass":
        reasons.append(f"issue_251_performance:{prerequisite.get('status', 'missing')}:{prerequisite.get('failure_kind', '')}")
    accepted = not nonpassing and prerequisite.get("status") == "pass"
    return {
        "status": "pass" if accepted else "blocked",
        "accepted": accepted,
        "required_gates": list(REQUIRED_GATES),
        "missing_or_nonpassing_gates": nonpassing,
        "blocking_reasons": reasons,
    }


def build_report(repo_root: Path = ROOT, godot_binary: str | None = None) -> dict[str, Any]:
    environment = collect_environment(repo_root, godot_binary)
    manifest = {
        "schema_version": 1,
        "issue": 252,
        "environment": environment,
        "prerequisites": {"issue_251_performance": _issue_251_prerequisite(repo_root)},
        "gates": _initial_gates(environment),
        "human_visual_review": {"status": "deferred", "until": "CAP-006"},
    }
    manifest["qualification"] = evaluate_qualification(manifest)
    return manifest


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--repo-root", type=Path, default=ROOT)
    parser.add_argument("--godot-bin")
    args = parser.parse_args()
    report = build_report(args.repo_root.resolve(), args.godot_bin)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"GSP Wayland qualification: {report['qualification']['status'].upper()} ({args.output})")
    return 0 if report["qualification"]["accepted"] else 2


if __name__ == "__main__":
    raise SystemExit(main())
