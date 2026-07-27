import hashlib
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from scripts.qualify_gsp_wayland import (
    GSP_SUITE_KIND,
    PERFORMANCE_KIND,
    PLATFORM_KIND,
    REQUIRED_GSP_PHASES,
    REQUIRED_PLATFORM_CHECKS,
    build_report,
    evaluate_qualification,
    gpu_metadata,
    load_evidence_manifest,
    load_performance_evidence,
    scale_observation,
)


ROOT = Path(__file__).resolve().parents[1]


def current_commit() -> str:
    return subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()


def write_artifact(directory: Path, name: str = "evidence.txt") -> dict[str, str]:
    path = directory / name
    path.write_text("trusted evidence\n", encoding="utf-8")
    return {"path": name, "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}


def provenance(commit: str) -> dict[str, str]:
    return {"source": "test fixture", "verifier": "tests", "commit_sha": commit}


def suite_manifest(directory: Path, *, phases=None, commit=None) -> Path:
    commit = commit or current_commit()
    artifact = write_artifact(directory)
    body = {
        "schema_version": 1,
        "kind": GSP_SUITE_KIND,
        "commit_sha": commit,
        "provenance": provenance(commit),
        "phases": phases or {phase: {"status": "pass", "artifact": artifact} for phase in REQUIRED_GSP_PHASES},
    }
    path = directory / "suite.json"
    path.write_text(json.dumps(body), encoding="utf-8")
    return path


def platform_manifest(directory: Path, *, checks=None, environment=None, commit=None) -> Path:
    commit = commit or current_commit()
    artifact = write_artifact(directory, "platform.txt")
    checks = checks or {check: {"status": "pass", "artifact": artifact} for check in REQUIRED_PLATFORM_CHECKS}
    if "native_wayland" in checks:
        checks["native_wayland"]["evidence"] = {"source": "Godot DisplayServer", "display_server": "Wayland"}
    if "hidpi_2x" in checks:
        checks["hidpi_2x"]["evidence"] = {"source": "effective compositor/per-monitor evidence", "effective_scale": 2.0}
    if "codex_visual_verification" in checks:
        checks["codex_visual_verification"]["evidence"] = {"verifier": "Codex", "provisional": True}
    body = {
        "schema_version": 1,
        "kind": PLATFORM_KIND,
        "commit_sha": commit,
        "provenance": provenance(commit),
        "environment": environment or {
            "ubuntu": "26.04",
            "gnome": "50.1",
            "kernel": "7.0.0-28-generic",
            "godot": "4.7",
            "firefox": "153",
            "chromium": "153",
            "display_topology": "single monitor",
            "scaling": {"effective_scale": 2.0},
            "wayland": "native",
            "pipewire_portal": "verified",
        },
        "checks": checks,
    }
    path = directory / "platform.json"
    path.write_text(json.dumps(body), encoding="utf-8")
    return path


def performance_manifest(directory: Path, *, status="pass", commit=None) -> Path:
    commit = commit or current_commit()
    artifact = write_artifact(directory, "performance.txt")
    body = {
        "schema_version": 1,
        "kind": PERFORMANCE_KIND,
        "commit_sha": commit,
        "provenance": provenance(commit),
        "reference": "issue-251-performance-contract",
        "status": status,
        "artifact": artifact,
    }
    path = directory / "performance.json"
    path.write_text(json.dumps(body), encoding="utf-8")
    return path


class GspWaylandQualificationTests(unittest.TestCase):
    def test_no_platform_evidence_cannot_pass(self):
        report = build_report(repo_root=ROOT)

        self.assertFalse(report["qualification"]["accepted"])
        self.assertEqual(report["platform_checks"]["status"], "unavailable")

    def test_uint32_zero_is_unknown_not_below_two(self):
        self.assertEqual(scale_observation("uint32 0")["status"], "unavailable")
        self.assertEqual(scale_observation("uint32 1")["status"], "fail")
        self.assertEqual(scale_observation("uint32 2")["status"], "pass")

    def test_gpu_metadata_keeps_only_exact_drm_cards(self):
        with tempfile.TemporaryDirectory() as raw:
            drm = Path(raw) / "class" / "drm"
            (drm / "card0" / "device").mkdir(parents=True)
            (drm / "card0-HDMI-A-1" / "device").mkdir(parents=True)
            for field, value in {"vendor": "0x1002", "device": "0x164e"}.items():
                (drm / "card0" / "device" / field).write_text(value, encoding="utf-8")
            result = gpu_metadata(Path(raw))

        self.assertEqual([device["card_name"] for device in result["devices"]], ["card0"])

    def test_missing_codex_check_blocks_platform_manifest(self):
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            checks = {check: {"status": "pass", "artifact": write_artifact(directory, "x.txt")} for check in REQUIRED_PLATFORM_CHECKS if check != "codex_visual_verification"}
            path = platform_manifest(directory, checks=checks)
            result = load_evidence_manifest(path, PLATFORM_KIND, REQUIRED_PLATFORM_CHECKS, ROOT)

        self.assertEqual(result["status"], "blocked")

    def test_malformed_stale_commit_and_provenance_block_suite(self):
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            path = suite_manifest(directory, commit="0" * 40)
            body = json.loads(path.read_text())
            body["provenance"]["commit_sha"] = "1" * 40
            path.write_text(json.dumps(body), encoding="utf-8")
            result = load_evidence_manifest(path, GSP_SUITE_KIND, REQUIRED_GSP_PHASES, ROOT)

        self.assertEqual(result["status"], "blocked")

    def test_missing_and_hash_mismatch_artifacts_block_pass(self):
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            path = suite_manifest(directory)
            body = json.loads(path.read_text())
            body["phases"]["GS-P0"]["artifact"]["sha256"] = "0" * 64
            path.write_text(json.dumps(body), encoding="utf-8")
            result = load_evidence_manifest(path, GSP_SUITE_KIND, REQUIRED_GSP_PHASES, ROOT)

        self.assertEqual(result["status"], "blocked")

    def test_missing_artifact_blocks_pass(self):
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            path = suite_manifest(directory)
            body = json.loads(path.read_text())
            body["phases"]["GS-P0"]["artifact"]["path"] = "missing.txt"
            path.write_text(json.dumps(body), encoding="utf-8")
            result = load_evidence_manifest(path, GSP_SUITE_KIND, REQUIRED_GSP_PHASES, ROOT)

        self.assertEqual(result["status"], "blocked")

    def test_exact_gs_phase_key_set_is_required(self):
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            phases = {phase: {"status": "pass", "artifact": write_artifact(directory, f"{phase}.txt")} for phase in REQUIRED_GSP_PHASES}
            phases["extra"] = phases["GS-P0"]
            path = suite_manifest(directory, phases=phases)
            result = load_evidence_manifest(path, GSP_SUITE_KIND, REQUIRED_GSP_PHASES, ROOT)

        self.assertEqual(result["status"], "blocked")

    def test_all_platform_keys_are_required(self):
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            checks = {check: {"status": "pass", "artifact": write_artifact(directory, f"{check}.txt")} for check in REQUIRED_PLATFORM_CHECKS}
            del checks["cross_monitor"]
            path = platform_manifest(directory, checks=checks)
            result = load_evidence_manifest(path, PLATFORM_KIND, REQUIRED_PLATFORM_CHECKS, ROOT)

        self.assertEqual(result["status"], "blocked")

    def test_wayland_environment_variable_is_not_displayserver_evidence(self):
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            checks = {check: {"status": "pass", "artifact": write_artifact(directory, f"{check}.txt")} for check in REQUIRED_PLATFORM_CHECKS}
            path = platform_manifest(directory, checks=checks)
            body = json.loads(path.read_text())
            body["checks"]["native_wayland"]["evidence"] = {"source": "WAYLAND_DISPLAY", "display_server": "Wayland"}
            path.write_text(json.dumps(body), encoding="utf-8")
            result = load_evidence_manifest(path, PLATFORM_KIND, REQUIRED_PLATFORM_CHECKS, ROOT)

        self.assertEqual(result["status"], "blocked")

    def test_gpu_metadata_and_absence_are_verdict_neutral(self):
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            suite = load_evidence_manifest(suite_manifest(directory), GSP_SUITE_KIND, REQUIRED_GSP_PHASES, ROOT)
            platform = load_evidence_manifest(platform_manifest(directory), PLATFORM_KIND, REQUIRED_PLATFORM_CHECKS, ROOT)
            performance = load_performance_evidence(performance_manifest(directory), ROOT)
            base = {"prerequisites": {"gsp_p0_p4_suite": suite, "issue_251_performance": performance}, "platform_checks": platform}
            amd = json.loads(json.dumps(base))
            amd["platform_checks"]["environment"]["gpu"] = {"vendor": "AMD", "model": "integrated", "type": "iGPU", "device": "x", "driver": "amdgpu", "renderer": "radv"}
            nvidia = json.loads(json.dumps(base))
            nvidia["platform_checks"]["environment"]["gpu"] = {"vendor": "NVIDIA", "model": "discrete", "type": "dGPU", "device": "y", "driver": "nvidia", "renderer": "vulkan"}
            absent = json.loads(json.dumps(base))
            absent["platform_checks"]["environment"].pop("gpu", None)

        self.assertEqual(evaluate_qualification(amd), evaluate_qualification(nvidia))
        self.assertEqual(evaluate_qualification(amd), evaluate_qualification(absent))

    def test_fully_valid_manifests_and_artifacts_can_pass(self):
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            manifest = {
                "prerequisites": {
                    "gsp_p0_p4_suite": load_evidence_manifest(suite_manifest(directory), GSP_SUITE_KIND, REQUIRED_GSP_PHASES, ROOT),
                    "issue_251_performance": load_performance_evidence(performance_manifest(directory), ROOT),
                },
                "platform_checks": load_evidence_manifest(platform_manifest(directory), PLATFORM_KIND, REQUIRED_PLATFORM_CHECKS, ROOT),
            }

        self.assertEqual(evaluate_qualification(manifest)["status"], "pass")
        self.assertTrue(evaluate_qualification(manifest)["accepted"])

    def test_direct_evaluator_rejects_nonpassing_manifest_status(self):
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            manifest = {
                "prerequisites": {
                    "gsp_p0_p4_suite": load_evidence_manifest(suite_manifest(directory), GSP_SUITE_KIND, REQUIRED_GSP_PHASES, ROOT),
                    "issue_251_performance": load_performance_evidence(performance_manifest(directory), ROOT),
                },
                "platform_checks": load_evidence_manifest(platform_manifest(directory), PLATFORM_KIND, REQUIRED_PLATFORM_CHECKS, ROOT),
            }
            manifest["prerequisites"]["gsp_p0_p4_suite"]["status"] = "blocked"

        self.assertFalse(evaluate_qualification(manifest)["accepted"])

    def test_known_issue_251_failure_blocks(self):
        failure = load_performance_evidence(ROOT / "build/gsp-idle-qualification-7310191/qualification.failure.json", ROOT)

        self.assertEqual(failure["status"], "fail")
        self.assertEqual(failure["failure_kind"], "conditioning_sample_count")

    def test_cli_ingests_explicit_inputs_and_absent_inputs_block(self):
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            output = directory / "report.json"
            argv = ["qualify_gsp_wayland.py", "--output", str(output), "--performance-evidence", str(ROOT / "build/gsp-idle-qualification-7310191/qualification.failure.json")]
            with patch.object(sys, "argv", argv):
                from scripts.qualify_gsp_wayland import main

                self.assertEqual(main(), 2)
            report = json.loads(output.read_text())

        self.assertEqual(report["prerequisites"]["issue_251_performance"]["status"], "fail")
        self.assertEqual(report["prerequisites"]["gsp_p0_p4_suite"]["status"], "unavailable")

    def test_build_report_ingests_all_three_explicit_inputs(self):
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            report = build_report(
                repo_root=ROOT,
                gsp_suite_evidence=suite_manifest(directory),
                performance_evidence=performance_manifest(directory),
                platform_evidence=platform_manifest(directory),
            )

        self.assertTrue(report["qualification"]["accepted"])


if __name__ == "__main__":
    unittest.main()
