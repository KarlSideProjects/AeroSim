import json
import struct
import tempfile
import unittest
from pathlib import Path

from dataset.portable import (
    DatasetReader,
    DatasetWriter,
    encode_png_rgb,
    validate_dataset,
)


def _manifest():
    return {
        "format": "aerosim.dataset",
        "schema_version": 1,
        "coordinate_frame": "NED",
        "timebase": {"unit": "ns", "clock": "simulation"},
        "byte_order": "little",
        "vehicles": [
            {"vehicle_id": "DroneA", "name": "DroneA"},
            {"vehicle_id": "DroneB", "name": "DroneB"},
        ],
        "streams": [
            {"stream_id": "DroneA/front/rgb", "vehicle_id": "DroneA", "device_id": "front", "kind": "rgb", "period_ns": 100_000_000, "start_time_ns": 0},
            {"stream_id": "DroneA/depth/depth", "vehicle_id": "DroneA", "device_id": "depth", "kind": "depth", "period_ns": 100_000_000, "start_time_ns": 0},
            {"stream_id": "DroneA/lidar/lidar", "vehicle_id": "DroneA", "device_id": "lidar", "kind": "lidar", "period_ns": 100_000_000, "start_time_ns": 0},
            {"stream_id": "DroneB/front/segmentation", "vehicle_id": "DroneB", "device_id": "front", "kind": "segmentation", "period_ns": 100_000_000, "start_time_ns": 0},
        ],
    }


def _sample(timestamp_ns):
    observations = [
        {
            "stream_id": "DroneA/front/rgb",
            "vehicle_id": "DroneA",
            "device_id": "front",
            "kind": "rgb",
            "width": 2,
            "height": 1,
            "data": encode_png_rgb(2, 1, bytes((255, 0, 0, 0, 255, 0))),
        },
        {
            "stream_id": "DroneA/depth/depth",
            "vehicle_id": "DroneA",
            "device_id": "depth",
            "kind": "depth",
            "width": 2,
            "height": 1,
            "data": [1.0, 2.0],
        },
        {
            "stream_id": "DroneA/lidar/lidar",
            "vehicle_id": "DroneA",
            "device_id": "lidar",
            "kind": "lidar",
            "data": [1.0, 2.0, 3.0],
        },
        {
            "stream_id": "DroneB/front/segmentation",
            "vehicle_id": "DroneB",
            "device_id": "front",
            "kind": "segmentation",
            "width": 2,
            "height": 1,
            "data": encode_png_rgb(2, 1, bytes((1, 0, 0, 0, 1, 0))),
        },
    ]
    return {
        "timestamp_ns": timestamp_ns,
        "vehicles": {
            "DroneA": {"command": {"throttle": 0.2}, "state": {"x_m": 1.0}, "collision": {"contacts": []}},
            "DroneB": {"command": {"throttle": 0.3}, "state": {"x_m": 2.0}, "collision": {"contacts": []}},
        },
        "environment": {"wind_mps": [0.0, 0.0, 0.0]},
        "observations": observations,
    }


class DatasetRecordingTests(unittest.TestCase):
    def _write_valid(self, root: Path, *, second_timestamp=200_000_000) -> None:
        writer = DatasetWriter(root, _manifest())
        writer.add_sample(_sample(0))
        writer.add_sample(_sample(second_timestamp))
        writer.finalize()

    def test_valid_two_vehicle_package_is_synchronized_and_readable(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp) / "dataset"
            self._write_valid(root)

            result = validate_dataset(root)
            self.assertTrue(result.valid, result.errors)
            self.assertEqual(result.sample_count, 2)
            self.assertEqual(result.dropped_count, 4)
            reader = DatasetReader(root)
            samples = list(reader.samples())
            self.assertEqual([sample["timestamp_ns"] for sample in samples], [0, 200_000_000])
            self.assertEqual(samples[0]["vehicles"]["DroneA"]["state"]["x_m"], 1.0)
            self.assertEqual(samples[0]["observations"][0]["vehicle_id"], "DroneA")

    def test_atomic_finalization_distinguishes_incomplete_and_interrupted(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp) / "dataset"
            writer = DatasetWriter(root, _manifest())
            writer.add_sample(_sample(0))
            self.assertFalse(validate_dataset(root).valid)
            writer.abort()
            interrupted = json.loads((root / "manifest.json").read_text())
            self.assertEqual(interrupted["status"], "interrupted")
            self.assertFalse(validate_dataset(root).valid)

    def test_pause_does_not_duplicate_simulation_time_and_step_keeps_rate_alignment(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp) / "dataset"
            writer = DatasetWriter(root, _manifest())
            writer.add_sample(_sample(0))
            with self.assertRaises(ValueError):
                writer.add_sample(_sample(0))
            writer.add_sample(_sample(100_000_000))
            writer.finalize()
            result = validate_dataset(root)
            self.assertTrue(result.valid, result.errors)
            self.assertEqual(result.dropped_count, 0)

    def test_validator_fails_closed_for_malformed_missing_traversal_identity_time_gap_and_sizes(self):
        mutations = (
            "malformed_json", "missing_file", "traversal", "identity", "timestamp",
            "gap", "image_size", "point_size", "endian", "incomplete",
        )
        for mutation in mutations:
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as temp:
                root = Path(temp) / "dataset"
                self._write_valid(root)
                if mutation == "malformed_json":
                    (root / "samples.jsonl").write_text("{")
                elif mutation == "missing_file":
                    (root / "assets" / "000000" / "DroneA_front_rgb.png").unlink()
                elif mutation == "traversal":
                    rows = [json.loads(line) for line in (root / "samples.jsonl").read_text().splitlines()]
                    rows[0]["observations"][0]["path"] = "../outside.png"
                    (root / "samples.jsonl").write_text("\n".join(json.dumps(row) for row in rows) + "\n")
                elif mutation == "identity":
                    rows = [json.loads(line) for line in (root / "samples.jsonl").read_text().splitlines()]
                    rows[0]["observations"][0]["vehicle_id"] = "DroneB"
                    (root / "samples.jsonl").write_text("\n".join(json.dumps(row) for row in rows) + "\n")
                elif mutation in {"timestamp", "gap", "image_size"}:
                    rows = [json.loads(line) for line in (root / "samples.jsonl").read_text().splitlines()]
                    if mutation == "timestamp":
                        rows[1]["timestamp_ns"] = 0
                    elif mutation == "gap":
                        rows[1]["observations"][0]["gap_count"] = 0
                    else:
                        rows[0]["observations"][0]["width"] = 3
                    (root / "samples.jsonl").write_text("\n".join(json.dumps(row) for row in rows) + "\n")
                elif mutation == "point_size":
                    lidar = next(root.glob("assets/**/*lidar*.bin"))
                    lidar.write_bytes(lidar.read_bytes()[:-1])
                elif mutation == "endian":
                    lidar = next(root.glob("assets/**/*lidar*.bin"))
                    lidar.write_bytes(struct.pack(">fff", 1.0, 2.0, 3.0))
                elif mutation == "incomplete":
                    manifest = json.loads((root / "manifest.json").read_text())
                    manifest["status"] = "interrupted"
                    (root / "manifest.json").write_text(json.dumps(manifest))
                self.assertFalse(validate_dataset(root).valid)

    def test_lidar_writer_uses_little_endian_float32(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp) / "dataset"
            self._write_valid(root)
            lidar = next(root.glob("assets/**/*lidar*.bin"))
            self.assertEqual(lidar.read_bytes(), struct.pack("<fff", 1.0, 2.0, 3.0))


if __name__ == "__main__":
    unittest.main()
