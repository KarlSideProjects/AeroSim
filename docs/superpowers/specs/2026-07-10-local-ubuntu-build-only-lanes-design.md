# Local Ubuntu Baseline and Build-Only Mobile Lanes Design

**Goal:** Make the maintainer's Ubuntu workstation the formal desktop performance baseline while retaining Android and iOS as CI/build-only lanes with no device-dependent acceptance requirements.

## Decisions

### Desktop baseline

The frozen desktop G0.1 environment is:

- Ubuntu 26.04 LTS
- AMD Ryzen 9 7945HX with Radeon Graphics
- NVIDIA GeForce RTX 4060 Ti, driver 580.159.03

G0.1 keeps every measurement rule and its P99 <= 3 ms threshold: Jolt plus GDExtension main-thread time, VSync off, 10-second warmup, 60-second measured duration, 240 Hz physics, and 1 kHz substeps. The performance harness treats this exact CPU/GPU/toolchain as `gate`, not `reference`.

### Android and iOS lanes

Android and iOS remain product lanes, but are build-only in the current environment.

Required verification remains:

- Platform export/build smoke and native unit tests where the platform toolchain is available.
- Shared deterministic replay, asset loading, renderer configuration, and profile-equivalence CI checks.
- Android APK artifact and size checks.
- iOS static/export configuration checks; an actual iOS build smoke remains `not verified` until a macOS/Xcode CI runner exists.

The following device-dependent items are not applicable and do not block current work: mobile FPS/P99/Perfetto evidence, Android OTG controller testing, iOS MFi/VirtualJoystick device testing, mobile recording, physical install procedures, thermal throttling, high-speed-camera latency, and mobile crash-free soak testing. They must be described as not applicable, never as passed.

This change does not waive desktop device-specific gates, shared-core DEV-M/USR/LEG gates, or any numeric desktop threshold.

## Source of truth and issue state

The PRD gains a concise current-environment policy that points to a decision record. The decision record is the complete allowlist/exception source for Android and iOS device-dependent gates. This avoids editing every later Phase table while preserving its numeric requirements for a future device-enabled environment.

- #17 changes from the legacy Ryzen 5 5600 / GTX 1660S prerequisite to the local Ubuntu baseline. It closes only after the new gate reports, full CI, and independent adversarial review pass.
- #18 and #55 become build-only implementation tracks. Their bodies distinguish required automated checks, not-applicable physical checks, and the iOS macOS build limitation.
- Existing Android/iOS release claims are not made by this policy.

## Minimal implementation

1. Add `docs/decisions/2026-07-10-local-ubuntu-build-only-lanes.md` with the decisions above and explicit non-claims.
2. Update `PRD_AeroSim.md` only where it names the G0.1 desktop machine, mobile benchmark devices, G0.2/G0.5/G0.P physical proof, and the methodology baseline rule; link the decision record for the full mobile exception list.
3. Update `README.md`, `scripts/performance_report.py`, `scripts/run_performance_benchmark.sh`, and `.github/workflows/performance-gpu.yml` so the local Ubuntu machine is the actual G0.1 gate environment.
4. Update tests that assert legacy CPU/GPU eligibility. Regenerate committed off/on G0.1 reports as `gate` reports and require their P99 verdicts to pass.
5. Update #17, #18, and #55 acceptance text and labels. Close #17 only after fresh evidence and independent review; leave #18/#55 open until their remaining build-only work is complete.

## Verification

- Report unit tests reject the former 5600/1660S identity and accept only the local Ubuntu CPU/GPU plus pinned Godot provenance for gate mode.
- Headed local gate runs produce 14,400 samples per off/on report, P99 <= 3 ms, `gate_eligible=true`, and matching comparison metadata.
- The real-GPU workflow runs `gate` mode on the self-hosted local machine and stores both JSON/SVG artifacts.
- Android CI stays green. iOS device/build status is explicitly `not verified` on Ubuntu rather than silently skipped or reported as passed.
- PRD and issue text have no remaining claim that a physical Android/iOS device was tested in this environment.

## Non-goals

- No mobile device emulation is introduced as a substitute for real-device performance, controller, thermal, or latency evidence.
- No Android or iOS release is claimed.
- No desktop threshold is relaxed.
