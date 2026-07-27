import sys
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
from run_gsp_idle_benchmark import (  # noqa: E402
    cppc_performance,
    cppc_window_performance,
    evaluate_cooling_sequence,
    evaluate_d_a_d_b_drift,
    evaluate_environment_protocol,
    ordered_cooling_samples,
    parse_cppc_snapshot,
    validate_conditioning,
    write_qualification_failure,
)


class GspIssue251ProtocolTests(unittest.TestCase):
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
