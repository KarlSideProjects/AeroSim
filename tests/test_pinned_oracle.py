#!/usr/bin/env python3
"""Intent: CI oracles execute only the hash-verified, versioned source cache."""

import hashlib
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

from pinned_oracle import load_pinned_oracle


CANONICAL_REPOSITORY = "https://github.com/learnsyslab/gym-pybullet-drones"
PINNED_COMMIT = "9bc12bc583fa3b28807b2f90a8cadf09fb06e1ff"
SOURCE_PATH = "gym_pybullet_drones/envs/BaseAviary.py"
TEST_SOURCE = """class BaseAviary:
    def _drag(self):
        pass

    def _groundEffect(self):
        pass

    def _downwash(self):
        pass
"""


class PinnedOracleTest(unittest.TestCase):
    def write_cached_contract(self, directory: Path, source: bytes = TEST_SOURCE.encode("utf-8")):
        cache_root = directory / "cache"
        cache_path = cache_root / PINNED_COMMIT / SOURCE_PATH
        cache_path.parent.mkdir(parents=True)
        cache_path.write_bytes(source)
        contract_path = directory / "contract.json"
        contract_path.write_text(
            json.dumps(
                {
                    "repository_url": CANONICAL_REPOSITORY,
                    "commit": PINNED_COMMIT,
                    "path": SOURCE_PATH,
                    "sha256": hashlib.sha256(source).hexdigest(),
                }
            ),
            encoding="utf-8",
        )
        return contract_path, cache_root, cache_path

    def test_cached_loader_works_when_network_is_unavailable(self):
        with tempfile.TemporaryDirectory() as directory:
            contract_path, cache_root, _ = self.write_cached_contract(Path(directory))
            with patch("urllib.request.urlopen", side_effect=AssertionError("network access is forbidden")):
                _, _, base_aviary = load_pinned_oracle(contract_path, cache_root)

            self.assertTrue(hasattr(base_aviary, "_drag"))
            self.assertTrue(hasattr(base_aviary, "_groundEffect"))
            self.assertTrue(hasattr(base_aviary, "_downwash"))

    def test_loader_fails_loudly_when_cache_is_missing(self):
        with tempfile.TemporaryDirectory() as directory:
            contract_path, cache_root, cache_path = self.write_cached_contract(Path(directory))
            cache_path.unlink()

            with self.assertRaisesRegex(RuntimeError, "pinned oracle cache missing"):
                load_pinned_oracle(contract_path, cache_root)

    def test_loader_fails_loudly_when_cached_bytes_do_not_match_contract_hash(self):
        with tempfile.TemporaryDirectory() as directory:
            contract_path, cache_root, cache_path = self.write_cached_contract(Path(directory))
            cache_path.write_bytes(b"modified cached bytes")

            with self.assertRaisesRegex(RuntimeError, "pinned oracle cache SHA-256 mismatch"):
                load_pinned_oracle(contract_path, cache_root)

    def test_default_contract_loads_the_versioned_base_aviary_cache(self):
        with patch("urllib.request.urlopen", side_effect=AssertionError("network access is forbidden")):
            _, _, base_aviary = load_pinned_oracle()

        self.assertTrue(hasattr(base_aviary, "_drag"))
        self.assertTrue(hasattr(base_aviary, "_groundEffect"))
        self.assertTrue(hasattr(base_aviary, "_downwash"))


if __name__ == "__main__":
    unittest.main()
