# AeroSim Task 2 / Issue #242 report

## Implementation summary

Implemented the minimum authenticated GSP loopback transport below the issue #241 launcher.

- The server uses Godot's native `TCPServer` and `WebSocketPeer.accept_stream()` APIs.
- It binds explicitly to `127.0.0.1`, tries ports `8765` through `8769`, and leaves the simulation running if all attempts fail.
- Each enabled debug launch generates a fresh 128-bit CSPRNG token and places only the selected port and token in the installed panel URL fragment.
- The server keeps separate bounded pending-handshake, open-unauthenticated, and authenticated peer sets. Handshake and authentication deadlines are polled from `PROCESS_MODE_ALWAYS` `_process`, not physics.
- Authentication is the first complete bounded text application packet. It uses the authoritative v2 envelope and fixed-length constant-time token comparison.
- Authenticated `hello` and `pong` messages use the same v2 envelope and carry the canonical vehicle/authority/registry identity snapshot. Pong echoes the client request data, including its timestamp/request fields.
- Reliable output is FIFO and bounded by both message count and serialized byte size. Overflow and send failures are recorded locally and close the peer.
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

The launch contract was rerun after the release-debug gate change:

```text
/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 --headless --path . --script res://tests/headless/gsp_launch_contract.gd
GSP launch contract: PASS
```

The fixed-runner/raw-TCP harness used a 240 Hz fixed runner and a standard-library masked WebSocket client. It probes three malformed raw request-line forms, then performs the v2 auth handshake and 1,000 v2 ping/pong exchanges:

```text
GODOT_BIN=/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 python3 scripts/test_gsp_transport.py
GSP fixed-runner transport: PASS samples=1000 p99_ms=0.107
```

Python syntax, shell syntax, and whitespace checks:

```text
python3 - <<'PY'
import py_compile
py_compile.compile('scripts/test_gsp_transport.py', doraise=True)
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
scripts/test_native.sh
exit 0
```

The native script is quiet on success.

Headless smoke:

```text
GODOT_BIN=/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 scripts/run_headless_smoke.sh --output build/gsp-headless-smoke-task2.json --frames 5
exit 0
```

The resulting JSON reports `{"completed":true}`. Its existing invalid-fixture and Terrain3D warnings are expected by that gate.

Pinned Linux native/build/headless gate:

```text
GODOT_BIN=/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 RUNNER_TEMP=/tmp/aerosim-gsp-ci-task2 scripts/verify_issue_11.sh
exit 0
```

Relevant passing output included:

```text
license scan passed: 11 dependencies
Ran 5 tests ... OK
Ran 3 tests ... OK
GPL fixture failed as expected
```

The gate also rebuilt the pinned native extension and completed its headless smoke path. It emitted the repository's existing invalid-fixture and Terrain3D/Jolt warnings while still returning exit 0.

## Architecture decisions and controller corrections

The controller paused implementation because a manual HTTP/WebSocket parser would have been a material security and complexity decision. Sol-high's binding guidance resolved it: use native `TCPServer` plus `WebSocketPeer.accept_stream()`, set inbound/outbound WebSocket byte limits and queued-packet limits before accepting the stream, and do not pre-read TCP bytes. The implementation follows that guidance and does not hand-parse HTTP or WebSocket frames.

Godot 4.7 does not expose incoming handshake headers through this API and ignores `Origin` for this server handshake. Accordingly, `Origin: null` is exercised as protocol evidence, not treated as an identity boundary. The actual boundary is explicit loopback binding, a fresh CSPRNG token, and the first complete application packet being the exact authenticated v2 message.

The first controller correction changed the protocol from the initial draft string version to the authoritative integer v2 envelope. All tests and implementation now use `{ "v": 2, "t": "...", "seq": ..., "tick": ..., "d": { ... } }`; `tick` is optional and omitted by the panel auth packet. Wrong versions and non-auth first packets are rejected and closed.

The second controller correction superseded the inherited NVIDIA-specific GS-065 wording. The implementation has no vendor or GPU-type allowlist; GSP qualification remains vendor/type neutral.

The raw-TCP probes are intentionally modest. They demonstrate that the native server remains healthy after three malformed request-line inputs and that a synthetic `Origin: null` native-compatible handshake can authenticate. They do not claim arbitrary malformed raw HTTP safety. The known upstream Godot 4.7 two-token request-line parser risk remains a native parser residual; it did not prevent the tested application-message acceptance criteria, so no native/proxy frontend was introduced.

## Self-review

- Release builds remain disabled by `OS.is_debug_build()` and launch still requires the explicit `--aerosim-gsp` argument; `--aerosim-gsp-no-open` only suppresses opening.
- Native Wayland fail-closed behavior from issue #241 is preserved before server startup.
- Listener scope is fixed to `127.0.0.1` and the documented five-port range.
- Tokens are fresh 16-byte CSPRNG values encoded as 32 hex characters and are not persisted; only the fragment URL carries them.
- Application input is text-only, UTF-8 byte bounded, exact-envelope validated, version checked, sequence checked, and authenticated before any server message is sent.
- Pending handshakes, open unauthenticated peers, authenticated peers, WebSocket packet limits, queue count, queue bytes, and deadlines are independently bounded.
- Identity comes from the existing flight runtime's telemetry/registry sources through a provider callback; the GSP layer does not create a parallel vehicle authority.
- The server runs in always-process mode, not the physics loop.
- The panel remains one dependency-free HTML file and uses no storage API.
- No generated files were staged.

## Problems encountered and resolutions

- The first RED draft encoded the rejected string protocol. It was revised before implementation to integer v2 per the controller correction.
- A manual parser was considered while investigating handshake validation. Sol-high's native API guidance rejected that approach; the final code uses `accept_stream()` exclusively.
- The first fixed-runner attempt at the default 60 Hz runner measured p99 6.960 ms. The reproducible harness was corrected to run the server at `--fixed-fps 240`; the resulting p99 was 0.126 ms. The criterion was not weakened.
- The first harness version allowed `_process()` to return `true`, causing the SceneTree harness to exit. It was corrected to return `false` and remain alive until the stop file.
- A temporary indentation regression in the pre-existing flight runtime caused GUT parse errors. The affected lines were restored to the repository's existing four-space style; GUT then passed.
- One unrelated collision-probe test transiently failed in an earlier full GUT run. A clean rerun passed all 275 tests with zero failures and zero errors.
- No implementation problem remains.

## Acceptance evidence unavailable in this environment

The headed harness was run and preserved its honest result:

```text
GODOT_BIN=/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64 scripts/run_gsp_headed_acceptance.sh --out-dir build/gsp-headed-task2
GSP headed acceptance: NOT_QUALIFIED (build/gsp-headed-task2/report.json)
```

The report recorded `status: environment_not_qualified`, Wayland, borderless mode, compositor scale `1.0` (below the required 2x), unavailable external input automation, and `shell_open_accepted: true`. Therefore credible real `file://` Firefox/Chromium evidence for browser Origin acceptance, external focus/input, and the required HiDPI qualification is unavailable here. The synthetic `Origin: null` protocol evidence is covered by the native integration and raw-TCP harness.
