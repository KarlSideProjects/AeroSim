import argparse
import ipaddress
import json
import re
import sqlite3
import sys
import time
import uuid
from http.server import BaseHTTPRequestHandler, HTTPServer

import jwt
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import rsa


MAX_BODY_BYTES = 16 * 1024
TOKEN_TTL_SECONDS = 72 * 60 * 60
ISSUER = "urn:aerosim:license-server"
AUDIENCE = "urn:aerosim:ubuntu-client"
JWT_HEADER = {"alg": "RS256", "typ": "aerosim-license+jwt"}
CLAIMS = {"iss", "aud", "sub", "jti", "iat", "exp"}
KID_RE = re.compile(r"[A-Za-z0-9._-]{1,64}\Z")


def _load_private_key(path):
    try:
        with open(path, "rb") as key_file:
            key_bytes = key_file.read()
        key = serialization.load_pem_private_key(key_bytes, password=None)
    except (OSError, TypeError, ValueError) as error:
        raise ValueError("invalid signing key") from error
    if not isinstance(key, rsa.RSAPrivateKey) or key.key_size < 2048:
        raise ValueError("invalid signing key")
    return key


def _allowed_kids(kids):
    try:
        result = frozenset(kids)
    except TypeError as error:
        raise ValueError("kid allowlist is required") from error
    if not result or any(not isinstance(kid, str) or not KID_RE.fullmatch(kid) for kid in result):
        raise ValueError("kid allowlist is required")
    return result


def _uuid_claim(value):
    try:
        parsed = uuid.UUID(value)
    except (AttributeError, TypeError, ValueError) as error:
        raise ValueError("invalid token") from error
    if str(parsed) != value:
        raise ValueError("invalid token")


def sign_jwt(claims, private_key, kid):
    return jwt.encode(
        claims,
        private_key,
        algorithm="RS256",
        headers={"typ": JWT_HEADER["typ"], "kid": kid},
    )


def read_jwt(token, private_key, allowed_kids, now=None, active_kid=None):
    try:
        header = jwt.get_unverified_header(token)
        if set(header) != {"alg", "typ", "kid"}:
            raise ValueError("invalid token")
        if header["alg"] != JWT_HEADER["alg"] or header["typ"] != JWT_HEADER["typ"]:
            raise ValueError("invalid token")
        allowed_kids = _allowed_kids(allowed_kids)
        if header["kid"] not in allowed_kids or (active_kid is not None and header["kid"] != active_kid):
            raise ValueError("invalid token")
        claims = jwt.decode(
            token,
            private_key.public_key() if isinstance(private_key, rsa.RSAPrivateKey) else private_key,
            algorithms=["RS256"],
            issuer=ISSUER,
            audience=AUDIENCE,
            options={"verify_exp": False, "verify_iat": False},
        )
        if set(claims) != CLAIMS:
            raise ValueError("invalid token")
        if not isinstance(claims["iat"], int) or isinstance(claims["iat"], bool):
            raise ValueError("invalid token")
        if not isinstance(claims["exp"], int) or isinstance(claims["exp"], bool):
            raise ValueError("invalid token")
        if claims["exp"] - claims["iat"] != TOKEN_TTL_SECONDS:
            raise ValueError("invalid token")
        _uuid_claim(claims["sub"])
        _uuid_claim(claims["jti"])
        current_time = int(time.time() if now is None else now)
        if claims["iat"] > current_time + 300 or current_time >= claims["exp"]:
            raise ValueError("invalid token")
        return claims
    except (jwt.InvalidTokenError, KeyError, TypeError, ValueError, json.JSONDecodeError) as error:
        raise ValueError("invalid token") from error


