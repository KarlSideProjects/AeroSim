#!/usr/bin/env python3
"""Ephemeral Python RS256 signing and Godot public-key verification interop."""

import base64
import copy
import json
import subprocess
import tempfile
import uuid
from pathlib import Path

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import padding, rsa


ROOT = Path(__file__).resolve().parents[1]
GODOT = Path("/home/karl/Workspace/Toys/Godot/Godot_v4.7-stable_linux.x86_64")
NOW = 1_700_000_000
KID = "ubuntu-2026"


def base64url(value: bytes) -> str:
    return base64.urlsafe_b64encode(value).decode("ascii").rstrip("=")


def decode_base64url(value: str) -> bytes:
    return base64.urlsafe_b64decode(value + "=" * (-len(value) % 4))


def sign_token(header: dict, claims: dict, private_key) -> str:
    encoded_header = base64url(json.dumps(header, separators=(",", ":")).encode())
    encoded_claims = base64url(json.dumps(claims, separators=(",", ":")).encode())
    signing_input = f"{encoded_header}.{encoded_claims}".encode("ascii")
    signature = private_key.sign(signing_input, padding.PKCS1v15(), hashes.SHA256())
    return f"{encoded_header}.{encoded_claims}.{base64url(signature)}"


def sign_payload_text(header: dict, payload_text: str, private_key) -> str:
    encoded_header = base64url(json.dumps(header, separators=(",", ":")).encode())
    encoded_payload = base64url(payload_text.encode())
    signing_input = f"{encoded_header}.{encoded_payload}".encode("ascii")
    signature = private_key.sign(signing_input, padding.PKCS1v15(), hashes.SHA256())
    return f"{encoded_header}.{encoded_payload}.{base64url(signature)}"


def altered_segment(token: str, index: int, value: str) -> str:
    segments = token.split(".")
    segments[index] = value
    return ".".join(segments)


def run() -> None:
    if not GODOT.is_file() or not GODOT.stat().st_mode & 0o111:
        raise SystemExit(f"Godot executable is missing or not executable: {GODOT}")

    private_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    public_key = private_key.public_key()
    claims = {
        "iss": "urn:aerosim:license-server",
        "aud": "urn:aerosim:ubuntu-client",
        "sub": str(uuid.UUID("00000000-0000-4000-8000-000000000001")),
        "jti": str(uuid.UUID("00000000-0000-4000-8000-000000000002")),
        "iat": NOW,
        "exp": NOW + 259200,
    }
    token = sign_token(
        {"alg": "RS256", "typ": "aerosim-license+jwt", "kid": KID},
        claims,
        private_key,
    )
    header = {"alg": "RS256", "typ": "aerosim-license+jwt", "kid": KID}
    missing_kid_header = {"alg": "RS256", "typ": "aerosim-license+jwt"}
    fractional_claims = json.dumps({**claims, "iat": NOW + 0.5}, separators=(",", ":"))
    duplicate_iat_claims = (
        '{"iss":"urn:aerosim:license-server","aud":"urn:aerosim:ubuntu-client",'
        '"sub":"00000000-0000-4000-8000-000000000001",'
        '"jti":"00000000-0000-4000-8000-000000000002",'
        f'"iat":{NOW},"iat":{NOW}.5,"exp":{NOW + 259200}}}'
    )

    header = json.loads(__import__("base64").urlsafe_b64decode(token.split(".")[0] + "=="))
    modified_header = copy.deepcopy(header)
    modified_header["alg"] = "HS256"
    modified_header_segment = base64url(json.dumps(modified_header, separators=(",", ":")).encode())

    modified_claims = copy.deepcopy(claims)
    modified_claims["aud"] = "urn:aerosim:other-client"
    modified_payload_segment = base64url(json.dumps(modified_claims, separators=(",", ":")).encode())

    signature = bytearray(decode_base64url(token.split(".")[2]))
    signature[0] ^= 1

    with tempfile.TemporaryDirectory(prefix="aerosim-license-token-") as directory:
        directory_path = Path(directory)
        private_path = directory_path / "signing-key.pem"
        public_path = directory_path / "signing-key-public.pem"
        input_path = directory_path / "input.json"
        output_path = directory_path / "output.json"
        private_path.write_bytes(private_key.private_bytes(
            serialization.Encoding.PEM,
            serialization.PrivateFormat.PKCS8,
            serialization.NoEncryption(),
        ))
        public_path.write_bytes(public_key.public_bytes(
            serialization.Encoding.PEM,
            serialization.PublicFormat.SubjectPublicKeyInfo,
        ))
        input_path.write_text(json.dumps({
            "public_key_path": str(public_path),
            "allowed_kids": [KID],
            "now": NOW,
            "cases": [
                {"name": "python_rs256", "token": token, "valid": True, "claims": claims},
                {"name": "modified_header", "token": altered_segment(token, 0, modified_header_segment), "valid": False},
                {"name": "missing_header_key", "token": sign_token(missing_kid_header, claims, private_key), "valid": False},
                {"name": "unknown_kid", "token": sign_token({**header, "kid": "other-key"}, claims, private_key), "valid": False},
                {"name": "modified_payload", "token": altered_segment(token, 1, modified_payload_segment), "valid": False},
                {"name": "modified_signature", "token": altered_segment(token, 2, base64url(bytes(signature))), "valid": False},
                {"name": "padded_header_segment", "token": altered_segment(token, 0, token.split(".")[0] + "="), "valid": False},
                {"name": "fractional_iat", "token": sign_payload_text(header, fractional_claims, private_key), "valid": False},
                {"name": "duplicate_fractional_iat", "token": sign_payload_text(header, duplicate_iat_claims, private_key), "valid": False},
            ],
        }), encoding="utf-8")

        command = [
            str(GODOT),
            "--headless",
            "--path",
            str(ROOT),
            "--script",
            "res://tests/headless/rs256_license_token_harness.gd",
            "--",
            "--input",
            str(input_path),
            "--output",
            str(output_path),
        ]
        result = subprocess.run(command, cwd=ROOT, capture_output=True, text=True)
        if result.returncode != 0:
            print(result.stdout, end="")
            print(result.stderr, end="")
            raise SystemExit(f"Godot token harness failed with status {result.returncode}")
        report = json.loads(output_path.read_text(encoding="utf-8"))
        if report != {"ok": True, "failures": []}:
            raise SystemExit(f"Godot token harness reported failure: {report}")
        print("RS256 Python -> Godot interop passed: valid token and modified header/payload/signature rejected")


if __name__ == "__main__":
    run()
