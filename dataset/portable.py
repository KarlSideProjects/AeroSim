"""Portable synchronized Dataset Recording format and fail-closed validator."""

from __future__ import annotations

import binascii
import hashlib
import json
import math
import os
import re
import struct
import zlib
from dataclasses import dataclass
from pathlib import Path, PurePosixPath
from typing import Any, Iterable, Iterator, Mapping


FORMAT = "aerosim.dataset"
SCHEMA_VERSION = 1
_PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"
_IDENTITY_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]*$")
_KINDS = {"rgb": ".png", "segmentation": ".png", "depth": ".pfm", "lidar": ".bin"}


@dataclass(frozen=True)
class ValidationResult:
    valid: bool
    errors: tuple[str, ...] = ()
    sample_count: int = 0
    dropped_count: int = 0


class DatasetValidationError(ValueError):
    def __init__(self, result: ValidationResult):
        self.result = result
        super().__init__("invalid dataset: " + "; ".join(result.errors))


def encode_png_rgb(width: int, height: int, pixels: bytes) -> bytes:
    """Encode tightly packed 8-bit RGB pixels as a deterministic PNG."""
    if width <= 0 or height <= 0 or len(pixels) != width * height * 3:
        raise ValueError("RGB pixels must contain width * height * 3 bytes")
    rows = b"".join(b"\0" + pixels[y * width * 3:(y + 1) * width * 3] for y in range(height))
    ihdr = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    return _PNG_SIGNATURE + _png_chunk(b"IHDR", ihdr) + _png_chunk(b"IDAT", zlib.compress(rows, 9)) + _png_chunk(b"IEND", b"")