class Store:
    def __init__(self, db_path):
        self.db = sqlite3.connect(db_path, check_same_thread=False)
        self.db.execute(
            """
            CREATE TABLE IF NOT EXISTS licenses (
                license_key TEXT PRIMARY KEY,
                customer_id TEXT NOT NULL,
                subject_id TEXT NOT NULL,
                revoked INTEGER NOT NULL DEFAULT 0
            )
            """
        )
        columns = {row[1] for row in self.db.execute("PRAGMA table_info(licenses)")}
        if "subject_id" not in columns:
            self.db.execute("ALTER TABLE licenses ADD COLUMN subject_id TEXT")
            for license_key, in self.db.execute(
                "SELECT license_key FROM licenses WHERE subject_id IS NULL"
            ).fetchall():
                self.db.execute(
                    "UPDATE licenses SET subject_id = ? WHERE license_key = ?",
                    (str(uuid.uuid4()), license_key),
                )
            self.db.commit()
        self.db.execute(
            "CREATE UNIQUE INDEX IF NOT EXISTS licenses_subject_id ON licenses(subject_id)"
        )

    def close(self):
        self.db.close()

    def register(self, customer_id):
        if not isinstance(customer_id, str) or not customer_id:
            raise ValueError("customer_id is required")
        license_key = "lic_" + uuid.uuid4().hex
        self.db.execute(
            "INSERT INTO licenses (license_key, customer_id, subject_id) VALUES (?, ?, ?)",
            (license_key, customer_id, str(uuid.uuid4())),
        )
        self.db.commit()
        return license_key

    def get(self, license_key):
        row = self.db.execute(
            "SELECT customer_id, subject_id, revoked FROM licenses WHERE license_key = ?",
            (license_key,),
        ).fetchone()
        if row is None:
            return None
        return {"customer_id": row[0], "subject_id": row[1], "revoked": bool(row[2])}

    def get_by_subject(self, subject_id):
        row = self.db.execute(
            "SELECT customer_id, subject_id, revoked FROM licenses WHERE subject_id = ?",
            (subject_id,),
        ).fetchone()
        if row is None:
            return None
        return {"customer_id": row[0], "subject_id": row[1], "revoked": bool(row[2])}

    def revoke(self, license_key):
        cursor = self.db.execute(
            "UPDATE licenses SET revoked = 1 WHERE license_key = ?",
            (license_key,),
        )
        self.db.commit()
        return cursor.rowcount > 0


def admin_register(db_path, customer_id):
    store = Store(db_path)
    try:
        return store.register(customer_id)
    finally:
        store.close()


def admin_revoke(db_path, license_key):
    store = Store(db_path)
    try:
        return store.revoke(license_key)
    finally:
        store.close()


class LicenseServer(HTTPServer):
    def __init__(self, address, private_key_path, kid, allowed_kids, clock, db_path):
        private_key = _load_private_key(private_key_path)
        allowed_kids = _allowed_kids(allowed_kids)
        if kid not in allowed_kids:
            raise ValueError("signing kid is not allowed")
        super().__init__(address, Handler)
        self.private_key = private_key
        self.public_key = private_key.public_key()
        self.kid = kid
        self.allowed_kids = allowed_kids
        self.clock = clock
        self.store = Store(db_path)

    def server_close(self):
        self.store.close()
        super().server_close()

    def token_for(self, license_key):
        license_record = self.store.get(license_key)
        if license_record is None:
            raise ValueError("unknown_license")
        if license_record["revoked"]:
            raise ValueError("revoked")
        return self._token_for_record(license_record)

    def token_for_subject(self, subject_id):
        license_record = self.store.get_by_subject(subject_id)
        if license_record is None:
            raise ValueError("unknown_license")
        if license_record["revoked"]:
            raise ValueError("revoked")
        return self._token_for_record(license_record)

    def _token_for_record(self, license_record):
        now = int(self.clock())
        return sign_jwt(
            {
                "iss": ISSUER,
                "aud": AUDIENCE,
                "sub": license_record["subject_id"],
                "jti": str(uuid.uuid4()),
                "iat": now,
                "exp": now + TOKEN_TTL_SECONDS,
            },
            self.private_key,
            self.kid,
        )


