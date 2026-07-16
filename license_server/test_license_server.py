import contextlib
import io
import json
import threading
import unittest
import uuid
from http import client
from pathlib import Path
from tempfile import TemporaryDirectory
from unittest import mock

import jwt
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec, rsa

from license_server.admin import main as admin_main
from license_server.server import (
    MAX_BODY_BYTES,
    TOKEN_TTL_SECONDS,
    admin_register,
    admin_revoke,
    make_server,
    read_jwt,
)


ISSUER = "urn:aerosim:license-server"
AUDIENCE = "urn:aerosim:ubuntu-client"
KID = "test-key-1"


class ApiClient:
    def __init__(self, key_path, clock=lambda: 1_700_000_000, db_path=":memory:"):
        self.server = make_server(
            ("127.0.0.1", 0),
            private_key_path=key_path,
            kid=KID,
            allowed_kids={KID},
            clock=clock,
            db_path=db_path,
        )
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.base_url = ("127.0.0.1", self.server.server_port)

    def close(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2)

    def post(self, path, payload):
        body = json.dumps(payload).encode()
        return self.raw_post(path, body, {"Content-Length": str(len(body)), "Content-Type": "application/json"})

    def raw_post(self, path, body=b"", headers=None):
        connection = client.HTTPConnection(*self.base_url)
        connection.putrequest("POST", path)
        for name, value in (headers or {}).items():
            connection.putheader(name, value)
        connection.endheaders()
        if body:
            connection.send(body)
        response = connection.getresponse()
        payload = response.read()
        result = response.status, json.loads(payload) if payload else None
        connection.close()
        return result


