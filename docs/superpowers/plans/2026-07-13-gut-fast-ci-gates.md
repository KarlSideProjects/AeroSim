# GUT-first CI fast gates implementation plan

**Goal:** Fail fast on GDScript regressions, remove duplicate PR builds, and reuse the Linux runtime build for headed smoke without reducing Linux/Windows/Android or replay coverage.

**Safety boundary:** This phase does not skip platform builds by changed paths. Every code PR still runs the complete Linux, Windows, Android, headed, performance-smoke, and replay checks. Blocking GUT runs immediately after the Linux debug GDExtension build. A non-blocking recovery-mode shadow records whether pure-GDScript pre-build execution is reliable enough to promote later.

**Dependency:** Vendor GUT 9.7.1 from commit `aeb5d4f3f7f0a6c9b5e178876d6c99b791fda605`, the upstream version declared compatible with Godot 4.7.x.

## Task 1: Lock the intended CI contract

- [ ] Add `tests/test_ci_strategy.py` before changing CI or runners.
- [ ] Assert PR builds are not duplicated by feature-branch pushes, manual runs remain available, and only stale runs from the same PR may be cancelled.
- [ ] Assert blocking GUT runs immediately after the Linux debug GDExtension build and before Linux smoke/export work.
- [ ] Assert a non-blocking recovery-mode shadow runs the same GUT suite without gating the platform matrix.
- [ ] Assert headed acceptance reuses the Linux debug build and the standalone duplicate-build job is gone.
- [ ] Assert both runtime runners retain logs and enforce structured completion.
- [ ] Run `python3 tests/test_ci_strategy.py` and record the expected failures.

## Task 2: Add the GUT unit-test layer

- [ ] Vendor only upstream `addons/gut` from the locked commit and retain its MIT license.
- [ ] Add the GUT dependency to `third_party/licenses.json` and keep the existing license scan green.
- [ ] Exclude `addons/gut/**` and `tests/gut/**` from release exports so test infrastructure is not shipped.
- [ ] Add `scripts/run_gut_tests.sh` with headless execution, JUnit output, retained import/test logs, fail-loud prerequisite checks, and an explicit `--recovery-mode` shadow option. Recovery mode uses editor recovery only for import, removes the generated `.godot/extension_list.cfg`, then runs the same GUT CLI headlessly without native code; passing recovery mode to the CLI itself leaks Godot resources and is rejected by the console-error gate.
- [ ] Add focused GUT tests for controller fallback/profile behavior and hardware configuration interpolation/schema rules. Each assertion documents the regression it prevents.
- [ ] Run `GODOT_BIN=/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 scripts/run_gut_tests.sh`.
- [ ] Run `scripts/test_license_scan.sh`.

## Task 3: Reorder CI without reducing coverage

- [ ] Restrict `push` to `main`, retain `pull_request`, and add `workflow_dispatch`.
- [ ] Add workflow concurrency keyed by PR number/ref; cancellation is enabled only for PR events.
- [ ] Run blocking GUT immediately after the Linux debug GDExtension build.
- [ ] Add a non-blocking `gut-recovery-shadow` job that runs the same suite with `--recovery-mode`; it must retain evidence but must not be a prerequisite for Linux, Windows, or Android.
- [ ] Run headed acceptance and the existing performance harness from the Linux job after its debug GDExtension build.
- [ ] Preserve all Linux/Windows/Android release exports and the three-way replay comparison.
- [ ] Store headed reports/screenshots from the Linux job with `if: always()`.

## Task 4: Make runtime gates fail loud

- [ ] Make headed acceptance fail if `report.json` cannot be written.
- [ ] Capture headed console output with Godot `--log-file`, require `passed: true`, require the expected screenshots, and reject stable Godot error prefixes.
- [ ] Capture headless console output, require an explicit completed artifact, reject stable Godot error prefixes, and never silently discard a non-zero process exit.
- [ ] Extend the contract test first for every runner behavior, then make the smallest runner/script change that passes it.

## Task 5: Verify and review

- [ ] Run `python3 tests/test_ci_strategy.py` and the existing Python/unit contract tests affected by CI.
- [ ] Run `scripts/test_native.sh`, `scripts/check_hardcoded_airframe_constants.sh`, and `scripts/test_license_scan.sh`.
- [ ] Run GUT, a short headless smoke, and headed acceptance with the locked local Godot binary.
- [ ] Run `git diff --check -- . ':(exclude)addons/gut'`, require the vendored GUT tree to match the locked upstream tree exactly, and inspect the full diff. Upstream whitespace is not rewritten merely to satisfy the project-owned check.
- [ ] Request independent specification and code-quality review; fix all High/Critical findings.
- [ ] Commit the verified implementation on branch `ci/gut-fast-gates` without pushing or merging.
