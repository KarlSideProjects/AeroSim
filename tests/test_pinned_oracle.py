#!/usr/bin/env python3
"""Intent: CI oracles execute only the hash-verified, versioned source cache."""

import json
import shutil
import socket
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

from pinned_oracle import CACHE_ROOT, CONTRACT_PATH, load_pinned_oracle


class PinnedOracleTest(unittest.TestCase):
    def copy_versioned_oracle_assets(self, directory: Path):
        cache_root = directory / "cache"
        contract_path = directory / "contract.json"
        shutil.copy2(CONTRACT_PATH, contract_path)
        contract = json.loads(contract_path.read_text(encoding="utf-8"))
        cache_path = cache_root / contract["commit"] / contract["path"]
        cache_path.parent.mkdir(parents=True)
        shutil.copy2(CACHE_ROOT / contract["commit"] / contract["path"], cache_path)
        return contract_path, cache_root, cache_path

    def test_cache_path_disables_git_text_normalization(self):
        contract = json.loads(CONTRACT_PATH.read_text(encoding="utf-8"))
        cache_path = CACHE_ROOT / contract["commit"] / contract["path"]
        completed = subprocess.run(
            ["git", "check-attr", "text", "--", str(cache_path.relative_to(ROOT))],
            cwd=ROOT,
            check=False,
            capture_output=True,
            text=True,
        )

        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(completed.stdout, f"{cache_path.relative_to(ROOT)}: text: unset\n")

    def test_cached_loader_works_when_network_transport_is_unavailable(self):
        with tempfile.TemporaryDirectory() as directory:
            contract_path, cache_root, _ = self.copy_versioned_oracle_assets(Path(directory))
            with patch.object(socket.socket, "connect", side_effect=AssertionError("network access is forbidden")):
                _, _, base_aviary = load_pinned_oracle(contract_path, cache_root)

            self.assertTrue(hasattr(base_aviary, "_drag"))
            self.assertTrue(hasattr(base_aviary, "_groundEffect"))
            self.assertTrue(hasattr(base_aviary, "_downwash"))

    def test_loader_fails_loudly_when_cache_is_missing(self):
        with tempfile.TemporaryDirectory() as directory:
            contract_path, cache_root, cache_path = self.copy_versioned_oracle_assets(Path(directory))
            cache_path.unlink()

            with self.assertRaisesRegex(RuntimeError, "pinned oracle cache missing"):
                load_pinned_oracle(contract_path, cache_root)

    def test_loader_fails_loudly_when_cached_bytes_do_not_match_contract_hash(self):
        with tempfile.TemporaryDirectory() as directory:
            contract_path, cache_root, cache_path = self.copy_versioned_oracle_assets(Path(directory))
            cache_path.write_bytes(b"modified cached bytes")

            with self.assertRaisesRegex(RuntimeError, "pinned oracle cache SHA-256 mismatch"):
                load_pinned_oracle(contract_path, cache_root)

    def test_loader_rejects_non_canonical_repository_url(self):
        with tempfile.TemporaryDirectory() as directory:
            contract_path, cache_root, _ = self.copy_versioned_oracle_assets(Path(directory))
            contract = json.loads(contract_path.read_text(encoding="utf-8"))
            contract["repository_url"] = "https://github.com/utiasDSL/gym-pybullet-drones"
            contract_path.write_text(json.dumps(contract), encoding="utf-8")

            with self.assertRaisesRegex(RuntimeError, "non-canonical repository URL"):
                load_pinned_oracle(contract_path, cache_root)

    def test_loader_fails_loudly_when_contract_is_missing(self):
        with tempfile.TemporaryDirectory() as directory:
            missing_contract = Path(directory) / "missing-contract.json"

            with self.assertRaisesRegex(RuntimeError, "pinned oracle contract missing"):
                load_pinned_oracle(missing_contract, CACHE_ROOT)


if __name__ == "__main__":
    unittest.main()
