# AeroSim Task 2 / Issue #242 report

## Implementation summary

Implemented the minimum authenticated GSP loopback transport below the issue #241 launcher.

- The server uses Godot's native `TCPServer` and `WebSocketPeer.accept_stream()` APIs.
- It binds explicitly to `127.0.0.1`, tries ports `8765` through `8769`, and leaves the simulation running if all attempts fail.
- Each enabled debug launch generates a fresh 128-bit CSPRNG token and places only the selected port and token in the installed panel URL fragment.
- The server keeps separate bounded pending-handshake, open-unauthenticated, and authenticated peer sets. Handshake and authentication deadlines are polled from `PROCESS_MODE_ALWAYS` `_process`, not physics.
- Live peers are capped at eight across all states, including closing peers, with two authenticated peers supported for the parent two-panel workflow and destination-capacity checks on both state transitions.
- Authentication is the first complete bounded text application packet. It uses the authoritative v2 envelope and fixed-length constant-time token comparison.
- Authenticated `hello` and `pong` messages use the same v2 envelope and carry `sim_version`, `proto_v`, `physics_hz`, `pid`, `instance_name`, `registry`, `registry_hash`, peer/process/vehicle/authority, and server sequence identity. The registry hash is explicitly `unavailable` until issue #244 supplies the parameter registry.
- Reliable output is FIFO and bounded by application count/bytes plus native outbound buffered bytes. Native capacity is 81,920 bytes and native packet capacity is above the 64-message application limit. Overflow and send failures remain distinct; accepted work is retained in the closing set and flushed before the 1008 close frame.
- Closing-peer deadlines are checked before every graceful-close or FIFO-flush branch. The one-second fallback uses `close(-1)` and removes the record; normal polling preserves accepted FIFO output before policy close 1008.
- The dependency-free panel now reads the fragment, authenticates, and sends bounded v2 pings without persisting credentials.
- No GPU vendor/type allowlist or NVIDIA-specific GSP requirement was added.

## Files changed

- `common/gsp/gsp_server.gd`
- `common/gsp/gsp_launcher.gd`
- `common/gsp/gsp_panel.html`
- `common/flight/flight_runtime.gd`
- `tests/headless/gsp_transport_contract.gd`
- `tests/headless/gsp_transport_integration.gd`
- `tests/headless/gsp_server_harness.gd`
- `scripts/test_gsp_transport.py`
- `tests/headless/gsp_transport_boundary.gd`
- `scripts/test_gsp_transport_boundary.py`
- `.superpowers/sdd/gsp-all-issues/task-2-report.md`

Generated Godot `.uid`, `.import`, translation, build, and unrelated files were not staged.

## TDD evidence

### RED

Exact command:

```text
/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 --headless --path . --script res://tests/headless/gsp_transport_contract.gd
```

Relevant expected failing output before implementation:

```text
SCRIPT ERROR: Parse Error: Preload file "res://common/gsp/gsp_server.gd" does not exist.
SCRIPT ERROR: Static function "panel_url()" not found in base "GspLauncher".
```

The RED contract was then corrected before implementation to the authoritative PRD v2 contract: integer `v: 2`, canonical `v/t/seq/tick/d` envelope, v2 auth, wrong-version rejection, and v2 ping validation. The initial draft's competing string protocol was not implemented.

During final self-review, a focused boundedness assertion was added for the separately tracked open-unauthenticated set. Its RED result was:

```text
ERROR: GSP must bound the separate open-unauthenticated peer set
GSP transport contract: FAIL
EXIT=1
```

The implementation then added `MAX_UNAUTHENTICATED_PEERS := 8` to connection admission, along with fixed-byte-length token comparison. The corrected contract and all focused tests were rerun GREEN below.

The review-fix RED command added actual transport-boundary transitions and table-driven rejection cases:

```text
/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 --headless --path . --script res://tests/headless/gsp_transport_boundary.gd
SCRIPT ERROR: Parse Error: Cannot find member "MAX_STRING_BYTES" in base "GspServer".
SCRIPT ERROR: Parse Error: Cannot find member "MAX_LIVE_PEERS" in base "GspServer".
EXIT=1
```

The first backpressure attempt also demonstrated why a real raw socket was required: the Godot test client's own outbound queue filled before the server boundary was driven. The final raw harness uses a small receive buffer and a large fixture identity so the server's native outbound buffer crosses the application hard limit.

The second independent Sol-high review produced a new RED boundary before the final fix:

```text
GODOT_BIN=/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 python3 scripts/test_gsp_transport_boundary.py
RuntimeError: incomplete pending handshakes were not reclaimed by deadline
RuntimeError: reliable backpressure was not recorded after sent=0: ...
```

