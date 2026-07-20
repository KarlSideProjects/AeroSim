#!/usr/bin/env bash
set -euo pipefail
umask 077

usage() {
    echo "usage: $0 [--customer-id ID] [--kid ID] [--port PORT]" >&2
}

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
output_dir="$repo_root/build/devm-license-fixture"
customer_id="devm-customer"
kid="ubuntu-devm-2026"
port=""
license_python="${AEROSIM_LICENSE_PYTHON:-$repo_root/build/license-venv/bin/python}"

while [ "$#" -gt 0 ]; do
    case "$1" in
        --customer-id)
            customer_id="${2:-}"
            shift 2
            ;;
        --kid)
            kid="${2:-}"
            shift 2
            ;;
        --port)
            port="${2:-}"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            usage
            exit 2
            ;;
    esac
done

if [ -z "$customer_id" ] || [ -z "$kid" ]; then
    usage
    exit 2
fi
if [[ ! "$kid" =~ ^[A-Za-z0-9._-]{1,64}$ ]]; then
    echo "invalid kid: use 1-64 letters, digits, '.', '_' or '-'" >&2
    exit 2
fi
if [ ! -x "$license_python" ]; then
    echo "missing locked license Python: $license_python (run scripts/test_license_dependencies.sh first)" >&2
    exit 1
fi
if ! command -v openssl >/dev/null 2>&1; then
    echo "missing required command: openssl" >&2
    exit 1
fi

if [ -z "$port" ]; then
    port="$(python3 - <<'PY'
import socket

with socket.socket() as sock:
    sock.bind(("127.0.0.1", 0))
    print(sock.getsockname()[1])
PY
)"
fi
if [[ ! "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
    echo "invalid port: $port" >&2
    exit 2
fi

mkdir -p "$output_dir"
output_dir="$(cd "$output_dir" && pwd -P)"
if find "$output_dir" -mindepth 1 -maxdepth 1 -print -quit | grep -q .; then
    echo "output directory is not empty: $output_dir" >&2
    echo "remove it explicitly before generating a new fixture" >&2
    exit 1
fi
chmod 700 "$output_dir"

private_key="$output_dir/private_key.pem"
public_key="$output_dir/public_key.pem"
database="$output_dir/licenses.sqlite3"
license_file="$output_dir/license.key"
config_file="$output_dir/license_provider.json"
server_script="$output_dir/start_server.sh"

openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$private_key" >/dev/null 2>&1
openssl pkey -in "$private_key" -pubout -out "$public_key" >/dev/null 2>&1
chmod 600 "$private_key"
chmod 644 "$public_key"

PYTHONPATH="$repo_root" "$license_python" -m license_server.admin \
    --db "$database" register \
    --customer-id "$customer_id" \
    --output "$license_file" \
    >"$output_dir/register.json"
chmod 600 "$database" "$license_file" "$output_dir/register.json"

python3 - "$config_file" "$public_key" "$port" "$kid" <<'PY'
import json
import sys
from pathlib import Path

config_path, public_key, port, kid = sys.argv[1:]
Path(config_path).write_text(
    json.dumps(
        {
            "schema_version": 1,
            "issue_endpoint": f"http://127.0.0.1:{port}/issue",
            "verify_endpoint": f"http://127.0.0.1:{port}/verify",
            "public_key_path": public_key,
            "allowed_kids": [kid],
            "state_path": "user://aerosim-license-devm.json",
        },
        indent=2,
    )
    + "\n",
    encoding="utf-8",
)
PY
chmod 600 "$config_file"

cat >"$server_script" <<EOF
#!/usr/bin/env bash
set -euo pipefail
exec "$license_python" -m license_server.server \\
    --host 127.0.0.1 \\
    --port "$port" \\
    --db "$database" \\
    --private-key "$private_key" \\
    --kid "$kid" \\
    --allowed-kid "$kid"
EOF
chmod 700 "$server_script"

echo "DEV-M license fixture created: $output_dir"
echo "start server: $server_script"
echo "provider config: $config_file"
echo "license key file: $license_file (not printed)"
