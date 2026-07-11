# Deterministic Rate Damping Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the non-reproducible deadbeat Quad-X rate mixer with a bounded stateless rate-damping controller that passes G0.6a and the existing G2.4/G2.5 gates.

**Architecture:** `quad_x_commands` keeps the existing 1 kHz callback and motor allocation. It computes torque from target rate and measured rate without dividing by `control_dt`, clamps torque before allocation, and has no previous-error or integral state. Replay checkpoints report the first divergent frame if cross-platform comparison fails.

**Tech Stack:** C++17, existing native test executables, Godot 4.7 GDExtension, GitHub Actions.

## Global Constraints

- Preserve the G0.6a orientation/position tolerances; never relax them.
- Preserve FRD conversion, Betaflight Quad-X order, 1 kHz substeps, and external motor API validation.
- Do not add dependencies, a settings UI, or an alternate replay-only controller.

---

### Task 1: Lock the saturation regression in a native test

**Files:**
- Modify: `tests/native/test_flight_control.cpp`
- Modify: `src/native/aerosim_flight_control.cpp:72-107`

- [ ] Add a focused test that arms a controller with the existing configured power model, applies a 1 rad/s roll-rate error for one 1 kHz substep, and fails when any motor command saturates.
- [ ] Run `scripts/test_native.sh`; confirm the current deadbeat mixer fails with the new saturation assertion.
- [ ] Replace the torque calculation with `I * (kp * target_rate - kd * actual_rate)` and an explicit pre-allocation torque clamp derived from the existing four-motor thrust capability.
- [ ] Tune only `kp` and `kd` against the existing G2.4 and G2.5 assertions; record every attempted pair and keep the first pair satisfying both.
- [ ] Re-run `scripts/test_native.sh` and commit the controller/test change.

### Task 2: Make replay divergence diagnosable

**Files:**
- Modify: `tests/native/test_replay.cpp`
- Modify: `scripts/compare_replay_artifacts.py`

- [ ] Add fixed replay checkpoints at each physics frame containing frame index, position, quaternion, angular velocity, and four motor commands.
- [ ] Make the comparer report the first checkpoint exceeding the existing G0.6a tolerance; retain the final-state gate unchanged.
- [ ] Verify the new checkpoint assertion fails against the known deadbeat cross-platform artifact and passes on same-platform replay.
- [ ] Run `scripts/test_native.sh` and commit the replay diagnostic change.

### Task 3: Verify the repaired contract

**Files:**
- Modify only evidence artifacts under ignored `build/`

- [ ] Run the PR replay comparison on Linux, Windows, and Android; require all pairs to satisfy current G0.6a tolerance.
- [ ] Run clean `scripts/run_headless_smoke.sh --frames 5`; reject Jolt contention warnings.
- [ ] Run G0.1 effects-off and effects-on on an idle host; require both p99 values below 3 ms.
- [ ] Run `DISPLAY=:0 scripts/run_headed_acceptance.sh`; require the signed Xbox left-roll and push-stick pitch evidence.
- [ ] Push commits to #106, wait for all CI checks, request a fresh adversarial review, then mark the PR ready only when every result is green.
