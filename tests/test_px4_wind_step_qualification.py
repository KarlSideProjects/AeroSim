import unittest

from scripts.px4_wind_step_qualification import PX4_REVISION, evaluate
from scripts.px4_wind_step_mission import qualification_readiness_failure, wait_for_async_command


def evidence(**overrides):
    value = {
        "kind": "aerosim.px4_wind_step_qualification",
        "px4_revision": PX4_REVISION,
        "transport": "real",
        "authority": "px4_exclusive",
        "wind": {"applied_tick": 120, "replay_event_tick": 120, "replay_identity": "wind-step-1"},
        "actuators": {"fresh": True, "mapping_verified": True, "age_seconds": 0.01},
        "lean": {"observed": True, "max_abs_roll_or_pitch_rad": 0.12},
        "position_error_m": [0.1, 0.2],
        "limits": {"rms_m": 0.3, "max_m": 0.4},
    }
    value.update(overrides)
    return value


class Px4WindStepQualificationTests(unittest.TestCase):
    def test_async_command_timeout_names_the_stage_without_waiting_forever(self):
        class NeverCompletes:
            def join(self):
                import threading

                threading.Event().wait()

        with self.assertRaisesRegex(TimeoutError, "takeoff timed out"):
            wait_for_async_command(lambda: NeverCompletes(), "takeoff", timeout_seconds=0.01)

    def test_accepts_complete_real_px4_evidence_within_frozen_limits(self):
        result = evaluate(evidence())
        self.assertEqual(result["status"], "qualified")

    def test_missing_prerequisite_is_unavailable_not_qualified(self):
        result = evaluate(None)
        self.assertEqual(result["status"], "unavailable")

    def test_rejects_missing_fresh_mapped_actuators(self):
        result = evaluate(evidence(actuators={"fresh": False, "mapping_verified": False, "age_seconds": 1.0}))
        self.assertEqual(result["status"], "failed")

    def test_rejects_replay_tick_mismatch_and_unfrozen_limit_breach(self):
        bad = evidence(wind={"applied_tick": 120, "replay_event_tick": 121, "replay_identity": "wind-step-1"})
        self.assertEqual(evaluate(bad)["status"], "failed")

    def test_runner_rejects_takeoff_before_px4_readiness_is_proven(self):
        trace = {
            "bridge_events": [
                {"kind": "command_ack", "command": 22, "result": 1},
            ],
            "runtime_authority_events": [],
        }

        self.assertIn("CMD22 ACK", qualification_readiness_failure(trace))
        bad = evidence(position_error_m=[0.6], limits={"rms_m": 0.3, "max_m": 0.4})
        self.assertEqual(evaluate(bad)["status"], "failed")

    def test_runner_requires_bridge_estimator_readiness_before_accepting_takeoff_proof(self):
        trace = {
            "bridge_events": [
                {"kind": "command_ack", "command": 22, "result": 0},
                {"state": "armed", "authority_active": True},
                {"kind": "hil_actuator_controls", "authority_active": True, "outputs": [0.2, 0.2, 0.2, 0.2]},
            ],
            "runtime_authority_events": [{"px4_collision_input": {"touching": False}}],
        }

        self.assertIn("estimator readiness", qualification_readiness_failure(trace))
        trace["bridge_events"].insert(1, {"kind": "estimator_status", "estimator_ready": True})
        self.assertEqual(qualification_readiness_failure(trace), "")
