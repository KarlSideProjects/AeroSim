import argparse
import json
import os
import stat
import sys

from .server import admin_register, admin_revoke


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("--db", default="license_server.sqlite3")
    commands = parser.add_subparsers(dest="command", required=True)

    register = commands.add_parser("register")
    register.add_argument("--customer-id", required=True)
    register.add_argument("--output", required=True)
    revoke = commands.add_parser("revoke")
    args = parser.parse_args(argv)

    if args.command == "register":
        license_key = admin_register(args.db, args.customer_id)
        output_path = os.path.abspath(args.output)
        descriptor = os.open(
            output_path,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL,
            stat.S_IRUSR | stat.S_IWUSR,
        )
        with os.fdopen(descriptor, "w", encoding="utf-8") as output:
            output.write(license_key)
        print(json.dumps({"status": "active"}))
        return 0
    license_key = sys.stdin.read().strip()
    if not license_key:
        print(json.dumps({"error": "license_key_required"}))
        return 2
    if admin_revoke(args.db, license_key):
        print(json.dumps({"revoked": True}))
        return 0
    print(json.dumps({"error": "unknown_license"}))
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
