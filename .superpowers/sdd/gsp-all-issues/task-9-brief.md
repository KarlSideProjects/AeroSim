# Task 9 brief — GitHub issue #249

Base commit: `175e804`

Implement: recover the GSP panel lifecycle without persisting credentials.

## Acceptance

- A temporary disconnect from the same running Godot process reconnects with bounded exponential backoff using only the token already present in the current document URL fragment / memory.
- Backoff has explicit minimum and maximum delays, avoids a tight loop, resets only after a fully ready session, and does not scan ports.
- Panel tuning, preset, migration, quick-adjust, and simulation controls remain disabled/gray until the replacement connection receives both a fresh authenticated `hello` and a fresh authoritative `snapshot`.
- A page refresh closes/reclaims the previous peer and establishes one replacement peer without leaving the server connection count inflated.
- Abrupt browser termination causes the server to reclaim the peer within five seconds while simulation ticks continue.
- Restarting Godot creates a fresh token. The old panel URL cannot authenticate or discover the replacement token and remains disconnected/gray.
- The restarted process prints and, when requested, opens a new URL whose new token authenticates successfully.
- Tokens are not written to localStorage, sessionStorage, IndexedDB, cookies, files, logs beyond the explicitly printed launch URL, or any secondary discovery endpoint/channel.

## Constraints

- Preserve #241–#248 protocol, queue, tuning, telemetry, preset, and migration behavior.
- Reuse the existing WebSocket lifecycle, auth timeout, peer cleanup, launcher URL, and panel state machinery; add the minimum state required.
- Keep the per-process token model. Do not add port scanning, token refresh, token exchange, a well-known endpoint, filesystem credential storage, or browser persistence.
- Business reconnect state is panel-local and non-authoritative. Runtime/native remain authoritative.
- Keep peer counts and cleanup deterministic and bounded; never pause or otherwise disturb simulation progress during client recovery.
- Single-file `file://` panel remains dependency-free, inline, non-module, and offline-capable.
- Do not implement #251 performance/backpressure expansion beyond the cleanup/recovery behavior necessary for #249.
- Remain GPU vendor/type neutral: no vendor, device type, adapter, renderer, or driver allowlist/restriction.

## Required evidence

- A focused panel behavior test with a deterministic fake clock/WebSocket proving:
  - bounded exponential delays and reset after fresh `hello` + `snapshot`;
  - all controls remain disabled until both messages arrive;
  - stale callbacks/generations cannot re-enable the panel;
  - no browser persistence API or port scan is used.
- Real authenticated WebSocket/runtime coverage proving:
  - refresh/replacement reclaims the old peer and restores the correct connection count;
  - abrupt close/kill-style loss is reclaimed within five seconds while physics tick progress continues;
  - a same-process replacement connection can authenticate with the existing token;
  - a restarted server rejects the old token and accepts only its freshly generated token/new URL.
- Existing GSP transport, telemetry, tuning, preset, quick-adjust, replay, headed, and smoke suites remain green.
- Run the exact full gate on committed HEAD:

```text
RUNNER_TEMP=/tmp/aerosim-gsp-249 \
GODOT_BIN=/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 \
scripts/verify_issue_11.sh
```

## Handoff

Write a detailed problem/solution/test report to `task-9-report.md`, commit all task changes, remove only known generated Godot artifacts, and leave the worktree clean. Do not edit the ledger or GitHub.