class RequestError(Exception):
    def __init__(self, status, error):
        super().__init__(error)
        self.status = status
        self.error = error


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_json(404, {"error": "not_found"})

    def do_POST(self):
        routes = {"/issue": self.issue, "/verify": self.verify}
        handler = routes.get(self.path)
        if handler is None:
            self.send_json(404, {"error": "not_found"})
            return
        try:
            handler(self.read_json())
        except RequestError as error:
            self.close_connection = True
            self.send_json(error.status, {"error": error.error})
        except KeyError:
            self.send_json(400, {"error": "bad_request"})
        except json.JSONDecodeError:
            self.send_json(400, {"error": "bad_request"})
        except ValueError as error:
            self.send_json(404, {"error": str(error)})

    def issue(self, body):
        license_key = self._required_string(body, "license_key")
        try:
            token = self.server.token_for(license_key)
        except ValueError as error:
            if str(error) == "revoked":
                self.send_json(403, {"error": "revoked"})
                return
            raise
        self.send_json(200, {"token": token})

    def verify(self, body):
        token = self._required_string(body, "token")
        try:
            claims = read_jwt(
                token,
                self.server.public_key,
                self.server.allowed_kids,
                now=self.server.clock(),
                active_kid=self.server.kid,
            )
        except (KeyError, ValueError):
            self.send_json(401, {"valid": False, "error": "invalid_token"})
            return
        license_record = self.server.store.get_by_subject(claims["sub"])
        if license_record is None:
            self.send_json(401, {"valid": False, "error": "invalid_token"})
            return
        if license_record["revoked"]:
            self.send_json(403, {"valid": False, "error": "revoked"})
            return
        self.send_json(200, {"valid": True, "token": self.server.token_for_subject(claims["sub"])})

    def read_json(self):
        if self.headers.get("Content-Type") != "application/json":
            raise RequestError(415, "unsupported_media_type")
        transfer_encoding = self.headers.get("Transfer-Encoding")
        if transfer_encoding:
            raise RequestError(400, "bad_request")
        content_lengths = self.headers.get_all("Content-Length", [])
        if len(content_lengths) != 1:
            raise RequestError(411, "length_required")
        content_length = content_lengths[0]
        if not content_length.isdigit():
            raise RequestError(400, "bad_request")
        length = int(content_length)
        if length > MAX_BODY_BYTES:
            raise RequestError(413, "request_too_large")
        body = self.rfile.read(length)
        if len(body) != length:
            raise RequestError(400, "bad_request")
        value = json.loads(body)
        if not isinstance(value, dict):
            raise RequestError(400, "bad_request")
        return value

    @staticmethod
    def _required_string(body, field):
        value = body.get(field)
        if not isinstance(value, str) or not value:
            raise RequestError(400, "bad_request")
        return value

    def send_json(self, status, body):
        payload = json.dumps(body, separators=(",", ":")).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, format, *args):
        return


def make_server(
    address,
    private_key_path,
    kid,
    allowed_kids,
    clock=time.time,
    db_path=":memory:",
):
    host = address[0]
    try:
        is_loopback = ipaddress.ip_address(host).is_loopback
    except ValueError as error:
        raise ValueError("cleartext server must bind to numeric loopback") from error
    if not is_loopback:
        raise ValueError("cleartext server must bind to numeric loopback")
    return LicenseServer(address, private_key_path, kid, allowed_kids, clock, db_path)


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", default=8080, type=int)
    parser.add_argument("--db", default="license_server.sqlite3")
    parser.add_argument("--private-key", required=True)
    parser.add_argument("--kid", required=True)
    parser.add_argument("--allowed-kid", action="append", required=True)
    args = parser.parse_args(argv)
    try:
        server = make_server(
            (args.host, args.port),
            private_key_path=args.private_key,
            kid=args.kid,
            allowed_kids=args.allowed_kid,
            db_path=args.db,
        )
    except ValueError as error:
        print(str(error), file=sys.stderr)
        return 2
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