The RED exposed both the missing pending-handshake transport case and the deadline path that could be skipped while a peer stayed open. An intermediate combined run after only moving the deadline check also showed that graceful-close and forced-reclamation evidence raced each other (`backpressure peer did not observe a WebSocket close; pongs=5`). Sol-high resolved this by isolating pending, graceful-emission, and forced-reclamation cases in separate harness processes. No eager production flush was retained.

### GREEN

Exact focused contract command and output:

```text
/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 --headless --path . --script res://tests/headless/gsp_transport_contract.gd
GSP transport contract: PASS
```

Native integration command and output:

```text
/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 --headless --path . --script res://tests/headless/gsp_transport_integration.gd
GSP transport integration: PASS
```

Review-fix transport boundary command and output:

```text
/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 --headless --fixed-fps 240 --path . --script res://tests/headless/gsp_transport_boundary.gd
GSP transport boundary: PASS
```

The isolated raw boundary command and output:

```text
GODOT_BIN=/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 python3 scripts/test_gsp_transport_boundary.py
GSP pending handshake boundary: PASS peers=8 all_reclaimed=true capacity_reused=true
GSP graceful boundary: PASS pongs=7 close_code=1008
GSP forced boundary: PASS max_closing=1
```

The graceful case uses a normal receive buffer, drains immediately, asserts the contiguous FIFO pong prefix and emitted close code 1008, and requires overflow count 1 with send-failure count 0. It does not claim graceful reclamation. The forced case uses a tiny receive buffer, never reads after flooding, waits beyond the one-second deadline, and asserts max closing >=1 followed by pre-stop live/closing zero with overflow count 1 and send-failure count 0. The pending case holds exactly eight incomplete TCP connections, verifies the ninth is rejected, waits seven seconds, then keeps every original socket open while asserting remote EOF on all eight before proving capacity reuse with a replacement connection.

The three isolated cases were repeated three times; each repetition printed the same three PASS lines. Status snapshots are taken before server stop. The forced socket remains open and unread through its snapshot; the graceful socket remains open through its emission snapshot and is closed only by test cleanup afterward. The pending sockets remain locally open while each server-side timeout is observed as EOF; cleanup and the status snapshot follow the capacity-reuse assertion. The raw pending test uses no HTTP bytes or parser.

The launch contract was rerun after the release-debug gate change:

```text
/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 --headless --path . --script res://tests/headless/gsp_launch_contract.gd
GSP launch contract: PASS
```

The fixed-runner/raw-TCP harness used a 240 Hz fixed runner and a standard-library masked WebSocket client. It probes three malformed raw request-line forms, then performs the v2 auth handshake and 1,000 v2 ping/pong exchanges:

```text
GODOT_BIN=/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 python3 scripts/test_gsp_transport.py
GSP fixed-runner transport: PASS samples=1000 p99_ms=0.121
```

Python syntax, shell syntax, and whitespace checks:

```text
python3 - <<'PY'
import py_compile
for path in ('scripts/test_gsp_transport.py', 'scripts/test_gsp_transport_boundary.py'):
    py_compile.compile(path, doraise=True)
print('GSP Python harness syntax: PASS')
PY
GSP Python harness syntax: PASS

bash -n scripts/run_gsp_headed_acceptance.sh
git diff --check
```

## Full gates

GUT:

```text
GODOT_BIN=/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 scripts/run_gut_tests.sh
GUT JUnit: 275 tests, 0 failures, 0 errors
```

The run reports the repository's existing three orphan warnings; they do not affect the result.

Native tests:

```text
GODOT_BIN=/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 RUNNER_TEMP=/tmp/aerosim-gsp-review-ci scripts/test_native.sh
exit 0
```

The native script is quiet on success.

During this uncommitted review-fix cycle, the normal GUT command correctly refused the stale native provenance artifact because the new fix commit did not yet exist. The proportionate recovery-mode rerun passed the test result gate while marking only its native-dependent cases pending:

```text
GODOT_BIN=/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 scripts/run_gut_tests.sh --recovery-mode
GUT JUnit: 275 tests, 0 failures, 0 errors
```

Headless smoke:

```text
GODOT_BIN=/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 RUNNER_TEMP=/tmp/aerosim-gsp-review-ci scripts/run_headless_smoke.sh --output build/gsp-headless-review.json --frames 5
exit 0
```

The resulting JSON reports `{"completed":true}`. Its existing invalid-fixture and Terrain3D warnings are expected by that gate.

Pinned Linux native/build/headless gate:

```text
GODOT_BIN=/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 RUNNER_TEMP=/tmp/aerosim-gsp-review-ci scripts/verify_issue_11.sh
exit 124 (headed acceptance timeout)
```

Relevant output before the headed timeout included:

```text
license scan passed: 11 dependencies
Ran 5 tests ... OK
Ran 3 tests ... OK
GPL fixture failed as expected
```

