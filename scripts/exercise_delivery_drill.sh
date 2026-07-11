#!/usr/bin/env bash
set -euo pipefail

usage() {
    echo "usage: $0 --customer-id ID --device-id ID --artifact PATH [--report PATH]" >&2
}

customer_id=""
device_id=""
artifact=""
report_path="build/delivery_drill/report.json"

while [ "$#" -gt 0 ]; do
    case "$1" in
        --customer-id)
            customer_id="${2:-}"
            shift 2
            ;;
        --device-id)
            device_id="${2:-}"
            shift 2
            ;;
        --artifact)
            artifact="${2:-}"
            shift 2
            ;;
        --report)
            report_path="${2:-}"
            shift 2
            ;;
        *)
            usage
            exit 2
            ;;
    esac
done

if [ -z "$customer_id" ] || [ -z "$device_id" ] || [ -z "$artifact" ]; then
    usage
    exit 2
fi
if [ ! -f "$artifact" ]; then
    echo "missing delivery artifact: $artifact" >&2
    exit 1
fi
python3 scripts/check_release_artifacts.py "$artifact"

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/aerosim-delivery-drill.XXXXXX")"
server_pid=""
cleanup() {
    if [ -n "$server_pid" ]; then
        kill "$server_pid" 2>/dev/null || true
        wait "$server_pid" 2>/dev/null || true
    fi
    rm -rf "$tmp_dir"
}
trap cleanup EXIT

port="$(python3 - <<'PY'
import socket
with socket.socket() as sock:
    sock.bind(("127.0.0.1", 0))
    print(sock.getsockname()[1])
PY
)"
secret="$(python3 - <<'PY'
import secrets
print(secrets.token_hex(32))
PY
)"
AEROSIM_LICENSE_SECRET="$secret" \
python3 -m license_server.server --host 127.0.0.1 --port "$port" --db "$tmp_dir/licenses.sqlite3" \
    >"$tmp_dir/server.log" 2>&1 &
server_pid="$!"

for _ in $(seq 1 100); do
    if grep -q "serving on http://127.0.0.1:$port" "$tmp_dir/server.log"; then
        break
    fi
    if ! kill -0 "$server_pid" 2>/dev/null; then
        cat "$tmp_dir/server.log" >&2
        exit 1
    fi
    sleep 0.05
done
if ! grep -q "serving on http://127.0.0.1:$port" "$tmp_dir/server.log"; then
    echo "license server did not become ready" >&2
    exit 1
fi

mkdir -p "$(dirname "$report_path")"
artifact_sha256="$(sha256sum "$artifact" | awk '{print $1}')"
python3 - "http://127.0.0.1:$port" "$customer_id" "$device_id" "$artifact" "$artifact_sha256" "$report_path" <<'PY'
import json
from pathlib import Path
import sys
from urllib import request
from urllib.error import HTTPError

base_url, customer_id, device_id, artifact, artifact_sha256, report_path = sys.argv[1:]


def post(path, payload):
    req = request.Request(
        base_url + path,
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with request.urlopen(req) as response:
            return response.status, json.loads(response.read())
    except HTTPError as error:
        with error:
            return error.status, json.loads(error.read())


steps = []
status, registered = post("/register", {"customer_id": customer_id, "device_id": device_id})
if status != 201 or registered.get("status") != "active":
    raise SystemExit("customer registration failed")
license_key = registered["license_key"]
steps.append("customer_registered")

status, issued = post("/issue", {"license_key": license_key, "device_id": device_id})
if status != 200 or not issued.get("token"):
    raise SystemExit("license activation failed")
token = issued["token"]
steps.append("license_issued")

status, verified = post("/verify", {"token": token})
if status != 200 or not verified.get("valid"):
    raise SystemExit("online activation verification failed")
steps.append("activation_verified")

status, revoked = post("/revoke", {"license_key": license_key})
if status != 200 or not revoked.get("revoked"):
    raise SystemExit("license revocation failed")
steps.append("license_revoked")

status, rejected = post("/verify", {"token": token})
if status != 403 or rejected.get("error") != "revoked":
    raise SystemExit("revoked license was accepted")
steps.append("revocation_verified")

report = {
    "artifact": artifact,
    "artifact_sha256": artifact_sha256,
    "customer_id": customer_id,
    "device_id": device_id,
    "steps": steps,
    "delivery_channel": "not_exercised",
}
Path(report_path).write_text(json.dumps(report, sort_keys=True) + "\n", encoding="utf-8")
PY

echo "Delivery drill completed; report: $report_path"
echo "External artifact/key delivery is not exercised by this local rehearsal."