class DatasetWriter:
    """Append synchronized ticks and atomically publish a complete package."""

    def __init__(self, root: os.PathLike[str] | str, manifest: Mapping[str, Any]):
        self.root = Path(root)
        if self.root.exists():
            raise FileExistsError(self.root)
        self.root.mkdir(parents=True)
        self.manifest = json.loads(json.dumps(manifest))
        self.manifest["format"] = FORMAT
        self.manifest["schema_version"] = SCHEMA_VERSION
        self.manifest["status"] = "recording"
        self.manifest["files"] = {"samples": "samples.jsonl"}
        self.manifest.setdefault("byte_order", "little")
        self.manifest.setdefault("timebase", {"unit": "ns", "clock": "simulation"})
        self._streams = {stream["stream_id"]: stream for stream in self.manifest.get("streams", [])}
        if not self._streams:
            raise ValueError("manifest must define streams")
        self._sample_file = (self.root / "samples.jsonl").open("w", encoding="utf-8", newline="\n")
        self._sample_index = 0
        self._last_timestamp = -1
        self._last_stream_timestamp: dict[str, int] = {}
        self._stream_counts = {stream_id: [0, 0] for stream_id in self._streams}
        self._closed = False
        _atomic_json(self.root / "manifest.json", self.manifest)

    def add_sample(self, sample: Mapping[str, Any]) -> None:
        if self._closed:
            raise ValueError("dataset writer is closed")
        if not isinstance(sample, Mapping):
            raise TypeError("sample must be an object")
        timestamp = _integer(sample.get("timestamp_ns"), "sample timestamp_ns")
        if timestamp < 0 or timestamp <= self._last_timestamp:
            raise ValueError("sample timestamps must be non-negative and monotonic")
        vehicles = sample.get("vehicles")
        if not isinstance(vehicles, Mapping):
            raise ValueError("sample vehicles must be an object")
        expected_vehicles = {vehicle["vehicle_id"] for vehicle in self.manifest.get("vehicles", [])}
        if set(vehicles) != expected_vehicles:
            raise ValueError("sample vehicle identities do not match the manifest")
        for vehicle_id, vehicle in vehicles.items():
            if not isinstance(vehicle, Mapping) or any(not isinstance(vehicle.get(key), Mapping) for key in ("command", "state", "collision")):
                raise ValueError(f"vehicle {vehicle_id} must contain command, state, and collision objects")
        if not isinstance(sample.get("environment"), Mapping):
            raise ValueError("sample environment must be an object")

        output = {
            "sample_index": self._sample_index,
            "timestamp_ns": timestamp,
            "vehicles": json.loads(json.dumps(vehicles)),
            "environment": json.loads(json.dumps(sample["environment"])),
            "observations": [],
        }
        seen_streams: set[str] = set()
        for observation in sample.get("observations", []):
            if not isinstance(observation, Mapping):
                raise ValueError("observations must contain objects")
            stream_id = observation.get("stream_id")
            stream = self._streams.get(stream_id)
            if stream is None or stream_id in seen_streams:
                raise ValueError(f"unknown or duplicate stream: {stream_id}")
            seen_streams.add(stream_id)
            _check_observation_identity(observation, stream)
            sequence, gap = _expected_stream_position(stream, self._last_stream_timestamp.get(stream_id), timestamp)
            path = self._write_observation(self._sample_index, observation)
            item = {key: json.loads(json.dumps(value)) for key, value in observation.items() if key != "data"}
            if observation["kind"] == "lidar":
                item["point_count"] = len(observation["data"]) // 3
            item.update({"timestamp_ns": timestamp, "sequence": sequence, "gap_count": gap, "path": path, "byte_order": "little"})
            item["sha256"] = hashlib.sha256((self.root / path).read_bytes()).hexdigest()
            output["observations"].append(item)
            self._last_stream_timestamp[stream_id] = timestamp
            self._stream_counts[stream_id][0] += 1
            self._stream_counts[stream_id][1] += gap

        self._sample_file.write(json.dumps(output, sort_keys=True, separators=(",", ":")) + "\n")
        self._sample_file.flush()
        self._sample_index += 1
        self._last_timestamp = timestamp

    def finalize(self) -> None:
        if self._closed:
            raise ValueError("dataset writer is closed")
        self._close_samples()
        self.manifest["status"] = "complete"
        self.manifest["sample_count"] = self._sample_index
        self.manifest["dropped_count"] = sum(value[1] for value in self._stream_counts.values())
        for stream_id, counts in self._stream_counts.items():
            stream = self._streams[stream_id]
            stream["sample_count"], stream["dropped_count"] = counts
        _atomic_json(self.root / "manifest.json", self.manifest)
        result = validate_dataset(self.root)
        self._closed = True
        if not result.valid:
            self.manifest["status"] = "interrupted"
            _atomic_json(self.root / "manifest.json", self.manifest)
            raise DatasetValidationError(result)

    def abort(self, reason: str = "interrupted") -> None:
        if self._closed:
            return
        self._close_samples()
        self.manifest["status"] = "interrupted"
        self.manifest["termination_reason"] = reason
        _atomic_json(self.root / "manifest.json", self.manifest)
        self._closed = True

    def _close_samples(self) -> None:
        if not self._sample_file.closed:
            self._sample_file.flush()
            os.fsync(self._sample_file.fileno())
            self._sample_file.close()

    def _write_observation(self, sample_index: int, observation: Mapping[str, Any]) -> str:
        kind = observation["kind"]
        stream_id = observation["stream_id"]
        directory = self.root / "assets" / f"{sample_index:06d}"
        directory.mkdir(parents=True, exist_ok=True)
        stem = stream_id.replace("/", "_")
        path = f"assets/{sample_index:06d}/{stem}{_KINDS[kind]}"
        target = self.root / path
        data = observation.get("data")
        if kind in ("rgb", "segmentation"):
            if not isinstance(data, (bytes, bytearray)):
                raise ValueError(f"{kind} data must be PNG bytes")
            info = _png_info(bytes(data))
            if info[:2] != (int(observation["width"]), int(observation["height"])) or info[2:] != (8, 2):
                raise ValueError(f"{kind} PNG dimensions or RGB format do not match")
            target.write_bytes(bytes(data))
        elif kind == "depth":
            _write_pfm(target, int(observation["width"]), int(observation["height"]), data)
        elif kind == "lidar":
            values = [float(value) for value in data]
            if len(values) % 3:
                raise ValueError("LiDAR point data must contain x/y/z triples")
            target.write_bytes(struct.pack("<" + "f" * len(values), *values))
        else:
            raise ValueError(f"unsupported observation kind: {kind}")
        return path


