# Task 11 — GitHub issue #251 report

## Problems

- Reliable admission counted native buffered bytes against the application FIFO, so a transient transport sample could reject otherwise bounded application work.
- Tuning commit broadcast duplicated queue accounting instead of using the shared admission path.
- Reliable flush did not enforce peer-local native pressure before and after sending; telemetry did not require an empty reliable FIFO or use a reachable suppression threshold.
- Overflow and packet-count rejection did not expose bounded local failure/acceptance evidence, and the panel had no production timing samples for request-to-commit and commit-to-rendered-ACK.

## Solutions

- `common/gsp/gsp_server.gd` now keeps application count, application bytes, and serialized message size independently bounded. Native buffered bytes are excluded from admission and sampled only during reliable/telemetry flush.
- Runtime policy is reachable and GPU-neutral: `MAX_RELIABLE_BYTES=65536`, `MAX_RELIABLE_MESSAGE_BYTES=32768`, `TELEMETRY_SUPPRESSION_THRESHOLD_BYTES=32768`, `HARD_CLOSE_THRESHOLD_BYTES=98304`, and `NATIVE_OUTBOUND_CAPACITY_BYTES=131072`; these satisfy `0 < MAX_RELIABLE_MESSAGE_BYTES <= MAX_RELIABLE_BYTES`, telemetry suppression below the reliable bound, the reliable bound below hard close, and hard-close headroom within native capacity.
- Reliable flush peeks the FIFO head, checks native pressure, sends, removes/decrements only after `OK`, then resamples and hard-closes only the impaired peer. Telemetry sends only with an empty reliable FIFO and native bytes below suppression.
- Tuning commits route through `_queue_identity_message` and the central admission helper. Packet-count rejection is an explicit reliable send failure. Overflow preserves earlier FIFO order and performs one nonrecursive best-effort error attempt after earlier messages drain, recording local attempt and local acceptance separately without claiming delivery.
- `common/gsp/gsp_panel.html` records bounded production timing samples and exposes a read-only test snapshot. No new dependency or architecture was added.

## TDD and tests

Initial RED was established before the implementation with:

```text
/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 --headless --path . --script res://tests/headless/gsp_backpressure_contract.gd
```

It failed to parse because the new threshold/admission contract symbols were absent. The focused GREEN contract then passed.

Focused checks passed:

```text
node --check tests/test_gsp_panel_behavior.js
node tests/test_gsp_panel_behavior.js                         # GSP panel row behavior passed
node tests/test_gsp_panel_recovery.js                         # GSP panel recovery behavior passed
Godot gsp_transport_contract.gd                               # PASS
Godot gsp_backpressure_contract.gd                             # PASS
Godot gsp_telemetry_integration.gd                            # PASS
Godot gsp_transport_integration.gd                            # PASS
Godot gsp_telemetry_contract.gd                               # PASS
Godot gsp_tuning_integration.gd                               # PASS
Godot gsp_tuning_stress.gd                                    # PASS
GODOT_BIN=... python3 scripts/test_gsp_transport.py            # PASS, 1000 samples, p99 0.117 ms
RUNNER_TEMP=/tmp/aerosim-gsp-251-native scripts/test_native.sh  # PASS
```

The boundary harness passed FIFO/overflow, pending-handshake, replacement, abrupt reclaim, token, and slow-peer cleanup cases. Its real authenticated two-peer pressure attempt reported:

```text
GSP peer isolation: DEFERRED authenticated_slow_peer_native_buffer=0/131072 telemetry_sends=300 suppression_threshold=32768 platform_socket_backpressure_unobservable=true
```

This is not acceptance evidence for telemetry suppression or hard-close isolation. The platform delivered all 300 telemetry sends without exposing native buffered bytes on the authenticated unread loopback peer, so the required real slow-peer qualification is explicitly deferred rather than forced or claimed.

## Artifact paths

- Contract: `tests/headless/gsp_backpressure_contract.gd`
- Boundary harness: `tests/headless/gsp_server_harness.gd`, `scripts/test_gsp_transport_boundary.py`
- Panel timing contract: `tests/test_gsp_panel_behavior.js`
- Telemetry distribution assertions: `tests/headless/gsp_telemetry_integration.gd`
- No raw issue-specific browser performance JSON/SVG artifact was produced; stdout-only transport timings are not browser qualification artifacts.

The exact committed-HEAD gate was run with:

```text
RUNNER_TEMP=/tmp/aerosim-gsp-251 GODOT_BIN=/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 scripts/verify_issue_11.sh
```

It passed on final committed HEAD `a35dea0`, including native build, license scan, GUT `277/277`, headed acceptance, replay, and headless smoke. It generated the expected build evidence at `build/gut/junit.xml`, `build/native_debug_artifact.json`, and `build/headless_smoke.json`; generated UID/import/translation files are cleanup-only artifacts.

## Deferred items

- Authenticated production-browser rendered-ACK benchmark: deferred. Firefox and display variables were present, but no authenticated production-browser benchmark runner was available; the existing headed driver requires unavailable `ydotool` and is a focus-acceptance driver, while the Node test is only deterministic contract evidence.
- Paired authenticated 60-second idle-vs-disabled measurement: not run. No valid issue-specific runner was available, and the required 60-second duration was not shortened or weakened.
- GPU performance qualification: not run and not used as evidence. No adapter allowlist was added and the frozen NVIDIA-specific G0.1 qualification was not called.

Codebase-memory MCP was available, the worktree was indexed, and it was used for GSP transport/telemetry/panel discovery. The issue ledger and GitHub were not edited.
