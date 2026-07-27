# Task 9 final review fix round 3 — GitHub issue #249

Continue the same #249 Luna-high thread. The third independent Sol-high review
verified the lifecycle/security fixes but found a small remaining
compliance/evidence set. Fix only these items.

1. **Four-space GDScript indentation.**
   Convert the #249-added/changed lines in
   `tests/headless/gsp_launch_contract.gd` and
   `tests/headless/gsp_server_harness.gd` to four spaces, as required by
   `AGENTS.md`. Keep the conversion scoped to the task-touched blocks; do not
   reformat unrelated files or behavior.

2. **Complete readiness control-inventory evidence.**
   The deterministic panel recovery test currently samples only preset-save,
   one dynamic group button, and one quick-adjust apply button. Extend the
   existing test with the minimum data-driven assertions proving every
   production readiness inventory category remains disabled until the current
   generation has authenticated `hello` plus matching fresh visible snapshot,
   and enables only after both:
   - static simulation/telemetry/preset/migration controls;
   - tuning row slider/number/apply controls;
   - every dynamic group Apply button created by the fixture;
   - all Quick Adjust slot/key/axis/min/max/apply controls.
   Keep the test coupled to the production inventory or derive the expected
   fixture elements so adding a control cannot silently escape the assertion.
   Preserve the existing hidden reconnect and stale-generation checks.

3. **Accurate final-gate report provenance.**
   Update `task-9-report.md` so it no longer says the final gate ran only from
   `facd36a` or that the report-bearing gate is pending. Record the already
   completed exact gate from final HEAD `8026343` and its exit-0 evidence.
   Commit implementation/tests and the report, then run the exact full gate
   again from the new actual final report-bearing HEAD. Do not edit tracked
   files after that gate.

Preserve all #249 behavior, server 8765..8769 fallback, fixed fragment
reconnect, token secrecy, same-sequence delayed probe test, harness-only
launcher override, single-file panel, and GPU vendor/type/device/driver
neutrality.

Run focused tests, commit all tracked changes including the report, then run:

```text
RUNNER_TEMP=/tmp/aerosim-gsp-249 \
GODOT_BIN=/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 \
scripts/verify_issue_11.sh
```

Afterward remove only untracked generated `.uid`, `.import`, and translation
artifacts, verify a clean worktree, and do not edit the ledger or GitHub.
