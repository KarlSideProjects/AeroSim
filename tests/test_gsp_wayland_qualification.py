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
    if "cross_monitor" in checks:
        checks["cross_monitor"]["evidence"] = {"topology": {"monitor_count": 2, "arrangement": "side_by_side"}}
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
            "display_topology": {"monitor_count": 2, "arrangement": "side_by_side"},
            "scaling": {"effective_scale": 2.0},
            "wayland": "native",
            "pipewire_portal": "verified",
            "gpu": [{"vendor": "AMD", "model": "Radeon", "driver": "amdgpu", "type": "integrated", "device": "0x1", "renderer": "radv"}],
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

    def test_effective_scale_rejects_bool_nan_inf_and_below_two(self):
        for value in (True, float("nan"), float("inf"), 1.5):
            with self.subTest(value=value):
                with tempfile.TemporaryDirectory() as raw:
                    directory = Path(raw)
                    path = platform_manifest(directory)
                    body = json.loads(path.read_text())
                    body["checks"]["hidpi_2x"]["evidence"]["effective_scale"] = value
                    path.write_text(json.dumps(body), encoding="utf-8")
                    result = load_evidence_manifest(path, PLATFORM_KIND, REQUIRED_PLATFORM_CHECKS, ROOT)
                self.assertEqual(result["status"], "blocked")

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
            performance = load_performance_evidence(performance_manifest(directory), ROOT)
            results = []
            for gpu in (
                {"vendor": "AMD", "model": "integrated", "type": "iGPU", "device": "x", "driver": "amdgpu", "renderer": "radv"},
                {"vendor": "NVIDIA", "model": "discrete", "type": "dGPU", "device": "y", "driver": "nvidia", "renderer": "vulkan"},
                {"vendor": "Other", "model": "software", "type": "cpu", "device": "z", "driver": "llvmpipe", "renderer": "software"},
            ):
                gpu_directory = directory / gpu["vendor"]
                gpu_directory.mkdir()
                path = platform_manifest(gpu_directory)
                body = json.loads(path.read_text())
                body["environment"]["gpu"] = [gpu]
                path.write_text(json.dumps(body), encoding="utf-8")
                platform = load_evidence_manifest(path, PLATFORM_KIND, REQUIRED_PLATFORM_CHECKS, ROOT)
                results.append(evaluate_qualification({"prerequisites": {"gsp_p0_p4_suite": suite, "issue_251_performance": performance}, "platform_checks": platform}))
            absent_directory = directory / "absent"
            absent_directory.mkdir()
            absent_path = platform_manifest(absent_directory)
            absent_body = json.loads(absent_path.read_text())
            absent_body["environment"].pop("gpu")
            absent_path.write_text(json.dumps(absent_body), encoding="utf-8")
            absent_platform = load_evidence_manifest(absent_path, PLATFORM_KIND, REQUIRED_PLATFORM_CHECKS, ROOT)
            absent = evaluate_qualification({"prerequisites": {"gsp_p0_p4_suite": suite, "issue_251_performance": performance}, "platform_checks": absent_platform})

        self.assertTrue(all(result["accepted"] for result in results))
        self.assertEqual({result["accepted"] for result in results}, {True})
        self.assertFalse(absent["accepted"])

    def test_single_monitor_topology_cannot_pass_cross_monitor(self):
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            path = platform_manifest(directory)
            body = json.loads(path.read_text())
            body["checks"]["cross_monitor"]["evidence"]["topology"]["monitor_count"] = 1
            path.write_text(json.dumps(body), encoding="utf-8")
            result = load_evidence_manifest(path, PLATFORM_KIND, REQUIRED_PLATFORM_CHECKS, ROOT)

        self.assertEqual(result["status"], "blocked")

    def test_mutated_frozen_performance_fail_to_pass_is_rejected(self):
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            manifest = {
                "prerequisites": {
                    "gsp_p0_p4_suite": load_evidence_manifest(suite_manifest(directory), GSP_SUITE_KIND, REQUIRED_GSP_PHASES, ROOT),
                    "issue_251_performance": load_performance_evidence(ROOT / "build/gsp-idle-qualification-7310191/qualification.failure.json", ROOT),
                },
                "platform_checks": load_evidence_manifest(platform_manifest(directory), PLATFORM_KIND, REQUIRED_PLATFORM_CHECKS, ROOT),
            }
            manifest["prerequisites"]["issue_251_performance"]["status"] = "pass"

        self.assertFalse(evaluate_qualification(manifest)["accepted"])

    def test_mutated_suite_phase_status_or_artifact_is_rejected(self):
        for field, value in (("status", "fail"), ("artifact", {"path": "fake", "sha256": "0" * 64})):
            with self.subTest(field=field), tempfile.TemporaryDirectory() as raw:
                directory = Path(raw)
                suite = load_evidence_manifest(suite_manifest(directory), GSP_SUITE_KIND, REQUIRED_GSP_PHASES, ROOT)
                performance = load_performance_evidence(performance_manifest(directory), ROOT)
                platform = load_evidence_manifest(platform_manifest(directory), PLATFORM_KIND, REQUIRED_PLATFORM_CHECKS, ROOT)
                suite["phases"]["GS-P0"][field] = value
                result = evaluate_qualification({"prerequisites": {"gsp_p0_p4_suite": suite, "issue_251_performance": performance}, "platform_checks": platform})

            self.assertFalse(result["accepted"])

    def test_mutated_platform_check_status_or_artifact_is_rejected(self):
        for field, value in (("status", "fail"), ("artifact", {"path": "fake", "sha256": "0" * 64})):
            with self.subTest(field=field), tempfile.TemporaryDirectory() as raw:
                directory = Path(raw)
                suite = load_evidence_manifest(suite_manifest(directory), GSP_SUITE_KIND, REQUIRED_GSP_PHASES, ROOT)
                performance = load_performance_evidence(performance_manifest(directory), ROOT)
                platform = load_evidence_manifest(platform_manifest(directory), PLATFORM_KIND, REQUIRED_PLATFORM_CHECKS, ROOT)
                platform["checks"]["native_wayland"][field] = value
                result = evaluate_qualification({"prerequisites": {"gsp_p0_p4_suite": suite, "issue_251_performance": performance}, "platform_checks": platform})

            self.assertFalse(result["accepted"])

    def test_nonserializable_validated_mutation_is_rejected(self):
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            suite = load_evidence_manifest(suite_manifest(directory), GSP_SUITE_KIND, REQUIRED_GSP_PHASES, ROOT)
            performance = load_performance_evidence(performance_manifest(directory), ROOT)
            platform = load_evidence_manifest(platform_manifest(directory), PLATFORM_KIND, REQUIRED_PLATFORM_CHECKS, ROOT)
            platform["environment"]["gpu"][0]["model"] = object()

        self.assertFalse(evaluate_qualification({"prerequisites": {"gsp_p0_p4_suite": suite, "issue_251_performance": performance}, "platform_checks": platform})["accepted"])

    def test_environment_single_monitor_cannot_pass_cross_monitor_evidence(self):
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            path = platform_manifest(directory)
            body = json.loads(path.read_text())
            body["environment"]["display_topology"]["monitor_count"] = 1
            path.write_text(json.dumps(body), encoding="utf-8")
            result = load_evidence_manifest(path, PLATFORM_KIND, REQUIRED_PLATFORM_CHECKS, ROOT)

        self.assertEqual(result["status"], "blocked")

    def test_environment_topology_arrangement_must_match_cross_monitor_evidence(self):
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            path = platform_manifest(directory)
            body = json.loads(path.read_text())
            body["environment"]["display_topology"]["arrangement"] = "stacked"
            path.write_text(json.dumps(body), encoding="utf-8")
            result = load_evidence_manifest(path, PLATFORM_KIND, REQUIRED_PLATFORM_CHECKS, ROOT)

        self.assertEqual(result["status"], "blocked")

    def test_evaluator_rechecks_mutated_validated_platform_semantics(self):
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            manifest = {
                "prerequisites": {
                    "gsp_p0_p4_suite": load_evidence_manifest(suite_manifest(directory), GSP_SUITE_KIND, REQUIRED_GSP_PHASES, ROOT),
                    "issue_251_performance": load_performance_evidence(performance_manifest(directory), ROOT),
                },
                "platform_checks": load_evidence_manifest(platform_manifest(directory), PLATFORM_KIND, REQUIRED_PLATFORM_CHECKS, ROOT),
            }
            manifest["platform_checks"]["environment"]["display_topology"]["monitor_count"] = 1

        self.assertFalse(evaluate_qualification(manifest)["accepted"])

    def test_raw_fabricated_statuses_cannot_be_evaluated_as_validated_evidence(self):
        raw = {
            "prerequisites": {
                "gsp_p0_p4_suite": {"status": "pass", "phases": {phase: {"status": "pass"} for phase in REQUIRED_GSP_PHASES}},
                "issue_251_performance": {"status": "pass"},
            },
            "platform_checks": {
                "status": "pass",
                "checks": {check: {"status": "pass"} for check in REQUIRED_PLATFORM_CHECKS},
                "environment": {key: "fabricated" for key in ("ubuntu", "gnome", "kernel", "godot", "firefox", "chromium", "display_topology", "scaling", "wayland", "pipewire_portal", "gpu")},
            },
        }

        result = evaluate_qualification(raw)

        self.assertFalse(result["accepted"])
        self.assertEqual(result["status"], "blocked")

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

    def test_malformed_performance_inputs_fail_closed(self):
        for value in ([], 7, "pass"):
            with self.subTest(value=value), tempfile.TemporaryDirectory() as raw:
                path = Path(raw) / "performance.json"
                path.write_text(json.dumps(value), encoding="utf-8")
                result = load_performance_evidence(path, ROOT)
            self.assertEqual(result["status"], "blocked")

        with tempfile.TemporaryDirectory() as raw:
            path = Path(raw) / "performance.json"
            path.write_text(json.dumps({"status": "pass", "commit_sha": 123}), encoding="utf-8")
            result = load_performance_evidence(path, ROOT)

        self.assertEqual(result["status"], "blocked")

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
