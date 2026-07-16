# Portable Dataset Recording

Dataset Recording is an analysis/AI artifact, separate from Flight Replay. A
recording is a directory with `manifest.json`, `samples.jsonl`, and the binary
assets referenced by each sample. It uses only simulation time; wall-clock time
is not part of the contract.

## Package contract

The checked-in contract is [dataset_schema.json](../config/dataset_schema.json)
and `schema_version` is exactly `1`. Readers must reject unknown versions.

`manifest.json` contains:

- `format`: `aerosim.dataset`.
- `schema_version`: integer format version.
- `status`: `recording`, `interrupted`, or `complete`; only `complete` is valid.
- `coordinate_frame`: `NED` world coordinates, SI metres/seconds, and FRD body coordinates.
- `timebase`: nanosecond `simulation` clock.
- `byte_order`: `little`; binary values are little-endian.
- `vehicles`: stable `{vehicle_id, name}` entries. Both configured vehicles are required in every sample.
- `streams`: stable `{stream_id, vehicle_id, device_id, kind, period_ns, start_time_ns}` entries. Stream IDs are slash-separated identity paths; camera and sensor identity never crosses vehicles.
- `files.samples`: the literal safe relative path `samples.jsonl`.
- `sample_count` and `dropped_count`: totals checked against JSONL and stream counters.

Each `samples.jsonl` line contains:

- `sample_index`: contiguous zero-based row number.
- `timestamp_ns`: strictly increasing simulation timestamp.
- `vehicles`: a map for every vehicle, each with `command`, `state`, and `collision` objects.
- `environment`: the captured environment state.
- `observations`: synchronized stream observations. Each has `stream_id`, `vehicle_id`, `device_id`, `kind`, `timestamp_ns`, `sequence`, `gap_count`, `path`, `byte_order`, and `sha256`; `timestamp_ns` equals the containing sample timestamp.

`sequence` is the stream sample number from `start_time_ns`. If a stream jumps
by `n` periods, `gap_count` is `n - 1`; an unreported jump is invalid. Paused
simulation produces no new timestamp, while frame/duration stepping advances
the same clock and rate alignment remains integer nanoseconds.

## Assets

All `path` values are canonical POSIX relative paths. Absolute paths, `..`,
backslashes, missing files, duplicate references, checksum changes, and
symlink escapes are invalid.

- `rgb` and `segmentation`: non-interlaced 8-bit RGB PNG with the declared `width` and `height`.
- `depth`: `Pf` PFM planar depth, rows stored bottom-to-top, scale `-1.0`, little-endian float32.
- `lidar`: raw little-endian float32 XYZ triples; `point_count` must equal the file size divided by 12.

`DatasetWriter.finalize()` flushes `samples.jsonl`, atomically replaces the
manifest, and validates the resulting package. An interrupted writer keeps its
directory inspectable but the validator rejects it. `DatasetReader` opens only
validated complete packages.
