import math
import unittest
from pathlib import Path

from scripts.px4_wind_step_qualification import PX4_REVISION, evaluate
from scripts.px4_wind_step_mission import (
    QUALIFICATION_TAKEOFF_NED,
    TARGET_NED,
    qualification_corridor_is_clear,
    qualification_route_clears_drone2,
    qualification_readiness_failure,
    segment_intersects_runtime_wall,
    truth_estimator_convergence_evidence,
    wait_for_async_command,
)


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
    def test_qualification_takeoff_and_target_path_stay_in_the_clear_side_of_runtime_wall(self):
        self.assertTrue(qualification_corridor_is_clear())
        self.assertLess(TARGET_NED[0], QUALIFICATION_TAKEOFF_NED[0])
        self.assertFalse(segment_intersects_runtime_wall(QUALIFICATION_TAKEOFF_NED, TARGET_NED))
        self.assertTrue(qualification_route_clears_drone2())

    def test_runtime_wall_path_guard_rejects_a_low_altitude_segment_through_the_wall(self):
        self.assertTrue(segment_intersects_runtime_wall((0.0, 0.0, 0.0), (2.0, 0.0, 0.0)))

    def test_headless_qualification_places_drone_one_at_the_normal_negative_x_spawn(self):
        source = Path("tests/headless/px4_wind_step_qualification.gd").read_text(encoding="utf-8")
        self.assertIn("QualificationSpawnWorld := Vector3(-1.0, 0.0, 0.0)", source)
        self.assertIn("QualificationSecondarySpawnWorld := Vector3(-1.0, 0.0, 2.0)", source)
        self.assertIn("_place_qualification_vehicles_in_clear_corridor()", source)

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
            "runtime_authority_events": [{"px4_collision_input": {"touching": True}, "px4_launch_handoff_events": [
                {"phase": "support_held", "contact_support": True},
                {"phase": "release_probe", "authority_jolt": False, "vertical_velocity_mps": 0.2},
                {"phase": "cleared"},
            ]}],
        }

        self.assertIn("estimator readiness", qualification_readiness_failure(trace))
        trace["bridge_events"].insert(1, {"kind": "estimator_status", "estimator_ready": True})
        trace["bridge_events"].append({"kind": "px4_stream_sample", "stream": "local_position_ned", "finite": True,
            "sample": {"position_ned": [0.0, 0.0, -3.0], "velocity_ned_mps": [0.0, 0.0, 0.0]}})
        trace["runtime"] = {"truth_kinematics_ned": {"position_ned": [0.0, 0.0, -3.0], "velocity_ned_mps": [0.0, 0.0, 0.0]}}
        self.assertEqual(qualification_readiness_failure(trace), "")

    def test_runner_rejects_wind_step_until_launch_support_probe_and_clearance_are_all_traced(self):
        trace = {
            "bridge_events": [
                {"kind": "command_ack", "command": 22, "result": 0},
                {"kind": "estimator_status", "estimator_ready": True},
                {"state": "armed", "authority_active": True},
                {"kind": "hil_actuator_controls", "authority_active": True, "outputs": [0.3, 0.3, 0.3, 0.3]},
            ],
            "runtime_authority_events": [{"px4_collision_input": {"touching": True}, "px4_launch_handoff_events": [
                {"phase": "support_held", "contact_support": True},
                {"phase": "release_probe", "authority_jolt": False, "vertical_velocity_mps": 0.2},
            ]}],
        }

        self.assertIn("clearance", qualification_readiness_failure(trace))
        trace["runtime_authority_events"][0]["px4_launch_handoff_events"].append({"phase": "cleared"})
        trace["bridge_events"].append({"kind": "px4_stream_sample", "stream": "local_position_ned", "finite": True,
            "sample": {"position_ned": [0.0, 0.0, -3.0], "velocity_ned_mps": [0.0, 0.0, 0.0]}})
        trace["runtime"] = {"truth_kinematics_ned": {"position_ned": [0.0, 0.0, -3.0], "velocity_ned_mps": [0.0, 0.0, 0.0]}}
        self.assertEqual(qualification_readiness_failure(trace), "")

    def test_runner_waits_for_truth_estimator_convergence_and_low_vertical_speed_before_waypoint(self):
        trace = {
            "bridge_events": [
                {"kind": "command_ack", "command": 22, "result": 0},
                {"kind": "estimator_status", "estimator_ready": True},
                {"state": "armed", "authority_active": True},
                {"kind": "hil_actuator_controls", "authority_active": True, "outputs": [0.3, 0.3, 0.3, 0.3]},
            ],
            "runtime_authority_events": [{"px4_collision_input": {"touching": True}, "px4_launch_handoff_events": [
                {"phase": "support_held", "contact_support": True},
                {"phase": "release_probe", "authority_jolt": False, "vertical_velocity_mps": 0.2},
                {"phase": "cleared"},
            ]}],
            "runtime": {"truth_kinematics_ned": {"position_ned": [0.0, 0.0, -3.0], "velocity_ned_mps": [0.0, 0.0, 0.0]}},
        }

        self.assertIn("truth/estimator", qualification_readiness_failure(trace))
        trace["bridge_events"].append({
            "kind": "px4_stream_sample",
            "stream": "local_position_ned",
            "finite": True,
            "sample": {"position_ned": [0.1, 0.0, -3.1], "velocity_ned_mps": [0.0, 0.0, 0.1]},
        })
        self.assertEqual(qualification_readiness_failure(trace), "")
        convergence = truth_estimator_convergence_evidence(trace)
        self.assertEqual(convergence["truth_position_ned"], [0.0, 0.0, -3.0])
        self.assertAlmostEqual(convergence["position_error_m"], math.sqrt(0.02))
        self.assertAlmostEqual(convergence["velocity_error_mps"], 0.1)
