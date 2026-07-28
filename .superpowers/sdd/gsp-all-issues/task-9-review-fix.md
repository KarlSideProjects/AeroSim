# Task 9 final review fix — GitHub issue #249

Continue the same #249 Luna-high thread. The independent Sol-high final review
returned SPEC FAIL / QUALITY FAIL. Fix only these findings with RED/GREEN tests:

1. **Token duplication in launcher errors (blocking).**
   `common/gsp/gsp_launcher.gd` prints the explicit launch URL once, but an
   `OS.shell_open()` failure currently returns/pushes an error that includes the
   full token-bearing URL again. Keep the explicitly printed launch URL, but
   ensure every shell-open failure/error string is URL- and fragment-free.
   Add a focused assertion proving a token-bearing URL cannot appear in the
   launcher error string.

2. **Restart evidence must include the launcher/new URL (important).**
   Extend the real restart integration so the second Godot process exercises
   the `GspLauncher` seam, captures its newly printed
   `file://...#port=...&token=...` URL, verifies that token authenticates, and
   proves the stale first-process token is rejected. Cover the requested-open
   path without actually depending on a desktop browser: use the smallest
   injectable/test seam already present or add only the minimum seam needed.
   Do not persist or expose credentials through any secondary channel.

3. **Abrupt-reclaim retry false negative (important).**
   In `scripts/test_gsp_transport_boundary.py`, a single 250 ms probe
   publication timeout inside the five-second outer deadline must be retryable.
   Only fail if the Godot process exits or the total deadline expires. Add a
   deterministic focused regression check for a delayed/missed probe followed
   by success.

Preserve:

- panel reconnect uses exactly the fragment port/token, no scan or persistence;
- hidden reconnect/readiness behavior and all control inventory;
- server bind fallback 8765..8769;
- exact peer/tick lifecycle evidence;
- single-file offline panel;
- GPU vendor/type/device/driver neutrality.

Run focused tests first, commit the fix, then run the exact committed-HEAD gate:

```text
RUNNER_TEMP=/tmp/aerosim-gsp-249 \
GODOT_BIN=/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 \
scripts/verify_issue_11.sh
```

Update `task-9-report.md`, commit it, clean only generated `.uid`, `.import`,
and translation artifacts, and leave the worktree clean. Do not edit the
ledger or GitHub.