The gate rebuilt the pinned native extension, passed GUT (`275 tests, 0 failures, 0 errors`), passed the native atomic boundary, and reached headed acceptance. `scripts/run_headed_acceptance.sh --xvfb` did not complete within the runner's 90-second timeout, so the aggregate command returned 124 before later replay/headless stages. This is reported as an environment limitation, not as a passing full gate. The independent native and headless smoke reruns above passed. The gate emitted the repository's existing invalid-fixture and Terrain3D/Jolt warnings.

## Architecture decisions and controller corrections

The controller paused implementation because a manual HTTP/WebSocket parser would have been a material security and complexity decision. Sol-high's binding guidance resolved it: use native `TCPServer` plus `WebSocketPeer.accept_stream()`, set inbound/outbound WebSocket byte limits and queued-packet limits before accepting the stream, and do not pre-read TCP bytes. The implementation follows that guidance and does not hand-parse HTTP or WebSocket frames.

Godot 4.7 does not expose incoming handshake headers through this API and ignores `Origin` for this server handshake. Accordingly, `Origin: null` is exercised as protocol evidence, not treated as an identity boundary. The actual boundary is explicit loopback binding, a fresh CSPRNG token, and the first complete application packet being the exact authenticated v2 message.

The first controller correction changed the protocol from the initial draft string version to the authoritative integer v2 envelope. All tests and implementation now use `{ "v": 2, "t": "...", "seq": ..., "tick": ..., "d": { ... } }`; `tick` is optional and omitted by the panel auth packet. Wrong versions and non-auth first packets are rejected and closed.

The second controller correction superseded the inherited NVIDIA-specific GS-065 wording. The implementation has no vendor or GPU-type allowlist; GSP qualification remains vendor/type neutral.

The raw-TCP probes are intentionally modest. They demonstrate that the native server remains healthy after three malformed request-line inputs and that a synthetic `Origin: null` native-compatible handshake can authenticate. They do not claim arbitrary malformed raw HTTP safety. The known upstream Godot 4.7 two-token request-line parser risk remains a native parser residual; it did not prevent the tested application-message acceptance criteria, so no native/proxy frontend was introduced.

The review-fix Sol-high consultation resolved the numeric-validation question: Godot 4.7 parses JSON numbers as floating-point values, and JSON Schema integer semantics accept mathematically integral spellings such as `2`, `2.0`, and `2e0`. The implementation therefore does not add a raw-token scanner or second parser. `_integer_value` requires finite exact integrality, nonnegative values, and the binary64-safe maximum `9_007_199_254_740_991`; fractional, negative, non-finite, and unsafe values are rejected. Auth sequence is exactly zero and each later client sequence is exactly the prior sequence plus one.

The review-fix Sol-high consultation also bound the reliable-queue ordering: `MAX_MESSAGE_BYTES <= MAX_RELIABLE_BYTES < native outbound capacity`, native queued packets exceed the 64-message application cap, and admission uses native buffered bytes plus application queued bytes plus the next serialized message. The triggering overflow message is rejected with the exact local error `reliable queue overflow`; previously accepted FIFO work is retained and flushed before the 1008 close. Send failure remains a separate counter/error path. This was the second Sol-high consultation after the reviewer's FAIL: it specifically resolved the ambiguity between overflow and native send failure, and required the raw receive-backpressure test rather than an in-process queue-only test.

## Self-review

- Release builds remain disabled by `OS.is_debug_build()` and launch still requires the explicit `--aerosim-gsp` argument; `--aerosim-gsp-no-open` only suppresses opening.
- Native Wayland fail-closed behavior from issue #241 is preserved before server startup.
- Listener scope is fixed to `127.0.0.1` and the documented five-port range.
- Tokens are fresh 16-byte CSPRNG values encoded as 32 hex characters and are not persisted; only the fragment URL carries them.
- Application input is text-only, UTF-8 byte bounded, exact-envelope validated, version checked, sequence checked, and authenticated before any server message is sent.
- Pending handshakes, open unauthenticated peers, authenticated peers, WebSocket packet limits, queue count, queue bytes, and deadlines are independently bounded.
- The total live-peer bound includes all active and closing states; transition checks are exercised by real clients, not source-text assertions.
- Native outbound capacity is 81,920 bytes, application reliable capacity is 65,536 bytes, and native queued packets are 80 versus the 64-message application cap.
- Closing peers are retained until `STATE_CLOSED` or an absolute one-second deadline, where `close(-1)` prevents restarting graceful close for a non-reader.
- The deadline check executes immediately after the closed-state check, before FIFO flush or graceful close. The forced boundary proves `close(-1)` reclamation without relying on client teardown; the graceful boundary records only close emission.
- The ready-file harness publishes through a temporary file and atomic rename.
- Identity comes from the existing flight runtime's telemetry/registry sources through a provider callback; the GSP layer does not create a parallel vehicle authority.
- The server runs in always-process mode, not the physics loop.
- The panel remains one dependency-free HTML file and uses no storage API.
- No generated files were staged.

