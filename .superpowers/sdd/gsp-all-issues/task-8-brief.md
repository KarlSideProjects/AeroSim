# Task 8 brief — GitHub issue #248

Base commit: `0742457`

Implement: preview and apply preset migrations safely.

## Acceptance

- A registry-hash mismatch preview classifies:
  - preset keys removed from the current registry;
  - current-registry parameters absent from the preset, using current registry defaults;
  - values outside current ranges, including original and corrected values.
- Preview is read-only: it does not mutate pending/staged values, native active values, or commit identity.
- Preview returns an opaque, unguessable migration identifier bound to the preset name, exact preset content, and current registry hash.
- Apply rejects a missing, wrong, reused, expired, or stale migration identifier, including when the preset file or current registry changes after preview.
- A confirmed apply commits exactly the previewed current-registry parameter set atomically through the existing preset/tuning staging → native commit path. Do not create a second commit path.
- The panel displays all migration classifications and requires an explicit user confirmation before sending apply.
- Apply produces the existing authoritative tuning ACK/commit behavior, including `source: "preset"` and multi-peer broadcast. Any corrected/clamped values remain visible in ordinary commit data.

## Constraints

- Preserve #247 same-registry save/load/compare behavior and exact preset name whitelist.
- Store authority remains runtime/native; panel state is not authoritative.
- Prefer the minimum extension to the existing preset provider/protocol and panel.
- Bound migration capability lifetime/count and compare exact content/current-registry bindings at apply time; do not persist migration credentials.
- No filesystem path input, shell ability, external dependency, CDN, or module script.
- Tests must use collision-safe per-run preset names and clean only files they created.
- Remain GPU vendor/type neutral: no vendor, device type, adapter, renderer, or driver allowlist/restriction.
- Do not implement #249 lifecycle recovery, #250 session recording/replay, or other later issues.

## Required evidence

- Focused contract tests for classification, read-only preview, and invalid/wrong/reused/stale identifiers.
- Real runtime/WebSocket integration for preview → explicit apply → deferred atomic boundary commit, correlated origin ACK, and identical multi-peer commit broadcast.
- Panel behavior test proving migration report rendering and explicit confirmation.
- Existing #247 preset tests remain green.
- Run the exact full gate on committed HEAD:

```text
RUNNER_TEMP=/tmp/aerosim-gsp-248 \
GODOT_BIN=/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 \
scripts/verify_issue_11.sh
```

## Handoff

Append a detailed problem/solution/test report to `task-8-report.md`, commit all task changes, remove only known generated Godot artifacts, and leave the worktree clean.
