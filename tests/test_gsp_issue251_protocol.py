import sys
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
from run_gsp_idle_benchmark import (  # noqa: E402
    cppc_performance,
    evaluate_cooling_sequence,
    evaluate_environment_protocol,
    parse_cppc_snapshot,
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

    def test_cooling_state_reset_state_and_transition_fail(self) -> None:
        devices = [{"stable_id": "cooling_device0", "path": "/sys/devices/virtual/thermal/cooling_device0"}]
        base = {"cooling_device0": {"cur_state": 0, "max_state": 10, "total_trans": 0, "time_in_state_ms": {"0": 100, "1": 0}}}
        state_fail = {"cooling_device0": {**base["cooling_device0"], "cur_state": 1}}
        transition_fail = {"cooling_device0": {**base["cooling_device0"], "total_trans": 1}}
        reset_fail = {"cooling_device0": {**base["cooling_device0"], "max_state": 11}}
        for changed in (state_fail, transition_fail, reset_fail):
            result = evaluate_cooling_sequence([base, changed], devices)
            self.assertEqual(result["status"], "FAIL")

    def test_configuration_drift_is_fail(self) -> None:
        conditioning = {
            "status": "PASS",
            "samples": [],
            "configuration_start": {"online_cpus": "0-1", "boost": "1", "policies": {"policy0": {"scaling_driver": "amd-pstate-epp", "scaling_governor": "powersave", "energy_performance_preference": "balance_performance", "scaling_min_freq": "1", "scaling_max_freq": "2"}}},
            "configuration_end": {"online_cpus": "0-1", "boost": "1", "policies": {"policy0": {"scaling_driver": "acpi-cpufreq", "scaling_governor": "powersave", "energy_performance_preference": "balance_performance", "scaling_min_freq": "1", "scaling_max_freq": "2"}}},
        }
        result = evaluate_environment_protocol(conditioning, {}, conditioning["configuration_start"], conditioning["configuration_end"])
        self.assertEqual(result["status"], "FAIL")
        self.assertEqual(result["failure_kind"], "configuration_drift")


if __name__ == "__main__":
    unittest.main()
