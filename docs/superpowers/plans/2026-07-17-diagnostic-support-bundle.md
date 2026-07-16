# Ubuntu Diagnostic Support Bundle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task with review checkpoints.

**Goal:** Add a local-only, allowlisted Ubuntu support bundle exporter without touching shared flight runtime.

**Architecture:** A standalone `RefCounted` receives sanitized metadata and records bounded named events/raw samples. It audits one `support.json`, writes a temporary ZIP, audits the archive, and atomically renames only after success.

**Tech Stack:** Godot 4.7 GDScript, GUT, built-in `ZIPPacker`, JSON, `FileAccess`/`DirAccess`.

## Global Constraints

- Only one ZIP member: allowlisted `support.json`.
- No JWT, license key, customer/device ID, claims, host/user/home/env/argv/IP/MAC, controller serial/GUID/raw name, free-text logs, `user://`, dumps, CSV, or screenshots.
- Unknown key/type, secret/PII canary, or JSON size over 256 KiB fails closed and removes temporary output.
- Events: named code only, recent 600 seconds, max 200. Raw samples: relative time, recent 5 seconds, 30 Hz contract, max 150.
- Server unreachable uses the caller's local sanitized license snapshot and performs no network operation.

### Task 1: Lock the public contract with focused GUT tests

**Files:** Create `tests/gut/test_diagnostic_support_bundle.gd`; create `common/diagnostics/diagnostic_support_bundle.gd` only after the test is red.

- [ ] Write tests for allowlisted document construction, bounded event/sample retention, canary/type/unknown-key/size rejection, and successful ZIP output with one `support.json` member.
- [ ] Run `GODOT_BIN=/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 scripts/run_gut_tests.sh --recovery-mode`; expect the new tests to fail because the module is absent.

### Task 2: Implement the smallest exporter

**Files:** Create `common/diagnostics/diagnostic_support_bundle.gd`.

- [ ] Implement public `record_event`, `record_raw_sample`, `build_document`, `audit_document`, and `export_bundle` with fixed constants and no external reads/network calls.
- [ ] Use `ZIPPacker` to create a temporary archive, read it back with `ZIPReader`, enforce exactly `support.json`, then `DirAccess.rename_absolute`.
- [ ] Run the focused GUT test file and make it pass; keep temporary/destination cleanup on every failure path.

### Task 3: Add schema and operational documentation

**Files:** Create `config/diagnostic_support_schema.json`; create `docs/diagnostic_support_bundle.md`.

- [ ] Document the exact allowlist, relative-time/capacity rules, deny-by-construction audit, local-only license behavior, and #131 DEV-M human gate status.
- [ ] Add schema fixture checks to the focused GUT tests if the runtime schema is loaded by the module; otherwise keep schema as the reviewable contract matching the code.

### Task 4: Verify and commit

- [ ] Run focused GUT, full GUT recovery, native tests, hardcoded-constant scan, and relevant Python/CI checks if available.
- [ ] Inspect `git diff`/status for only #51 files, commit with `feat: add diagnostic support bundle`, and report the commit plus any unavailable gates/blockers.