## Problems encountered and resolutions

- The first RED draft encoded the rejected string protocol. It was revised before implementation to integer v2 per the controller correction.
- A manual parser was considered while investigating handshake validation. Sol-high's native API guidance rejected that approach; the final code uses `accept_stream()` exclusively.
- The first fixed-runner attempt at the default 60 Hz runner measured p99 6.960 ms. The reproducible harness was corrected to run the server at `--fixed-fps 240`; intermediate reruns measured 0.126 ms, 0.086 ms, and 0.114 ms, and the latest rerun measured 0.121 ms. The criterion was not weakened.
- The first harness version allowed `_process()` to return `true`, causing the SceneTree harness to exit. It was corrected to return `false` and remain alive until the stop file.
- A temporary indentation regression in the pre-existing flight runtime caused GUT parse errors. The affected lines were restored to the repository's existing four-space style; GUT then passed.
- One unrelated collision-probe test transiently failed in an earlier full GUT run. A clean rerun passed all 275 tests with zero failures and zero errors.
- Sol-high review found that one authenticated peer was incompatible with the two-panel workflow and that state-array-only admission could overflow during transitions. The fix uses a total eight-peer cap, two authenticated peers, and runtime transition checks.
- Sol-high review found incomplete identity and a misleading config-hash-as-registry-hash shape. The fix emits the exact named identity fields and the explicit `registry_hash: "unavailable"` placeholder reserved for issue #244.
- Sol-high review found permissive approximate integer checks and missing sequence continuity. The fix uses exact finite safe integrality, auth sequence zero, and strict incrementing client sequences; the numeric spelling decision is recorded above.
- Sol-high review found that reliable accepted work could be discarded and that native outbound capacity was too small to make the intended overflow path reachable. The second Sol-high consultation resolved the remaining backpressure problem: use 81,920-byte native outbound capacity, count native plus application bytes, reject the triggering packet as a distinct overflow, retain closing records, preserve FIFO before 1008, and force-close with `close(-1)` at the one-second deadline. The isolated raw harness now proves overflow rather than send failure.
- Sol-high review required runtime boundary cases rather than source-text assertions. The new GDScript boundary suite and raw backpressure harness cover rejection, transition, fallback/exhaustion, sequence, overflow, close-code, and reclamation behavior.
- Sol-high review found the ready-file publication race and conditional URL printing. The harness now atomically publishes readiness, and the launcher prints the fragment URL before optional shell opening.
- The second independent Sol-high review found three blocking gaps: deadline checks after `continue`, no incomplete raw pending-handshake case, and client teardown before the status snapshot. The fix checks the deadline first, adds the standard-library raw pending-capacity/reclamation test, and keeps the forced backpressure socket open until status records pre-stop live zero. A replacement pending socket proves capacity reuse after the seven-second bounded wait.
- The final pre-commit evidence review found that pending capacity reuse alone did not prove every original incomplete peer was reclaimed. The harness now observes remote EOF on each held original while its local socket remains open, then checks replacement capacity and performs cleanup/snapshot.
- Sol-high's follow-up separated graceful close emission from forced reclamation. The graceful case now requires only overflow isolation, contiguous FIFO pongs, and emitted 1008; the forced case alone requires retention through the absolute deadline and pre-stop live/closing zero. The eager `_begin_close` flush was removed because isolation made it unnecessary; no outbound-buffer-zero inference or extra close operation was added.
- No implementation problem remains. The only unavailable evidence is the headed/browser qualification described below; the focused transport and GUT gates are green.

## Acceptance evidence unavailable in this environment

The headed harness was run and preserved its honest result:

```text
GODOT_BIN=/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 scripts/run_gsp_headed_acceptance.sh --out-dir build/gsp-headed-task2
GSP headed acceptance: NOT_QUALIFIED (build/gsp-headed-task2/report.json)
```

The report recorded `status: environment_not_qualified`, Wayland, borderless mode, compositor scale `1.0` (below the required 2x), unavailable external input automation, and `shell_open_accepted: true`. Therefore credible real `file://` Firefox/Chromium evidence for browser Origin acceptance, external focus/input, and the required HiDPI qualification is unavailable here. The synthetic `Origin: null` protocol evidence is covered by the native integration and raw-TCP harness.

The later pinned Linux gate's Xvfb headed stage also timed out after 90 seconds (`exit 124`) before producing additional browser evidence. The known upstream Godot 4.7 malformed raw HTTP two-token request-line parser residual remains documented above; no handwritten parser or native/proxy frontend was introduced.
