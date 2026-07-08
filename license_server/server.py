import argparse
import base64
import hashlib
import hmac
import json
import os
import sqlite3
import sys
import time
import uuid
from http.server import BaseHTTPRequestHandler, HTTPServer


def _b64url(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def _unb64url(data):
    return base64.urlsafe_b64decode(data + "=" * (-len(data) % 4))


def sign_jwt(claims, secret):
    header = {"alg": "HS256", "typ": "JWT"}
    parts = [
        _b64url(json.dumps(header, separators=(",", ":")).encode()),
        _b64url(json.dumps(claims, separators=(",", ":")).encode()),
    ]
    signing_input = ".".join(parts).encode()
    signature = hmac.new(secret.encode(), signing_input, hashlib.sha256).digest()
    return ".".join(parts + [_b64url(signature)])


def read_jwt(token, secret):
    header, payload, signature = token.split(".")
    signing_input = f"{header}.{payload}".encode()
    expected = hmac.new(secret.encode(), signing_input, hashlib.sha256).digest()
    if not hmac.compare_digest(_unb64url(signature), expected):
        raise ValueError("bad signature")
    header_claims = json.loads(_unb64url(header))
    claims = json.loads(_unb64url(payload))
    if header_claims != {"alg": "HS256", "typ": "JWT"}:
        raise ValueError("unsupported token header")
    if claims.get("iss") != "aerosim-license-server":
        raise ValueError("bad issuer")
    if claims.get("aud") != "aerosim-client":
        raise ValueError("bad audience")
    return claims


def offline_grace_valid(token, secret, now):
    try:
        claims = read_jwt(token, secret)
        return int(now) <= int(claims["offline_grace_until"])
    except (KeyError, TypeError, ValueError, json.JSONDecodeError):
        return False


class Store:
    def __init__(self, db_path):
        self.db = sqlite3.connect(db_path, check_same_thread=False)
        self.db.execute(
            """
            CREATE TABLE IF NOT EXISTS licenses (
                license_key TEXT PRIMARY KEY,
                customer_id TEXT NOT NULL,
                revoked INTEGER NOT NULL DEFAULT 0
            )
            """
        )

    def register(self, customer_id):
        license_key = "lic_" + uuid.uuid4().hex
        self.db.execute(
            "INSERT INTO licenses (license_key, customer_id) VALUES (?, ?)",
            (license_key, customer_id),
        )
        self.db.commit()
        return license_key

    def get(self, license_key):
        row = self.db.execute(
            "SELECT customer_id, revoked FROM licenses WHERE license_key = ?",
            (license_key,),
        ).fetchone()
        if row is None:
            return None
        return {"customer_id": row[0], "revoked": bool(row[1])}

    def revoke(self, license_key):
        cursor = self.db.execute(
            "UPDATE licenses SET revoked = 1 WHERE license_key = ?",
            (license_key,),
        )
        self.db.commit()
        return cursor.rowcount > 0


class LicenseServer(HTTPServer):
    def __init__(self, address, secret, clock, db_path):
        super().__init__(address, Handler)
        self.secret = secret
        self.clock = clock
        self.store = Store(db_path)

    def token_for(self, license_key, device_id):
        now = int(self.clock())
        license_record = self.store.get(license_key)
        if license_record is None:
            raise ValueError("unknown_license")
        return sign_jwt(
            {
                "iss": "aerosim-license-server",
                "aud": "aerosim-client",
                "sub": license_key,
                "customer_id": license_record["customer_id"],
                "device_id": device_id,
                "iat": now,
                "online_verified_at": now,
                "offline_grace_until": now + 72 * 60 * 60,
            },
            self.secret,
        )


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        routes = {
            "/register": self.register,
            "/issue": self.issue,
            "/verify": self.verify,
            "/revoke": self.revoke,
        }
        handler = routes.get(self.path)
        if handler is None:
            self.send_json(404, {"error": "not_found"})
            return
        try:
            handler(self.read_json())
        except (KeyError, json.JSONDecodeError):
            self.send_json(400, {"error": "bad_request"})
        except ValueError as error:
            self.send_json(404, {"error": str(error)})

    def register(self, body):
        license_key = self.server.store.register(body["customer_id"])
        self.send_json(201, {"license_key": license_key, "status": "active"})

    def issue(self, body):
        license_record = self.server.store.get(body["license_key"])
        if license_record is None:
            raise ValueError("unknown_license")
        if license_record["revoked"]:
            self.send_json(403, {"error": "revoked"})
            return
        token = self.server.token_for(body["license_key"], body.get("device_id", ""))
        self.send_json(200, {"token": token})

    def verify(self, body):
        try:
            claims = read_jwt(body["token"], self.server.secret)
        except ValueError:
            self.send_json(401, {"valid": False, "error": "invalid_token"})
            return
        license_record = self.server.store.get(claims["sub"])
        if license_record is None:
            raise ValueError("unknown_license")
        if license_record["revoked"]:
            self.send_json(403, {"valid": False, "error": "revoked"})
            return
        token = self.server.token_for(claims["sub"], claims.get("device_id", ""))
        self.send_json(200, {"valid": True, "token": token})

    def revoke(self, body):
        if not self.server.store.revoke(body["license_key"]):
            raise ValueError("unknown_license")
        self.send_json(200, {"revoked": True})

    def read_json(self):
        length = int(self.headers.get("Content-Length", "0"))
        return json.loads(self.rfile.read(length) or b"{}")

    def send_json(self, status, body):
        payload = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, format, *args):
        return


def make_server(address, secret, clock=time.time, db_path=":memory:"):
    return LicenseServer(address, secret, clock, db_path)


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", default=8080, type=int)
    parser.add_argument("--db", default="license_server.sqlite3")
    parser.add_argument("--secret-file")
    args = parser.parse_args(argv)

    secret = os.environ.get("AEROSIM_LICENSE_SECRET")
    if args.secret_file:
        with open(args.secret_file, encoding="utf-8") as file:
            secret = file.read().strip()
    if not secret:
        print("AEROSIM_LICENSE_SECRET or --secret-file is required", file=sys.stderr)
        return 2

    server = make_server((args.host, args.port), secret=secret, db_path=args.db)
    host, port = server.server_address
    print(f"serving on http://{host}:{port}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        return 130
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
