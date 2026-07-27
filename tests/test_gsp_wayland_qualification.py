import unittest

from scripts.qualify_gsp_wayland import (
    REQUIRED_GATES,
    _scale_is_at_least_two,
    browser_observation,
    evaluate_qualification,
)


def manifest(*, gate_status="pass", performance_status="pass", gpu=None):
    return {
        "gates": {gate: {"status": gate_status} for gate in REQUIRED_GATES},
        "prerequisites": {
            "issue_251_performance": {
                "status": performance_status,
                "failure_kind": "conditioning_sample_count",
            }
        },
        "environment": {"gpu": gpu or {"devices": []}},
    }


class GspWaylandQualificationTests(unittest.TestCase):
    def test_frozen_issue_251_failure_blocks_platform_pass(self):
        result = evaluate_qualification(manifest(performance_status="fail"))

        self.assertEqual(result["status"], "blocked")
        self.assertFalse(result["accepted"])
        self.assertTrue(any(reason.startswith("issue_251_performance:") for reason in result["blocking_reasons"]))

    def test_every_non_human_gate_is_required(self):
        result = evaluate_qualification(manifest(gate_status="not_run"))

        self.assertEqual(result["status"], "blocked")
        self.assertFalse(result["accepted"])
        self.assertEqual(set(result["missing_or_nonpassing_gates"]), set(REQUIRED_GATES))

    def test_gpu_metadata_never_changes_verdict(self):
        amd = evaluate_qualification(manifest(gpu={"devices": [{"vendor": "AMD"}]}))
        nvidia = evaluate_qualification(manifest(gpu={"devices": [{"vendor": "NVIDIA"}]}))

        self.assertEqual(amd, nvidia)

    def test_missing_chromium_is_recorded_without_using_google_chrome(self):
        observed = browser_observation("chromium", lookup=lambda _: None)

        self.assertEqual(observed, {"status": "unavailable", "command": "chromium"})

    def test_hidpi_threshold_accepts_any_scale_at_or_above_two(self):
        self.assertFalse(_scale_is_at_least_two("uint32 1"))
        self.assertTrue(_scale_is_at_least_two("uint32 2"))
        self.assertTrue(_scale_is_at_least_two("double 2.5"))


if __name__ == "__main__":
    unittest.main()
