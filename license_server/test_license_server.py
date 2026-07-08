import json
import threading
import unittest
from urllib import request
from urllib.error import HTTPError

from license_server.server import make_server, offline_grace_valid, read_jwt, sign_jwt


class ApiClient:
    def __init__(self, clock):
        self.server = make_server(("127.0.0.1", 0), secret="test-secret", clock=clock)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.base_url = f"http://127.0.0.1:{self.server.server_port}"

    def close(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2)

    def post(self, path, payload):
        body = json.dumps(payload).encode()
        api_request = request.Request(
            self.base_url + path,
            data=body,
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        try:
            response = request.urlopen(api_request)
            with response:
                return response.status, json.loads(response.read())
        except HTTPError as error:
            with error:
                return error.status, json.loads(error.read())


class LicenseServerApiTest(unittest.TestCase):
    def test_register_issue_and_verify_return_claims_for_offline_grace(self):
        now = 1_700_000_000
        api = ApiClient(clock=lambda: now)
        self.addCleanup(api.close)

        status, registration = api.post(
            "/register",
            {"customer_id": "cust-1", "device_id": "sim-rig-1"},
        )
        self.assertEqual(status, 201)
        self.assertEqual(registration["status"], "active")

        status, issued = api.post(
            "/issue",
            {"license_key": registration["license_key"], "device_id": "sim-rig-1"},
        )
        self.assertEqual(status, 200)

        status, verified = api.post("/verify", {"token": issued["token"]})
        self.assertEqual(status, 200)
        self.assertTrue(verified["valid"])

        claims = read_jwt(verified["token"], "test-secret")
        self.assertEqual(claims["sub"], registration["license_key"])
        self.assertEqual(claims["customer_id"], "cust-1")
        self.assertEqual(claims["device_id"], "sim-rig-1")
        self.assertEqual(claims["online_verified_at"], now)
        self.assertEqual(claims["offline_grace_until"], now + 72 * 60 * 60)

    def test_revoked_license_fails_next_online_verify(self):
        api = ApiClient(clock=lambda: 1_700_000_000)
        self.addCleanup(api.close)
        _, registration = api.post("/register", {"customer_id": "cust-2"})
        _, issued = api.post("/issue", {"license_key": registration["license_key"]})

        status, revoked = api.post(
            "/revoke",
            {"license_key": registration["license_key"]},
        )
        self.assertEqual(status, 200)
        self.assertTrue(revoked["revoked"])

        status, verified = api.post("/verify", {"token": issued["token"]})
        self.assertEqual(status, 403)
        self.assertFalse(verified["valid"])
        self.assertEqual(verified["error"], "revoked")

        status, issued_after_revoke = api.post(
            "/issue",
            {"license_key": registration["license_key"]},
        )
        self.assertEqual(status, 403)
        self.assertEqual(issued_after_revoke["error"], "revoked")

    def test_offline_grace_expires_after_72_hours(self):
        now = 1_700_000_000
        api = ApiClient(clock=lambda: now)
        self.addCleanup(api.close)
        _, registration = api.post("/register", {"customer_id": "cust-3"})
        _, issued = api.post("/issue", {"license_key": registration["license_key"]})

        self.assertTrue(
            offline_grace_valid(issued["token"], "test-secret", now + 72 * 60 * 60)
        )
        self.assertFalse(
            offline_grace_valid(issued["token"], "test-secret", now + 72 * 60 * 60 + 1)
        )

    def test_offline_grace_fails_closed_for_missing_or_bad_grace_claims(self):
        base_claims = {
            "iss": "aerosim-license-server",
            "aud": "aerosim-client",
            "sub": "lic_test",
        }

        missing_grace = sign_jwt(base_claims, "test-secret")
        bad_grace = sign_jwt(
            {**base_claims, "offline_grace_until": "not-a-timestamp"},
            "test-secret",
        )

        self.assertFalse(offline_grace_valid(missing_grace, "test-secret", 1))
        self.assertFalse(offline_grace_valid(bad_grace, "test-secret", 1))

    def test_invalid_token_fails_loudly(self):
        api = ApiClient(clock=lambda: 1_700_000_000)
        self.addCleanup(api.close)

        status, verified = api.post("/verify", {"token": "not-a-jwt"})

        self.assertEqual(status, 401)
        self.assertFalse(verified["valid"])
        self.assertEqual(verified["error"], "invalid_token")

    def test_signed_token_with_wrong_audience_is_rejected(self):
        api = ApiClient(clock=lambda: 1_700_000_000)
        self.addCleanup(api.close)
        _, registration = api.post("/register", {"customer_id": "cust-4"})
        token = sign_jwt(
            {
                "iss": "aerosim-license-server",
                "aud": "other-client",
                "sub": registration["license_key"],
                "offline_grace_until": 1_700_000_000 + 72 * 60 * 60,
            },
            "test-secret",
        )

        status, verified = api.post("/verify", {"token": token})

        self.assertEqual(status, 401)
        self.assertFalse(verified["valid"])
        self.assertEqual(verified["error"], "invalid_token")


if __name__ == "__main__":
    unittest.main()
