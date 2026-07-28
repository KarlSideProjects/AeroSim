# Task 9 final review fix round 2 — GitHub issue #249

Continue the same #249 Luna-high thread. A fresh Sol-high re-review still
returned SPEC FAIL / QUALITY FAIL. Fix only the findings below with sensitive
RED/GREEN evidence.

## Required fixes

1. **Retry the same probe sequence after publication timeout.**
   The probe file is level-triggered. If the Godot harness has not consumed it,
   incrementing the expected sequence on timeout can leave the client
   permanently ahead. On `ProbePublicationTimeout`, retry the same sequence;
   increment only after a successful publication. Replace/extend the fake test
   with a real delayed-consumption harness seam that proves a missed 250 ms
   publication later succeeds with the same sequence. Process exit and the
   total five-second deadline must remain fatal.

2. **Make credential assertions sensitive to the raw token and exact log count.**
   Save the raw test token independently and assert the launcher error does not
   contain it, in addition to rejecting URL/fragment/token labels. Capture the
   complete launcher stdout and assert the explicit `GSP panel URL:` record
   occurs exactly once. A duplicate URL/token in later output must fail.

3. **Remove test injection from production launch options.**
   `display_name` and `open_panel` must not be accepted in production options.
   Use the smallest harness-only subclass/override seam instead: production
   launch must obtain the real display name and real opener result, while the
   test subclass overrides methods and records that the opener was actually
   invoked. Do not weaken the native-Wayland invariant or expand runtime API.

4. **Bound launcher-harness failure cleanup.**
   If the launcher URL deadline expires while the process is alive, never call
   unbounded `stdout.read()`. Stop/kill the process, then use
   `communicate(timeout=...)`; ensure failure cleanup cannot hang CI.

5. **Style and final-HEAD evidence.**
   Use four-space indentation for newly added/changed GDScript lines as required
   by `AGENTS.md`; do not perform unrelated whole-file reformatting. Update and
   commit the report before the final gate, then run the exact full gate from
   that actual final committed HEAD. Do not make tracked changes after the
   gate. Remove only untracked generated `.uid`, `.import`, and translation
   artifacts and leave the worktree clean.

## Preserve

- all earlier #249 reconnect, hidden readiness, control, stale-generation,
  lifecycle, token and launcher behavior;
- server bind fallback 8765..8769 and fixed fragment reconnect port;
- no persistence, discovery, browser port scan, or secondary credential channel;
- single-file offline panel;
- GPU vendor/type/device/driver neutrality.

Run focused tests, commit production/tests, update and commit
`task-9-report.md`, then run from that final HEAD:

```text
RUNNER_TEMP=/tmp/aerosim-gsp-249 \
GODOT_BIN=/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 \
scripts/verify_issue_11.sh
```

Do not edit the ledger or GitHub.