class DatasetReader:
    def __init__(self, root: os.PathLike[str] | str):
        self.root = Path(root)
        self.result = validate_dataset(self.root)
        if not self.result.valid:
            raise DatasetValidationError(self.result)
        self.manifest = json.loads((self.root / "manifest.json").read_text(encoding="utf-8"))

    def samples(self) -> Iterator[dict[str, Any]]:
        with (self.root / "samples.jsonl").open(encoding="utf-8") as sample_file:
            for line in sample_file:
                yield json.loads(line)


def validate_dataset(root: os.PathLike[str] | str) -> ValidationResult:
    root = Path(root)
    errors: list[str] = []
    if not root.is_dir():
        return ValidationResult(False, ("dataset directory is missing",))
    manifest = _read_json(root / "manifest.json", errors, "manifest.json")
    if not isinstance(manifest, Mapping):
        return ValidationResult(False, tuple(errors or ["manifest must be an object"]))
    if manifest.get("format") != FORMAT:
        errors.append("unsupported dataset format")
    if manifest.get("schema_version") != SCHEMA_VERSION:
        errors.append("unsupported dataset schema_version")
    if manifest.get("status") != "complete":
        errors.append("dataset is not complete")
    if manifest.get("coordinate_frame") != "NED":
        errors.append("manifest coordinate_frame must be NED")
    if manifest.get("byte_order") != "little":
        errors.append("manifest byte_order must be little")
    timebase = manifest.get("timebase")
    if not isinstance(timebase, Mapping) or timebase.get("unit") != "ns" or timebase.get("clock") != "simulation":
        errors.append("manifest timebase must be simulation nanoseconds")

    vehicles = manifest.get("vehicles")
    vehicle_ids = _unique_ids(vehicles, "vehicle_id", errors, "vehicles")
    streams = manifest.get("streams")
    stream_map: dict[str, Mapping[str, Any]] = {}
    if not isinstance(streams, list) or not streams:
        errors.append("manifest streams must be a non-empty array")
    else:
        for index, stream in enumerate(streams):
            if not isinstance(stream, Mapping):
                errors.append(f"streams[{index}] must be an object")
                continue
            stream_id = stream.get("stream_id")
            if not _safe_stream_id(stream_id) or stream_id in stream_map:
                errors.append(f"streams[{index}] has an invalid or duplicate stream_id")
                continue
            stream_map[stream_id] = stream
            if stream.get("vehicle_id") not in vehicle_ids or not _safe_id(stream.get("device_id")):
                errors.append(f"streams[{index}] has invalid identity")
            if stream.get("kind") not in _KINDS:
                errors.append(f"streams[{index}] has invalid kind")
            if not _positive_integer(stream.get("period_ns")) or not _nonnegative_integer(stream.get("start_time_ns")):
                errors.append(f"streams[{index}] has invalid timing")

    files = manifest.get("files")
    samples_name = files.get("samples") if isinstance(files, Mapping) else None
    if samples_name != "samples.jsonl" or not _safe_relative(samples_name):
        errors.append("samples path must be samples.jsonl")
        samples_name = "samples.jsonl"
    sample_path = root / samples_name
    if not sample_path.is_file():
        errors.append("samples.jsonl is missing")
        return ValidationResult(False, tuple(errors), 0, 0)

    sample_count = 0
    dropped_count = 0
    last_timestamp = -1
    last_stream_timestamp: dict[str, int] = {}
    stream_counts = {stream_id: [0, 0] for stream_id in stream_map}
    seen_paths: set[str] = set()
    try:
        lines = sample_path.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeError) as error:
        errors.append(f"cannot read samples.jsonl: {error}")
        lines = []
    for line_number, line in enumerate(lines, 1):
        try:
            sample = json.loads(line)
        except (json.JSONDecodeError, UnicodeError) as error:
            errors.append(f"samples.jsonl:{line_number} malformed JSON: {error}")
            continue
        if not isinstance(sample, Mapping):
            errors.append(f"samples.jsonl:{line_number} must be an object")
            continue
        if sample.get("sample_index") != sample_count:
            errors.append(f"samples.jsonl:{line_number} sample_index is not contiguous")
        timestamp = sample.get("timestamp_ns")
        if not _nonnegative_integer(timestamp) or timestamp <= last_timestamp:
            errors.append(f"samples.jsonl:{line_number} timestamp is not monotonic")
        if _nonnegative_integer(timestamp):
            last_timestamp = timestamp
        sample_vehicles = sample.get("vehicles")
        if not isinstance(sample_vehicles, Mapping) or set(sample_vehicles) != set(vehicle_ids):
            errors.append(f"samples.jsonl:{line_number} vehicle identity set mismatch")
        for vehicle_id in vehicle_ids:
            vehicle = sample_vehicles.get(vehicle_id) if isinstance(sample_vehicles, Mapping) else None
            if not isinstance(vehicle, Mapping) or any(not isinstance(vehicle.get(key), Mapping) for key in ("command", "state", "collision")):
                errors.append(f"samples.jsonl:{line_number} vehicle {vehicle_id} is incomplete")
        if not isinstance(sample.get("environment"), Mapping):
            errors.append(f"samples.jsonl:{line_number} environment is missing")
        observations = sample.get("observations")
        if not isinstance(observations, list):
            errors.append(f"samples.jsonl:{line_number} observations must be an array")
            observations = []
        for observation in observations:
            if not isinstance(observation, Mapping):
                errors.append(f"samples.jsonl:{line_number} observation must be an object")
                continue
            stream_id = observation.get("stream_id")
            stream = stream_map.get(stream_id) if isinstance(stream_id, str) else None
            required = ("vehicle_id", "device_id", "kind", "timestamp_ns", "sequence", "gap_count", "path", "sha256")
            if stream is None or any(key not in observation for key in required):
                errors.append(f"samples.jsonl:{line_number} observation identity or fields are missing")
                continue
            try:
                _check_observation_identity(observation, stream)
            except ValueError as error:
                errors.append(f"samples.jsonl:{line_number} {error}")
            observation_timestamp = observation.get("timestamp_ns")
            if observation_timestamp != timestamp:
                errors.append(f"samples.jsonl:{line_number} observation timestamp is not synchronized")
            try:
                sequence, gap = _expected_stream_position(stream, last_stream_timestamp.get(stream_id), observation_timestamp)
                if observation.get("sequence") != sequence or observation.get("gap_count") != gap:
                    errors.append(f"samples.jsonl:{line_number} stream {stream_id} has an unreported gap")
            except (TypeError, ValueError):
                errors.append(f"samples.jsonl:{line_number} stream {stream_id} has invalid timing")
            if _nonnegative_integer(observation_timestamp) and isinstance(stream_id, str):
                last_stream_timestamp[stream_id] = observation_timestamp
            stream_counts[stream_id][0] += 1
            if _nonnegative_integer(observation.get("gap_count")):
                stream_counts[stream_id][1] += observation["gap_count"]
                dropped_count += observation["gap_count"]
            path = observation.get("path")
            if not _safe_relative(path) or path in seen_paths:
                errors.append(f"samples.jsonl:{line_number} asset path is unsafe or duplicated")
                continue
            seen_paths.add(path)
            asset_error = _validate_asset(root, path, observation, manifest.get("byte_order"))
            if asset_error:
                errors.append(f"samples.jsonl:{line_number} {asset_error}")
        sample_count += 1

    if manifest.get("sample_count") != sample_count:
        errors.append("manifest sample_count does not match samples.jsonl")
    if manifest.get("dropped_count") != dropped_count:
        errors.append("manifest dropped_count does not match samples.jsonl")
    for stream_id, counts in stream_counts.items():
        stream = stream_map[stream_id]
        if stream.get("sample_count") != counts[0] or stream.get("dropped_count") != counts[1]:
            errors.append(f"manifest stream counts do not match {stream_id}")
    for stream_id, counts in stream_counts.items():
        if counts[0] == 0:
            errors.append(f"stream has no samples: {stream_id}")
    return ValidationResult(not errors, tuple(errors), sample_count, dropped_count)


