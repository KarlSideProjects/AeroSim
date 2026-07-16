# Portable Synchronized Dataset Recording Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Write and validate a portable, synchronized two-vehicle Dataset Recording directory without coupling it to Flight Replay or adding a dependency.

**Architecture:** A small Python package owns the on-disk contract. `DatasetWriter` appends JSONL ticks and emits RGB/segmentation PNG, planar-depth PFM, and little-endian float32 LiDAR assets; `validate_dataset` checks the complete package before `DatasetReader` exposes it. The existing Godot camera/sensor/replay code remains unchanged and supplies already-normalized records to this boundary.

**Tech Stack:** Python 3 standard library (`json`, `pathlib`, `struct`, `zlib`, `unittest`); no new dependency.

## Global Constraints

- Package files are exactly `manifest.json`, `samples.jsonl`, RGB/segmentation PNG, planar-depth PFM, and little-endian float32 LiDAR.
- Identity is stable and isolated by vehicle and camera/sensor stream.
- All timestamps are simulation-time nanoseconds; rate gaps are explicit and validated.
- Finalization is atomic; complete is valid, recording/interrupted is inspectable but invalid.
- Validation fails closed for malformed JSON, unsafe/missing paths, identity/timestamp/gap/image/point/endian/incomplete errors.
- Dataset Recording stays separate from Flight Replay.

### Task 1: Freeze behavior with focused tests

**Files:**
- Create: `tests/test_dataset_recording.py`

- [ ] Write tests for a valid two-vehicle package, pause/step gaps, atomic completion, reader output, and each fail-closed mutation.
- [ ] Run `python3 -m unittest tests/test_dataset_recording.py` and confirm failure because the package is absent.

### Task 2: Implement the portable package

**Files:**
- Create: `dataset/__init__.py`
- Create: `dataset/portable.py`
- Create: `config/dataset_schema.json`

- [ ] Implement `DatasetWriter`, `DatasetReader`, `validate_dataset`, and stdlib encoders/decoders for the frozen asset formats.
- [ ] Make final manifest replacement atomic and reject incomplete status in the public validator.
- [ ] Run the focused tests and confirm all pass.

### Task 3: Publish the contract

**Files:**
- Create: `docs/dataset_recording.md`

- [ ] Document every manifest/sample field, units, coordinate frame, byte order, identity, relative path, version rule, and the Replay boundary.
- [ ] Run focused tests, native tests, applicable GUT/smoke gates, and `git diff --check` where prerequisites exist.

### Task 4: Commit

- [ ] Inspect status and diff for unrelated changes.
- [ ] Commit with `feat: add portable dataset recording (#146)`.
