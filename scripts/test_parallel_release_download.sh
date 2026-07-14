#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_dir="$(mktemp -d)"
server_info="$test_dir/server-info"
fixture="$test_dir/fixture.bin"
output="$test_dir/output.bin"
server_pid=""

cleanup() {
    if [[ -n "$server_pid" ]]; then
        kill "$server_pid" 2>/dev/null || true
        wait "$server_pid" 2>/dev/null || true
    fi
    rm -rf "$test_dir"
}
trap cleanup EXIT

dd if=/dev/zero of="$fixture" bs=1M count=1 status=none

python3 - "$fixture" >"$server_info" <<'PY' &
import http.server
import pathlib
import re
import sys

fixture = pathlib.Path(sys.argv[1]).read_bytes()


class Handler(http.server.BaseHTTPRequestHandler):
    def _send_headers(self, status, start, end):
        self.send_response(status)
        self.send_header("Content-Length", str(end - start + 1))
        self.send_header("Accept-Ranges", "bytes")
        if status == 206:
            self.send_header("Content-Range", f"bytes {start}-{end}/{len(fixture)}")
        self.end_headers()

    def do_HEAD(self):
        self._send_headers(200, 0, len(fixture) - 1)

    def do_GET(self):
        match = re.fullmatch(r"bytes=(\d+)-(\d*)", self.headers.get("Range", ""))
        if match:
            start = int(match.group(1))
            end = int(match.group(2) or len(fixture) - 1)
            end = min(end, len(fixture) - 1)
            self._send_headers(206, start, end)
            self.wfile.write(fixture[start:end + 1])
            return
        self._send_headers(200, 0, len(fixture) - 1)
        self.wfile.write(fixture)

    def log_message(self, *_args):
        pass


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
print(server.server_address[1], flush=True)
server.serve_forever()
PY
server_pid=$!

for _ in {1..50}; do
    if [[ -s "$server_info" ]]; then
        break
    fi
    sleep 0.1
done
port="$(<"$server_info")"
sha512="$(sha512sum "$fixture" | awk '{print $1}')"

AEROSIM_DOWNLOAD_CHUNK_SIZE=262144 \
    AEROSIM_DOWNLOAD_PARALLELISM=4 \
    "$root_dir/scripts/download_release_asset.sh" \
    "http://127.0.0.1:$port/asset" "$output" "$sha512"
cmp "$fixture" "$output"