def _check_observation_identity(observation: Mapping[str, Any], stream: Mapping[str, Any]) -> None:
    for key in ("vehicle_id", "device_id", "kind"):
        if observation.get(key) != stream.get(key):
            raise ValueError(f"observation {key} does not match stream identity")


def _expected_stream_position(stream: Mapping[str, Any], previous: int | None, timestamp: Any) -> tuple[int, int]:
    timestamp = _integer(timestamp, "observation timestamp_ns")
    period = _integer(stream.get("period_ns"), "stream period_ns")
    start = _integer(stream.get("start_time_ns"), "stream start_time_ns")
    if timestamp < start:
        raise ValueError("observation timestamp precedes stream start")
    if previous is None:
        delta = timestamp - start
    else:
        delta = timestamp - previous
    if delta % period or previous is not None and delta < period:
        raise ValueError("observation timestamp is not aligned to stream rate")
    sequence = (timestamp - start) // period
    return sequence, sequence - ((previous - start) // period + 1) if previous is not None else sequence


def _validate_asset(root: Path, path: str, observation: Mapping[str, Any], byte_order: Any) -> str | None:
    target = root / PurePosixPath(path)
    try:
        target.resolve().relative_to(root.resolve())
    except ValueError:
        return f"asset path escapes dataset root: {path}"
    if not target.is_file():
        return f"asset is missing: {path}"
    kind = observation.get("kind")
    if kind not in _KINDS or Path(path).suffix != _KINDS[kind]:
        return f"asset extension does not match kind: {path}"
    try:
        data = target.read_bytes()
        if observation.get("sha256") != hashlib.sha256(data).hexdigest():
            return f"asset checksum is wrong: {path}"
        if not isinstance(observation.get("sha256"), str) or not re.fullmatch(r"[0-9a-f]{64}", observation["sha256"]) or hashlib.sha256(data).hexdigest() != observation["sha256"]:
            return f"asset checksum is wrong: {path}"
        if kind in ("rgb", "segmentation"):
            width, height, bit_depth, color_type = _png_info(data)
            if (width, height) != (observation.get("width"), observation.get("height")) or (bit_depth, color_type) != (8, 2):
                return f"{kind} PNG dimensions or RGB format are wrong: {path}"
        elif kind == "depth":
            width, height = _pfm_info(data)
            if (width, height) != (observation.get("width"), observation.get("height")):
                return f"depth PFM dimensions are wrong: {path}"
        elif kind == "lidar":
            if byte_order != "little" or observation.get("byte_order") != "little" or len(data) % 12:
                return f"LiDAR byte order or point size is wrong: {path}"
            if observation.get("point_count") != len(data) // 12:
                return f"LiDAR point_count is wrong: {path}"
            values = struct.unpack("<" + "f" * (len(data) // 4), data)
            if any(not math.isfinite(value) or value != 0.0 and abs(value) < 1e-20 for value in values):
                return f"LiDAR contains invalid values or byte order: {path}"
    except (OSError, ValueError, struct.error, zlib.error) as error:
        return f"invalid {kind} asset {path}: {error}"
    return None


def _write_pfm(path: Path, width: int, height: int, values: Iterable[Any]) -> None:
    values = [float(value) for value in values]
    if width <= 0 or height <= 0 or len(values) != width * height:
        raise ValueError("depth values must contain width * height floats")
    path.write_bytes(f"Pf\n{width} {height}\n-1.0\n".encode() + struct.pack("<" + "f" * len(values), *reversed(values)))


def _png_info(data: bytes) -> tuple[int, int, int, int]:
    if not data.startswith(_PNG_SIGNATURE):
        raise ValueError("invalid PNG signature")
    position = len(_PNG_SIGNATURE)
    idat = bytearray()
    info = None
    while position < len(data):
        if position + 12 > len(data):
            raise ValueError("truncated PNG chunk")
        length = struct.unpack(">I", data[position:position + 4])[0]
        chunk_type = data[position + 4:position + 8]
        chunk_end = position + 12 + length
        if chunk_end > len(data):
            raise ValueError("truncated PNG data")
        chunk = data[position + 8:position + 8 + length]
        crc = struct.unpack(">I", data[position + 8 + length:chunk_end])[0]
        if binascii.crc32(chunk_type + chunk) & 0xFFFFFFFF != crc:
            raise ValueError("PNG CRC mismatch")
        if chunk_type == b"IHDR":
            if len(chunk) != 13:
                raise ValueError("invalid PNG IHDR")
            info = struct.unpack(">IIBBBBB", chunk)
        elif chunk_type == b"IDAT":
            idat.extend(chunk)
        elif chunk_type == b"IEND":
            break
        position = chunk_end
    if info is None or not idat:
        raise ValueError("PNG has no image data")
    width, height, bit_depth, color_type, _, _, interlace = info
    if interlace != 0:
        raise ValueError("interlaced PNG is unsupported")
    decoded = zlib.decompress(bytes(idat))
    channels = {0: 1, 2: 3, 4: 2, 6: 4}.get(color_type)
    if channels is None or len(decoded) != height * (1 + width * channels * bit_depth // 8):
        raise ValueError("PNG pixel data size is wrong")
    return width, height, bit_depth, color_type


def _pfm_info(data: bytes) -> tuple[int, int]:
    lines = data.split(b"\n", 3)
    if len(lines) != 4 or lines[0] != b"Pf" or lines[3] == b"":
        raise ValueError("invalid planar-depth PFM")
    try:
        width, height = (int(value) for value in lines[1].split())
        scale = float(lines[2])
    except (ValueError, TypeError):
        raise ValueError("invalid planar-depth PFM header") from None
    if width <= 0 or height <= 0 or scale != -1.0 or len(lines[3]) != width * height * 4:
        raise ValueError("invalid planar-depth PFM dimensions, byte order, or size")
    values = struct.unpack("<" + "f" * (width * height), lines[3])
    if any(not math.isfinite(value) or value != 0.0 and abs(value) < 1e-20 for value in values):
        raise ValueError("invalid planar-depth values or byte order")
    return width, height


def _png_chunk(kind: bytes, data: bytes) -> bytes:
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", binascii.crc32(kind + data) & 0xFFFFFFFF)


def _atomic_json(path: Path, value: Mapping[str, Any]) -> None:
    temporary = path.with_name(path.name + ".tmp")
    with temporary.open("w", encoding="utf-8", newline="\n") as output:
        json.dump(value, output, sort_keys=True, separators=(",", ":"))
        output.write("\n")
        output.flush()
        os.fsync(output.fileno())
    os.replace(temporary, path)


def _read_json(path: Path, errors: list[str], label: str) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        errors.append(f"{label} is missing or malformed: {error}")
        return None


def _unique_ids(value: Any, key: str, errors: list[str], label: str) -> list[str]:
    if not isinstance(value, list):
        errors.append(f"manifest {label} must be an array")
        return []
    result = []
    for item in value:
        identifier = item.get(key) if isinstance(item, Mapping) else None
        if not _safe_id(identifier) or identifier in result:
            errors.append(f"manifest {label} has an invalid or duplicate {key}")
        else:
            result.append(identifier)
    return result


def _safe_id(value: Any) -> bool:
    return isinstance(value, str) and bool(_IDENTITY_RE.fullmatch(value))


def _safe_stream_id(value: Any) -> bool:
    return isinstance(value, str) and bool(value) and all(_safe_id(part) for part in value.split("/"))


def _safe_relative(value: Any) -> bool:
    if not isinstance(value, str) or not value or "\\" in value:
        return False
    path = PurePosixPath(value)
    return not path.is_absolute() and all(part not in ("", ".", "..") for part in path.parts)


def _positive_integer(value: Any) -> bool:
    return isinstance(value, int) and not isinstance(value, bool) and value > 0


def _nonnegative_integer(value: Any) -> bool:
    return isinstance(value, int) and not isinstance(value, bool) and value >= 0


def _integer(value: Any, label: str) -> int:
    if not isinstance(value, int) or isinstance(value, bool):
        raise ValueError(f"{label} must be an integer")
    return value
