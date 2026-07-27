import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
import run_gsp_idle_benchmark as benchmark  # noqa: E402
from run_gsp_idle_benchmark import (  # noqa: E402
    cppc_performance,
    cppc_window_performance,
    compare_payloads,
    collect_qualification_provenance,
    combine_protocol_results,
    benchmark_command,
    evaluate_cooling_sequence,
    evaluate_d_a_d_b_drift,
    evaluate_environment_protocol,
    ordered_cooling_samples,
    parse_cppc_snapshot,
    read_gpu_metadata,
    record_environment_evidence_failure,
    validate_conditioning,
    write_qualification_failure,
)


class GspIssue251ProtocolTests(unittest.TestCase):
    def test_cppc_duplicate_field_is_unavailable(self) -> None:
        self.assertIsNone(parse_cppc_snapshot("ref:1 ref:2 del:3", "76"))

    def test_failure_precedes_unavailable_and_preserves_failure_kind(self) -> None:
        result = combine_protocol_results(
            {"status": "FAIL", "failure_kind": "thermal_throttle"},
            {"status": "UNAVAILABLE", "failure_kind": "missing_evidence"},
        )
        self.assertEqual(result, {"status": "FAIL", "failure_kind": "thermal_throttle"})

    def test_conditioning_failure_precedes_missing_cppc(self) -> None:
        result = combine_protocol_results(
            {"status": "FAIL", "failure_kind": "thermal_throttle"},
            {"status": "FAIL", "failure_kind": "configuration_drift"},
            {"status": "UNAVAILABLE", "failure_kind": "missing_evidence"},
        )
        self.assertEqual(result["status"], "FAIL")
        self.assertIn(result["failure_kind"], {"thermal_throttle", "configuration_drift"})

    def test_gpu_metadata_records_two_vendors_without_gate(self) -> None:
        with tempfile.TemporaryDirectory() as root_name:
            root = Path(root_name)
            for index, vendor in enumerate(("0x1002", "0x10de")):
                device = root / "devices" / f"gpu{index}"
                device.mkdir(parents=True)
                (device / "vendor").write_text(vendor, encoding="utf-8")
                (device / "device").write_text(f"0x73{index}", encoding="utf-8")
                (device / "subsystem_vendor").write_text("0x1", encoding="utf-8")
                (device / "subsystem_device").write_text("0x2", encoding="utf-8")
                (device / "driver-amd" if index == 0 else device / "driver-nouveau").mkdir()
                driver = device / ("driver-amd" if index == 0 else "driver-nouveau")
                card = root / "class" / "drm" / f"card{index}"
                (card / "device").parent.mkdir(parents=True)
                (card / "device").symlink_to(device)
                (device / "driver").symlink_to(driver)
            metadata = read_gpu_metadata(root)
            self.assertEqual(metadata["status"], "available")
            self.assertEqual({item["vendor"] for item in metadata["devices"]}, {"0x1002", "0x10de"})
            self.assertTrue(all(item["path"].startswith(str(root / "devices")) for item in metadata["devices"]))
            empty = read_gpu_metadata(root / "empty")
            self.assertEqual(empty, {"status": "unavailable", "devices": []})

            payload = {"samples_ms": [1.0, 1.0]}
            with tempfile.TemporaryDirectory() as output_name:
                unavailable = compare_payloads({"D_a": payload, "I_a": payload, "I_b": payload, "D_b": payload}, Path(output_name), "a" * 40, empty)
                available = compare_payloads({"D_a": payload, "I_a": payload, "I_b": payload, "D_b": payload}, Path(output_name), "a" * 40, metadata)
            self.assertEqual(unavailable["status"], available["status"])
            self.assertFalse(unavailable["provenance"]["gpu_recorded_by_process"])
            self.assertTrue(available["provenance"]["gpu_recorded_by_process"])

    def test_environment_exception_failure_is_machine_readable(self) -> None:
        with tempfile.TemporaryDirectory() as path:
            failure_path = record_environment_evidence_failure(Path(path), "c" * 40)
            result = json.loads(failure_path.read_text(encoding="utf-8"))
            self.assertEqual(result["status"], "fail")
            self.assertEqual(result["environment_status"], "UNAVAILABLE")
            self.assertEqual(result["failure_kind"], "environment_evidence_unavailable")

    def test_main_environment_parse_failure_writes_artifact(self) -> None:
        with tempfile.TemporaryDirectory() as path, patch.dict("os.environ", {"AEROSIM_GSP_IDLE_OUTPUT_DIR": path}), patch.object(benchmark, "read_cpu_configuration", return_value={}), patch.object(benchmark, "collect_qualification_provenance", return_value={"commit_sha": "a" * 40}), patch.object(benchmark, "run_conditioning", side_effect=ValueError("bad environment JSON")):
            with self.assertRaises(ValueError):
                benchmark.main()
            result = json.loads((Path(path) / "qualification.failure.json").read_text(encoding="utf-8"))
            self.assertEqual(result["status"], "fail")
            self.assertEqual(result["environment_status"], "UNAVAILABLE")

    def test_cppc_formula_uses_feedback_delta_and_reference_perf(self) -> None:
        before = parse_cppc_snapshot("ref:100 del:200", "76")
        after = parse_cppc_snapshot("ref:300 del:500", "76")
        self.assertEqual(cppc_performance(before, after), 114.0)

    def test_cppc_counter_rollback_is_unavailable(self) -> None:
        before = parse_cppc_snapshot("ref:300 del:500", "76")
        after = parse_cppc_snapshot("ref:200 del:600", "76")
        self.assertIsNone(cppc_performance(before, after))

    def test_cppc_window_uses_package_aggregate_not_median_cpu(self) -> None:
        first = {
            "elapsed_seconds": 180.0,
            "cppc_samples": {
                "cpu0": {**parse_cppc_snapshot("ref:0 del:0", "100"), "stable_id": "cpu0"},
                "cpu1": {**parse_cppc_snapshot("ref:0 del:0", "100"), "stable_id": "cpu1"},
            },
        }
        last = {
            "elapsed_seconds": 239.0,
            "cppc_samples": {
                "cpu0": {**parse_cppc_snapshot("ref:100 del:100", "100"), "stable_id": "cpu0"},
                "cpu1": {**parse_cppc_snapshot("ref:900 del:1800", "100"), "stable_id": "cpu1"},
            },
        }
        self.assertEqual(cppc_window_performance([first, last], 180.0, 240.0), 190.0)

    def test_cppc_windows_share_boundary_as_adjacent_counter_intervals(self) -> None:
        def sample(elapsed: float, delivered: int) -> dict[str, object]:
            return {
                "elapsed_seconds": elapsed,
                "cppc_samples": {"cpu0": parse_cppc_snapshot(f"ref:{delivered} del:{delivered}", "100")},
            }

        samples = [sample(180.0, 0), sample(240.0, 100), sample(300.0, 200)]
        self.assertEqual(cppc_window_performance(samples, 180.0, 240.0), 100.0)
        self.assertEqual(cppc_window_performance(samples, 240.0, 300.0), 100.0)

    def test_d_a_d_b_drift_passes_with_stable_cppc_and_tctl(self) -> None:
        def run() -> dict[str, object]:
            return {"samples": [
                {"elapsed_seconds": 0.0, "package_temperature_c": 40.0, "cppc_samples": {"cpu0": parse_cppc_snapshot("ref:0 del:0", "100")}},
                {"elapsed_seconds": 1.0, "package_temperature_c": 40.0, "cppc_samples": {"cpu0": parse_cppc_snapshot("ref:100 del:100", "100")}},
            ]}

        self.assertEqual(evaluate_d_a_d_b_drift({"D_a": run(), "D_b": run()})["status"], "PASS")

    def test_collect_provenance_rejects_extension_hash_mismatch(self) -> None:
        with tempfile.TemporaryDirectory() as path:
            root = Path(path)
            binary = root / "fake-godot"
            binary.write_text("#!/bin/sh\necho 'Godot Engine v4.7.stable'\n", encoding="utf-8")
            binary.chmod(0o755)
            (root / "third_party" / "godot-cpp").mkdir(parents=True)
            (root / "third_party" / "godot-cpp" / "AEROSIM_PINNED_COMMIT").write_text("b" * 40, encoding="utf-8")
            (root / "src" / "native").mkdir(parents=True)
            (root / "src" / "native" / "source.cpp").write_text("native", encoding="utf-8")
            (root / "SConstruct").write_text("build", encoding="utf-8")
            extension = root / "bin" / "native.so"
            extension.parent.mkdir()
            extension.write_bytes(b"extension")
            artifact = root / "native.json"
            artifact.write_text(json.dumps({
                "commit_sha": "c" * 40,
                "gdextension_path": "bin/native.so",
                "gdextension_sha256": "0" * 64,
                "native_source_sha256": "0" * 64,
            }), encoding="utf-8")
            with self.assertRaises(RuntimeError):
                collect_qualification_provenance(
                    repo_root=root,
                    godot_binary=binary,
                    native_provenance_path=artifact,
                    configuration={},
                    sys_root=root / "sys",
                )

    def test_benchmark_command_carries_complete_runtime_hashes(self) -> None:
        provenance = {
            "godot_path": "/tmp/fake-godot",
            "godot_version": "Godot Engine v4.7.stable",
            "godot_sha256": "1" * 64,
            "godot_cpp_revision": "2" * 40,
            "gdextension_sha256": "3" * 64,
            "native_source_sha256": "4" * 64,
        }
        command = benchmark_command(Path("out.json"), "authenticated-idle", "a" * 40, 10, 60, benchmark_mode="reference", provenance=provenance)
        self.assertEqual(command[0], provenance["godot_path"])
        for option, value in (("--godot-version", provenance["godot_version"]), ("--godot-sha256", provenance["godot_sha256"]), ("--godot-cpp-revision", provenance["godot_cpp_revision"]), ("--gdextension-sha256", provenance["gdextension_sha256"]), ("--native-source-sha256", provenance["native_source_sha256"])):
            self.assertEqual(command[command.index(option) + 1], value)

    def test_collect_provenance_missing_artifact_is_unavailable(self) -> None:
        with tempfile.TemporaryDirectory() as path:
            root = Path(path)
            binary = root / "fake-godot"
            binary.write_text("#!/bin/sh\necho 'Godot Engine v4.7.stable'\n", encoding="utf-8")
            binary.chmod(0o755)
            with self.assertRaises(RuntimeError):
                collect_qualification_provenance(
                    repo_root=root,
                    godot_binary=binary,
                    native_provenance_path=root / "missing.json",
                    configuration={},
                    sys_root=root / "sys",
                )

    def test_validate_raw_rejects_provenance_mismatch(self) -> None:
        provenance = {
            "commit_sha": "d" * 40,
            "godot_version": "Godot Engine v4.7.stable",
            "godot_sha256": "1" * 64,
            "godot_cpp_revision": "e" * 40,
            "gdextension_sha256": "2" * 64,
            "native_source_sha256": "3" * 64,
        }
        payload = {
            "samples_ms": [1.0] * 14400,
            "sample_count": 14400,
            "commit_sha": provenance["commit_sha"],
            "gsp_mode": "disabled",
            "sampling_source": "PhysicsFrameProfiler._tick",
            "physics_ticks_per_second": 240,
            "monotonic_timing": {"warmup_elapsed_monotonic_seconds": 10.0, "measurement_elapsed_monotonic_seconds": 60.0},
            **{field: value for field, value in provenance.items() if field != "commit_sha"},
        }
        with tempfile.TemporaryDirectory() as path:
            output = Path(path)
            (output / "D_a.raw.json").write_text(json.dumps(payload), encoding="utf-8")
            with self.assertRaises(RuntimeError):
                from run_gsp_idle_benchmark import validate_raw
                validate_raw(output, "D_a", "disabled", provenance["commit_sha"], {**provenance, "godot_sha256": "4" * 64})

    def test_cooling_state_reset_state_and_transition_fail(self) -> None:
        devices = [{"stable_id": "cooling_device0", "path": "/sys/devices/virtual/thermal/cooling_device0"}]
        base = {"cooling_device0": {"cur_state": 0, "max_state": 10, "total_trans": 0, "time_in_state_ms": {"0": 100, "1": 0}}}
        state_fail = {"cooling_device0": {**base["cooling_device0"], "cur_state": 1, "time_in_state_ms": {"0": 101, "1": 0}}}
        transition_fail = {"cooling_device0": {**base["cooling_device0"], "total_trans": 1, "time_in_state_ms": {"0": 101, "1": 0}}}
        reset_fail = {"cooling_device0": {**base["cooling_device0"], "max_state": 11, "time_in_state_ms": {"0": 101, "1": 0}}}
        for changed in (state_fail, transition_fail, reset_fail):
            result = evaluate_cooling_sequence([base, changed], devices)
            self.assertEqual(result["status"], "FAIL")

    def test_cooling_state0_must_grow_and_exist(self) -> None:
        devices = [{"stable_id": "/sys/devices/virtual/thermal/cooling_device0", "path": "/sys/devices/virtual/thermal/cooling_device0"}]
        first = {devices[0]["stable_id"]: {"cur_state": 0, "max_state": 10, "total_trans": 0, "time_in_state_ms": {"0": 100, "1": 0}}}
        unchanged = {devices[0]["stable_id"]: {**first[devices[0]["stable_id"]], "time_in_state_ms": {"0": 100, "1": 0}}}
        missing = {devices[0]["stable_id"]: {**first[devices[0]["stable_id"]], "time_in_state_ms": {"1": 0}}}
        self.assertEqual(evaluate_cooling_sequence([first, unchanged], devices)["status"], "UNAVAILABLE")
        self.assertEqual(evaluate_cooling_sequence([first, missing], devices)["status"], "UNAVAILABLE")

    def test_whole_cooling_sequence_includes_every_boundary(self) -> None:
        device_id = "/sys/devices/virtual/thermal/cooling_device0"
        devices = [{"stable_id": device_id, "path": device_id}]
        def sample(state0: int, transition: int = 0) -> dict[str, object]:
            return {"processor_cooling_samples": {device_id: {"cur_state": 0, "max_state": 1, "total_trans": transition, "time_in_state_ms": {"0": state0, "1": 0}}}}
        phases = {"conditioning": {"boundary_snapshots": {"initial": sample(1), "final": sample(3)}, "samples": [sample(2)]}}
        for label, start in (("D_a", 4), ("I_a", 7), ("I_b", 10), ("D_b", 13)):
            transition = 1 if label in ("I_a", "I_b", "D_b") else 0
            phases[label] = {"boundary_snapshots": {"initial": sample(start, transition), "final": sample(start + 2, transition)}, "samples": [sample(start + 1, transition)]}
        sequence = ordered_cooling_samples(phases["conditioning"], {key: phases[key] for key in phases if key != "conditioning"})
        self.assertEqual(evaluate_cooling_sequence(sequence, devices)["status"], "FAIL")

    def test_conditioning_failure_writes_top_level_mapping(self) -> None:
        with self.subTest("machine-readable failure"):
            import tempfile
            with tempfile.TemporaryDirectory() as path:
                failure_path = write_qualification_failure(Path(path), "a" * 40, "UNAVAILABLE", "missing_evidence")
                import json
                result = json.loads(failure_path.read_text(encoding="utf-8"))
                self.assertEqual(result, {"status": "fail", "environment_status": "UNAVAILABLE", "failure_kind": "environment_evidence_unavailable", "commit_sha": "a" * 40})

    def test_validate_conditioning_raise_leaves_failure_artifact(self) -> None:
        import json
        import tempfile
        with tempfile.TemporaryDirectory() as path:
            environment_path = Path(path) / "conditioning.environment.raw.json"
            environment_path.write_text(json.dumps({
                "commit_sha": "b" * 40,
                "sources": {"cppc_protocol": "unavailable", "processor_cooling_protocol": "unavailable", "processor_cooling_devices": []},
                "configuration_start": {},
                "configuration_end": {},
            }), encoding="utf-8")
            with self.assertRaises(RuntimeError):
                validate_conditioning(environment_path, [], "b" * 40)
            failure = json.loads((Path(path) / "qualification.failure.json").read_text(encoding="utf-8"))
            self.assertEqual(failure["status"], "fail")
            self.assertEqual(failure["environment_status"], "UNAVAILABLE")
            self.assertEqual(failure["failure_kind"], "environment_evidence_unavailable")

    def test_configuration_drift_is_fail(self) -> None:
        conditioning = {
            "status": "PASS",
            "samples": [],
            "configuration_start": {"online_cpus": "0-1", "online_cpu_set": [0, 1], "cppc_cpu_set": [0, 1], "boost": "1", "policies": {"policy0": {"scaling_driver": "amd-pstate-epp", "scaling_governor": "powersave", "energy_performance_preference": "balance_performance", "scaling_min_freq": "1", "scaling_max_freq": "2"}}},
            "configuration_end": {"online_cpus": "0-1", "online_cpu_set": [0, 1], "cppc_cpu_set": [0, 1], "boost": "1", "policies": {"policy0": {"scaling_driver": "acpi-cpufreq", "scaling_governor": "powersave", "energy_performance_preference": "balance_performance", "scaling_min_freq": "1", "scaling_max_freq": "2"}}},
        }
        result = evaluate_environment_protocol(conditioning, {}, conditioning["configuration_start"], conditioning["configuration_end"])
        self.assertEqual(result["status"], "FAIL")
        self.assertEqual(result["failure_kind"], "configuration_drift")

    def test_environment_failure_is_not_masked_by_missing_drift(self) -> None:
        device_id = "/sys/devices/virtual/thermal/cooling_device0"
        device = {"stable_id": device_id, "path": device_id}
        counter = 0

        def sample(transition: int = 0) -> dict[str, object]:
            nonlocal counter
            counter += 1
            return {"processor_cooling_samples": {device_id: {
                "cur_state": 0,
                "max_state": 1,
                "total_trans": transition,
                "time_in_state_ms": {"0": counter, "1": 0},
            }}}

        phases = {}
        conditioning = {"status": "PASS", "admitted": True, "sources": {"processor_cooling_devices": [device]}, "boundary_snapshots": {"initial": sample(), "final": sample()}}
        for label in ("D_a", "I_a", "I_b", "D_b"):
            transition = 1 if label in ("I_a", "I_b", "D_b") else 0
            phases[label] = {"boundary_snapshots": {"initial": sample(transition), "final": sample(transition)}, "samples": []}
        configuration = {"online_cpus": "0", "online_cpu_set": [0], "cppc_cpu_set": [0], "boost": "1", "policies": {"policy0": {"scaling_driver": "amd-pstate-epp", "scaling_governor": "powersave", "energy_performance_preference": "balance_performance", "scaling_min_freq": "1", "scaling_max_freq": "2"}}}
        result = evaluate_environment_protocol(conditioning, phases, configuration, configuration)
        self.assertEqual(result["status"], "FAIL")
        self.assertEqual(result["failure_kind"], "thermal_throttle")

    def test_missing_configuration_is_unavailable(self) -> None:
        result = evaluate_environment_protocol({"status": "PASS", "admitted": True}, {}, {}, {})
        self.assertEqual(result["status"], "UNAVAILABLE")
        self.assertEqual(result["failure_kind"], "missing_evidence")

    def test_d_a_d_b_cppc_and_tctl_drift_fails(self) -> None:
        def run(perf: int, temp: float) -> dict[str, object]:
            return {"samples": [
                {"elapsed_seconds": 0.0, "package_temperature_c": temp, "cppc_samples": {"cpu0": parse_cppc_snapshot("ref:0 del:0", "100")}},
                {"elapsed_seconds": 1.0, "package_temperature_c": temp, "cppc_samples": {"cpu0": parse_cppc_snapshot("ref:100 del:%d" % perf, "100")}},
            ]}
        result = evaluate_d_a_d_b_drift({"D_a": run(100, 40.0), "D_b": run(103, 40.0)})
        self.assertEqual(result["status"], "FAIL")
        self.assertEqual(result["failure_kind"], "run_environment_drift")


if __name__ == "__main__":
    unittest.main()
