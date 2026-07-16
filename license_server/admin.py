import argparse
import json

from .server import admin_register, admin_revoke


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("--db", default="license_server.sqlite3")
    commands = parser.add_subparsers(dest="command", required=True)

    register = commands.add_parser("register")
    register.add_argument("--customer-id", required=True)
    revoke = commands.add_parser("revoke")
    revoke.add_argument("--license-key", required=True)
    args = parser.parse_args(argv)

    if args.command == "register":
        print(json.dumps({"license_key": admin_register(args.db, args.customer_id), "status": "active"}))
        return 0
    if admin_revoke(args.db, args.license_key):
        print(json.dumps({"revoked": True}))
        return 0
    print(json.dumps({"error": "unknown_license"}))
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
