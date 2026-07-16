#!/usr/bin/env bash
set -euo pipefail

usage() {
    echo "usage: $0 --customer-id ID --device-id ID --artifact PATH [--report PATH]" >&2
}

customer_id=""
device_id=""
artifact=""
report_path="build/delivery_drill/report.json"
license_python="${AEROSIM_LICENSE_PYTHON:-build/license-venv/bin/python}"

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
if [ ! -x "$license_python" ]; then
    echo "missing locked license Python: $license_python (run scripts/test_license_dependencies.sh first)" >&2
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
private_key_path="$tmp_dir/license-signing-key.pem"
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$private_key_path" >/dev/null 2>&1
"$license_python" -m license_server.admin \
    --db "$tmp_dir/licenses.sqlite3" register \
    --customer-id "$customer_id" --output "$tmp_dir/license.key" \
    >"$tmp_dir/register.json"
"$license_python" -m license_server.server --host 127.0.0.1 --port "$port" --db "$tmp_dir/licenses.sqlite3" \
    --private-key "$private_key_path" --kid ubuntu-2026 --allowed-kid ubuntu-2026 \
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
python3 - "http://127.0.0.1:$port" "$customer_id" "$device_id" "$artifact" "$artifact_sha256" "$tmp_dir/license.key" "$tmp_dir/register.json" "$tmp_dir/token" <<'PY'
import json
from pathlib import Path
import sys
from urllib import request
from urllib.error import HTTPError

base_url, customer_id, device_id, artifact, artifact_sha256, key_path, register_path, token_path = sys.argv[1:]


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
license_key = Path(key_path).read_text(encoding="utf-8").strip()
registered = json.loads(Path(register_path).read_text(encoding="utf-8"))
if registered.get("status") != "active" or not license_key:
    raise SystemExit("customer registration failed")
steps.append("customer_registered")

status, issued = post("/issue", {"license_key": license_key})
if status != 200 or not issued.get("token"):
    raise SystemExit("license activation failed")
token = issued["token"]
Path(token_path).write_text(token, encoding="utf-8")
steps.append("license_issued")

status, verified = post("/verify", {"token": token})
if status != 200 or not verified.get("valid"):
    raise SystemExit("online activation verification failed")
steps.append("activation_verified")
PY

"$license_python" -m license_server.admin --db "$tmp_dir/licenses.sqlite3" revoke \
    <"$tmp_dir/license.key" >"$tmp_dir/revoke.json"

python3 - "http://127.0.0.1:$port" "$customer_id" "$device_id" "$artifact" "$artifact_sha256" "$report_path" "$tmp_dir/token" "$tmp_dir/revoke.json" <<'PY'
import json
from pathlib import Path
import sys
from urllib import request
from urllib.error import HTTPError

base_url, customer_id, device_id, artifact, artifact_sha256, report_path, token_path, revoke_path = sys.argv[1:]


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


steps = ["customer_registered", "license_issued", "activation_verified"]
token = Path(token_path).read_text(encoding="utf-8").strip()
revoked = json.loads(Path(revoke_path).read_text(encoding="utf-8"))
if not revoked.get("revoked"):
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