class LicenseServerApiTest(unittest.TestCase):
    def setUp(self):
        self.directory = TemporaryDirectory()
        key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        self.private_key = key
        self.key_path = Path(self.directory.name) / "signing-key.pem"
        self.key_path.write_bytes(
            key.private_bytes(
                serialization.Encoding.PEM,
                serialization.PrivateFormat.PKCS8,
                serialization.NoEncryption(),
            )
        )

    def tearDown(self):
        self.directory.cleanup()

    def api(self, clock=lambda: 1_700_000_000):
        api = ApiClient(self.key_path, clock=clock)
        self.addCleanup(api.close)
        return api

    def test_issue_has_rs256_header_and_opaque_uuid_claims_for_exact_72_hours(self):
        now = 1_700_000_000
        db_path = Path(self.directory.name) / "licenses.sqlite3"
        license_key = admin_register(db_path, "customer-with-pii@example.test")
        api = ApiClient(self.key_path, clock=lambda: now, db_path=db_path)
        self.addCleanup(api.close)

        status, issued = api.post("/issue", {"license_key": license_key, "device_id": "rig-42"})

        self.assertEqual(status, 200)
        token = issued["token"]
        header = jwt.get_unverified_header(token)
        payload = jwt.decode(token, options={"verify_signature": False})
        self.assertEqual(header, {"alg": "RS256", "typ": "aerosim-license+jwt", "kid": KID})
        self.assertEqual(set(payload), {"iss", "aud", "sub", "jti", "iat", "exp"})
        self.assertEqual(payload["iss"], ISSUER)
        self.assertEqual(payload["aud"], AUDIENCE)
        self.assertEqual(payload["iat"], now)
        self.assertEqual(payload["exp"], now + TOKEN_TTL_SECONDS)
        self.assertEqual(str(uuid.UUID(payload["sub"])), payload["sub"])
        self.assertEqual(str(uuid.UUID(payload["jti"])), payload["jti"])
        self.assertNotIn("customer-with-pii", json.dumps(payload))
        self.assertNotIn("rig-42", json.dumps(payload))
        self.assertEqual(read_jwt(token, self.private_key, {KID}, now=now), payload)

    def test_future_iat_allows_five_minutes_but_not_more(self):
        now = 1_700_000_000
        claims = {
            "iss": ISSUER,
            "aud": AUDIENCE,
            "sub": "00000000-0000-4000-8000-000000000001",
            "jti": "00000000-0000-4000-8000-000000000002",
            "iat": now + 300,
            "exp": now + 300 + TOKEN_TTL_SECONDS,
        }
        token = jwt.encode(claims, self.private_key, algorithm="RS256", headers={"typ": "aerosim-license+jwt", "kid": KID})
        self.assertEqual(read_jwt(token, self.private_key, {KID}, now=now), claims)
        claims["iat"] += 1
        claims["exp"] += 1
        token = jwt.encode(claims, self.private_key, algorithm="RS256", headers={"typ": "aerosim-license+jwt", "kid": KID})
        with self.assertRaises(ValueError):
            read_jwt(token, self.private_key, {KID}, now=now)

    def test_unknown_kid_is_rejected(self):
        now = 1_700_000_000
        license_key = admin_register(Path(self.directory.name) / "licenses.sqlite3", "cust-1")
        api = self.api(clock=lambda: now)
        token = jwt.encode(
            {
                "iss": ISSUER,
                "aud": AUDIENCE,
                "sub": "00000000-0000-4000-8000-000000000001",
                "jti": "00000000-0000-4000-8000-000000000002",
                "iat": now,
                "exp": now + TOKEN_TTL_SECONDS,
            },
            self.private_key,
            algorithm="RS256",
            headers={"typ": "aerosim-license+jwt", "kid": "unknown"},
        )

        status, result = api.post("/verify", {"token": token})

        self.assertEqual(status, 401)
        self.assertEqual(result, {"valid": False, "error": "invalid_token"})
        self.assertIsNotNone(license_key)

    def test_active_kid_is_required_and_kid_format_is_bounded(self):
        now = 1_700_000_000
        claims = {
            "iss": ISSUER,
            "aud": AUDIENCE,
            "sub": "00000000-0000-4000-8000-000000000001",
            "jti": "00000000-0000-4000-8000-000000000002",
            "iat": now,
            "exp": now + TOKEN_TTL_SECONDS,
        }
        token = jwt.encode(claims, self.private_key, algorithm="RS256", headers={"typ": "aerosim-license+jwt", "kid": "other-key"})
        with self.assertRaises(ValueError):
            read_jwt(token, self.private_key, {KID, "other-key"}, now=now, active_kid=KID)
        with self.assertRaises(ValueError):
            make_server(("127.0.0.1", 0), private_key_path=self.key_path, kid="bad/kid", allowed_kids={"bad/kid"})

    def test_expiry_is_valid_before_boundary_and_invalid_at_boundary(self):
        now = 1_700_000_000
        db_path = Path(self.directory.name) / "licenses.sqlite3"
        license_key = admin_register(db_path, "cust-1")
        api = ApiClient(self.key_path, clock=lambda: now, db_path=db_path)
        self.addCleanup(api.close)
        _, issued = api.post("/issue", {"license_key": license_key})
        token = issued["token"]

        self.assertIsNotNone(read_jwt(token, self.private_key, {KID}, now=now + TOKEN_TTL_SECONDS - 1))
        with self.assertRaises(ValueError):
            read_jwt(token, self.private_key, {KID}, now=now + TOKEN_TTL_SECONDS)

    def test_revocation_is_local_admin_only_and_blocks_issue_and_verify(self):
        now = 1_700_000_000
        db_path = Path(self.directory.name) / "licenses.sqlite3"
        license_key = admin_register(db_path, "cust-2")
        api = ApiClient(self.key_path, clock=lambda: now, db_path=db_path)
        self.addCleanup(api.close)
        _, issued = api.post("/issue", {"license_key": license_key})

        self.assertTrue(admin_revoke(db_path, license_key))
        self.assertEqual(api.post("/verify", {"token": issued["token"]}), (403, {"valid": False, "error": "revoked"}))
        self.assertEqual(api.post("/issue", {"license_key": license_key}), (403, {"error": "revoked"}))
        self.assertEqual(api.post("/register", {"customer_id": "cust-3"})[0], 404)
        self.assertEqual(api.post("/revoke", {"license_key": license_key})[0], 404)

    def test_only_issue_and_verify_are_post_routes(self):
        api = self.api()

        self.assertEqual(api.post("/unknown", {})[0], 404)
        self.assertEqual(api.raw_post("/issue?admin=1", b"{}", {"Content-Length": "2"})[0], 404)

    def test_request_requires_json_and_string_fields(self):
        api = self.api()
        self.assertEqual(api.raw_post("/issue", b"{}", {"Content-Length": "2"})[0], 415)
        self.assertEqual(api.post("/issue", {"license_key": 42})[0], 400)
        self.assertEqual(api.post("/verify", {"token": None})[0], 400)

    def test_request_requires_explicit_content_length_and_rejects_chunked(self):
        api = self.api()

        self.assertEqual(api.raw_post("/issue", b"{}", {"Content-Type": "application/json"})[0], 411)
        self.assertEqual(api.raw_post("/issue", b"{}", {"Content-Type": "application/json", "Transfer-Encoding": "chunked"})[0], 400)

    def test_request_rejects_malformed_and_oversized_content_length(self):
        api = self.api()

        self.assertEqual(api.raw_post("/issue", b"{}", {"Content-Type": "application/json", "Content-Length": "bad"})[0], 400)
        self.assertEqual(api.raw_post("/issue", b"{", {"Content-Type": "application/json", "Content-Length": "1"})[0], 400)
        self.assertEqual(api.raw_post("/issue", b"{}", {"Content-Type": "application/json", "Content-Length": str(MAX_BODY_BYTES + 1)})[0], 413)

    def test_request_rejects_oversized_json_body(self):
        api = self.api()
        body = b"{" + b"\"x\":" + b"\"a\"" * MAX_BODY_BYTES + b"}"

        self.assertEqual(len(body) > MAX_BODY_BYTES, True)
        self.assertEqual(api.raw_post("/issue", body, {"Content-Type": "application/json", "Content-Length": str(len(body))})[0], 413)

    def test_bad_key_configuration_fails_closed(self):
        with self.assertRaises(ValueError):
            make_server(("127.0.0.1", 0), private_key_path=Path(self.directory.name) / "missing.pem", kid=KID, allowed_kids={KID})

        small_key = rsa.generate_private_key(public_exponent=65537, key_size=1024)
        small_path = Path(self.directory.name) / "small.pem"
        small_path.write_bytes(small_key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()))
        with self.assertRaises(ValueError):
            make_server(("127.0.0.1", 0), private_key_path=small_path, kid=KID, allowed_kids={KID})

        ec_path = Path(self.directory.name) / "ec.pem"
        ec_key = ec.generate_private_key(ec.SECP256R1())
        ec_path.write_bytes(ec_key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()))
        with self.assertRaises(ValueError):
            make_server(("127.0.0.1", 0), private_key_path=ec_path, kid=KID, allowed_kids={KID})

        with self.assertRaises(ValueError):
            make_server(("127.0.0.1", 0), private_key_path=self.key_path, kid=KID, allowed_kids=set())
        for host in ("0.0.0.0", "192.0.2.10", "localhost"):
            with self.assertRaises(ValueError):
                make_server((host, 0), private_key_path=self.key_path, kid=KID, allowed_kids={KID})

    def test_admin_cli_registers_and_revokes_without_network_routes(self):
        db_path = Path(self.directory.name) / "admin.sqlite3"
        key_path = Path(self.directory.name) / "license.key"
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            self.assertEqual(admin_main(["--db", str(db_path), "register", "--customer-id", "cust-5", "--output", str(key_path)]), 0)
        license_key = key_path.read_text()
        self.assertNotIn(license_key, output.getvalue())

        output = io.StringIO()
        with contextlib.redirect_stdout(output), mock.patch("sys.stdin", io.StringIO(license_key)):
            self.assertEqual(admin_main(["--db", str(db_path), "revoke"]), 0)
        self.assertEqual(json.loads(output.getvalue()), {"revoked": True})


if __name__ == "__main__":
    unittest.main()
