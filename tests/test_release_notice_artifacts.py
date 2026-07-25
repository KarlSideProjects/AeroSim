#!/usr/bin/env python3
"""Intent: release notices ship, and Ubuntu artifacts exclude Python runtime evidence."""

from pathlib import Path
import json
import resource
import subprocess
import sys
import tempfile
import unittest
import warnings
from zipfile import ZIP_DEFLATED, ZIP_STORED, ZipFile


ROOT = Path(__file__).resolve().parents[1]
ARTIFACT_CHECK = ROOT / "scripts" / "check_release_artifacts.py"
LICENSE_SCAN = ROOT / "scripts" / "check_licenses.py"
MANIFEST = ROOT / "third_party" / "licenses.json"
LINUX_EXECUTABLE = "AeroSim-linux/AeroSim.x86_64"
LINUX_EXTENSION = "AeroSim-linux/libaerosim_native.linux.template_release.x86_64.so"
LINUX_TERRAIN_EXTENSION = "AeroSim-linux/libterrain.linux.release.x86_64.so"
LINUX_NOTICE = "AeroSim-linux/THIRD_PARTY_NOTICES.txt"


class ReleaseArtifactTestCase(unittest.TestCase):
    def generated_notice(self, directory: Path) -> str:
        notice_path = directory / "THIRD_PARTY_NOTICES.txt"
        result = subprocess.run(
            [sys.executable, str(LICENSE_SCAN), "--notice-out", str(notice_path)],
            cwd=ROOT,
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        return notice_path.read_text(encoding="utf-8")

    def write_archive(self, path: Path, notice_path: str | None, notice: str = ""):
        with ZipFile(path, "w", ZIP_DEFLATED) as archive:
            archive.writestr("payload.bin", "release payload")
            if notice_path:
                archive.writestr(notice_path, notice)

    def write_linux_archive(
        self,
        path: Path,
        notice: str,
        *,
        executable: bytes = b"\x7fELF executable",
        extension: bytes = b"\x7fELF extension",
        terrain_extension: bytes = b"\x7fELF terrain extension",
        extra_entries: dict[str, bytes] | None = None,
        compression: int = ZIP_DEFLATED,
    ):
        with ZipFile(path, "w", compression) as archive:
            archive.writestr(LINUX_EXECUTABLE, executable)
            archive.writestr(LINUX_EXTENSION, extension)
            archive.writestr(LINUX_TERRAIN_EXTENSION, terrain_extension)
            archive.writestr(LINUX_NOTICE, notice)
            for name, payload in (extra_entries or {}).items():
                archive.writestr(name, payload)

    def mark_first_entry_encrypted(self, path: Path):
        data = bytearray(path.read_bytes())
        for signature, offset in ((b"PK\x03\x04", 6), (b"PK\x01\x02", 8)):
            header = data.index(signature)
            flags = int.from_bytes(data[header + offset : header + offset + 2], "little")
            data[header + offset : header + offset + 2] = (flags | 1).to_bytes(2, "little")
        path.write_bytes(data)

    def set_first_entry_compression(self, path: Path, compression: int):
        data = bytearray(path.read_bytes())
        for signature, offset in ((b"PK\x03\x04", 8), (b"PK\x01\x02", 10)):
            header = data.index(signature)
            data[header + offset : header + offset + 2] = compression.to_bytes(2, "little")
        path.write_bytes(data)

    def set_central_file_size(self, path: Path, entry: str, size: int):
        data = bytearray(path.read_bytes())
        offset = 0
        while True:
            header = data.find(b"PK\x01\x02", offset)
            self.assertNotEqual(header, -1, entry)
            name_length = int.from_bytes(data[header + 28 : header + 30], "little")
            name = bytes(data[header + 46 : header + 46 + name_length]).decode()
            if name == entry:
                data[header + 24 : header + 28] = size.to_bytes(4, "little")
                path.write_bytes(data)
                return
            offset = header + 46 + name_length

    def corrupt_deflated_entry(self, path: Path, entry: str):
        with ZipFile(path) as archive:
            info = archive.getinfo(entry)
        data = bytearray(path.read_bytes())
        header = info.header_offset
        name_length = int.from_bytes(data[header + 26 : header + 28], "little")
        extra_length = int.from_bytes(data[header + 28 : header + 30], "little")
        payload = header + 30 + name_length + extra_length
        data[payload] ^= 0xFF
        path.write_bytes(data)

    def check(self, artifact: Path, *args: str, memory_limit_mb: int | None = None):
        preexec_fn = None
        if memory_limit_mb is not None:
            limit = memory_limit_mb * 1024 * 1024
            preexec_fn = lambda: resource.setrlimit(resource.RLIMIT_AS, (limit, limit))
        return subprocess.run(
            [sys.executable, str(ARTIFACT_CHECK), *args, str(artifact)],
            cwd=ROOT,
            capture_output=True,
            text=True,
            check=False,
            preexec_fn=preexec_fn,
        )

    def assert_checker_accepts_notice_path(self, filename: str, notice_path: str):
        with tempfile.TemporaryDirectory() as directory:
            notice = self.generated_notice(Path(directory))
            artifact = Path(directory) / filename
            self.write_archive(artifact, notice_path, notice)
            result = self.check(artifact)
        self.assertEqual(result.returncode, 0, result.stderr)


class ReleaseNoticeArtifactsTest(ReleaseArtifactTestCase):
    def test_checker_rejects_production_android_archive_without_notice(self):
        with tempfile.TemporaryDirectory() as directory:
            artifact = Path(directory) / "AeroSim-android-production.apk"
            self.write_archive(artifact, None)
            result = self.check(artifact)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("missing THIRD_PARTY_NOTICES.txt", result.stderr)

    def test_checker_rejects_truncated_notice(self):
        with tempfile.TemporaryDirectory() as directory:
            artifact = Path(directory) / "AeroSim-windows.zip"
            self.write_archive(
                artifact,
                "AeroSim-windows/THIRD_PARTY_NOTICES.txt",
                "gym-pybullet-drones\nCopyright (c) 2020 Jacopo Panerati\n",
            )
            result = self.check(artifact)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("THIRD_PARTY_NOTICES.txt missing required text", result.stderr)


class UbuntuReleaseArtifactAuditTest(ReleaseArtifactTestCase):
    def test_checker_rejects_archive_without_notice(self):
        with tempfile.TemporaryDirectory() as directory:
            artifact = Path(directory) / "AeroSim-linux.zip"
            self.write_archive(artifact, None)
            result = self.check(artifact)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("missing THIRD_PARTY_NOTICES.txt", result.stderr)

    def test_checker_rejects_notice_missing_mit_warranty(self):
        manifest = json.loads(MANIFEST.read_text(encoding="utf-8"))
        entry = next(item for item in manifest["dependencies"] if item["name"] == "gym-pybullet-drones")
        truncated_notice = "\n".join((
            "gym-pybullet-drones",
            f"Attribution scope: {entry['attribution_scope']}",
            entry["notice"].split("\n\nTHE SOFTWARE IS PROVIDED", 1)[0],
        ))
        with tempfile.TemporaryDirectory() as directory:
            artifact = Path(directory) / "AeroSim-linux.zip"
            self.write_linux_archive(artifact, truncated_notice)
            result = self.check(artifact)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("THIRD_PARTY_NOTICES.txt missing required text", result.stderr)

    def test_checker_accepts_linux_notice_path(self):
        with tempfile.TemporaryDirectory() as directory:
            notice = self.generated_notice(Path(directory))
            artifact = Path(directory) / "AeroSim-linux.zip"
            self.write_linux_archive(artifact, notice)
            result = self.check(artifact)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_checker_short_circuits_oversized_archive_before_opening_zip(self):
        with tempfile.TemporaryDirectory() as directory:
            artifact = Path(directory) / "AeroSim-linux.zip"
            artifact.write_bytes(b"not a ZIP archive")
            result = self.check(artifact, "--max-mb", "0")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("artifact too large", result.stderr)
        self.assertNotIn("release archive", result.stderr)
        self.assertNotIn("Traceback", result.stderr)

    def test_checker_rejects_notice_zip_bomb_before_decompression(self):
        with tempfile.TemporaryDirectory() as directory:
            base_notice = self.generated_notice(Path(directory)).encode()
            notice = base_notice + b"x" * (128 * 1024 * 1024 - len(base_notice))
            artifact = Path(directory) / "AeroSim-linux.zip"
            self.write_linux_archive(artifact, notice)
            self.assertLess(artifact.stat().st_size, 1024 * 1024)
            result = self.check(artifact, memory_limit_mb=96)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("notice exceeds 1 MB", result.stderr)
        self.assertNotIn("Traceback", result.stderr)

    def test_checker_accepts_notice_at_one_megabyte_boundary(self):
        with tempfile.TemporaryDirectory() as directory:
            base_notice = self.generated_notice(Path(directory)).encode()
            notice = base_notice + b"x" * (1024 * 1024 - len(base_notice))
            artifact = Path(directory) / "AeroSim-linux.zip"
            self.write_linux_archive(artifact, notice)
            result = self.check(artifact)

        self.assertEqual(result.returncode, 0, result.stderr)

    def test_checker_rejects_oversized_native_metadata_before_decompression(self):
        with tempfile.TemporaryDirectory() as directory:
            notice = self.generated_notice(Path(directory))
            artifact = Path(directory) / "AeroSim-linux.zip"
            self.write_linux_archive(artifact, notice)
            self.set_central_file_size(artifact, LINUX_EXECUTABLE, 256 * 1024**2 + 1)
            result = self.check(artifact, memory_limit_mb=96)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("native payload exceeds 256 MB", result.stderr)
        self.assertNotIn("Traceback", result.stderr)

    def test_checker_rejects_oversized_total_metadata_before_decompression(self):
        with tempfile.TemporaryDirectory() as directory:
            notice = self.generated_notice(Path(directory))
            artifact = Path(directory) / "AeroSim-linux.zip"
            self.write_linux_archive(artifact, notice)
            self.set_central_file_size(artifact, LINUX_EXECUTABLE, 200 * 1024**2)
            self.set_central_file_size(artifact, LINUX_EXTENSION, 101 * 1024**2)
            result = self.check(artifact, memory_limit_mb=96)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("release archive exceeds 300 MB uncompressed", result.stderr)
        self.assertNotIn("Traceback", result.stderr)

    def test_checker_streams_large_native_payload_with_bounded_memory(self):
        with tempfile.TemporaryDirectory() as directory:
            notice = self.generated_notice(Path(directory))
            executable = b"\x7fELF" + b"\x00" * (128 * 1024**2 - 4)
            artifact = Path(directory) / "AeroSim-linux.zip"
            self.write_linux_archive(artifact, notice, executable=executable)
            self.assertLess(artifact.stat().st_size, 1024 * 1024)
            result = self.check(artifact, memory_limit_mb=96)

        self.assertEqual(result.returncode, 0, result.stderr)

    def test_checker_finds_runtime_marker_split_across_scan_chunks(self):
        with tempfile.TemporaryDirectory() as directory:
            notice = self.generated_notice(Path(directory))
            marker = b"libpython3.11.so.1.0\x00"
            prefix = b"\x7fELF" + b"\x00" * (1024**2 - 4 - 1 - 5) + b"\x00"
            artifact = Path(directory) / "AeroSim-linux.zip"
            self.write_linux_archive(artifact, notice, executable=prefix + marker)
            result = self.check(artifact)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("libpython runtime dependency marker", result.stderr)

    def test_checker_rejects_deflated_corruption_without_zlib_traceback(self):
        with tempfile.TemporaryDirectory() as directory:
            notice = self.generated_notice(Path(directory))
            executable = b"\x7fELF" + bytes(range(256)) * 1024
            artifact = Path(directory) / "AeroSim-linux.zip"
            self.write_linux_archive(artifact, notice, executable=executable)
            self.corrupt_deflated_entry(artifact, LINUX_EXECUTABLE)
            result = self.check(artifact)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("invalid release archive entry (corrupt or malformed)", result.stderr)
        self.assertNotIn("Traceback", result.stderr)

    def test_checker_rejects_extra_linux_entry_to_keep_python_out_of_release(self):
        with tempfile.TemporaryDirectory() as directory:
            notice = self.generated_notice(Path(directory))
            artifact = Path(directory) / "AeroSim-linux.zip"
            self.write_linux_archive(
                artifact,
                notice,
                extra_entries={"AeroSim-linux/python/runtime.py": b"print('unexpected')"},
            )
            result = self.check(artifact)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unexpected release archive entries", result.stderr)

    def test_checker_rejects_missing_linux_native_entry_instead_of_partial_scan(self):
        with tempfile.TemporaryDirectory() as directory:
            notice = self.generated_notice(Path(directory))
            artifact = Path(directory) / "AeroSim-linux.zip"
            with ZipFile(artifact, "w", ZIP_DEFLATED) as archive:
                archive.writestr(LINUX_EXECUTABLE, b"\x7fELF executable")
                archive.writestr(LINUX_NOTICE, notice)
            result = self.check(artifact)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unexpected release archive entries", result.stderr)

    def test_checker_rejects_duplicate_linux_entry_because_shape_must_be_unambiguous(self):
        with tempfile.TemporaryDirectory() as directory:
            notice = self.generated_notice(Path(directory))
            artifact = Path(directory) / "AeroSim-linux.zip"
            self.write_linux_archive(artifact, notice)
            with warnings.catch_warnings():
                warnings.simplefilter("ignore", UserWarning)
                with ZipFile(artifact, "a", ZIP_DEFLATED) as archive:
                    archive.writestr(LINUX_EXECUTABLE, b"\x7fELF duplicate")
            result = self.check(artifact)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("duplicate release archive entry", result.stderr)

    def test_checker_rejects_non_elf_native_payloads_before_runtime_scan(self):
        cases = {
            "executable": {"executable": b"not an executable"},
            "extension": {"extension": b"not an extension"},
            "terrain extension": {"terrain_extension": b"not a terrain extension"},
        }
        for name, payloads in cases.items():
            with self.subTest(payload=name), tempfile.TemporaryDirectory() as directory:
                notice = self.generated_notice(Path(directory))
                artifact = Path(directory) / "AeroSim-linux.zip"
                self.write_linux_archive(artifact, notice, **payloads)
                result = self.check(artifact)

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("native payload is not ELF", result.stderr)

    def test_checker_rejects_truncated_linux_zip_without_a_traceback(self):
        with tempfile.TemporaryDirectory() as directory:
            notice = self.generated_notice(Path(directory))
            artifact = Path(directory) / "AeroSim-linux.zip"
            self.write_linux_archive(artifact, notice)
            artifact.write_bytes(artifact.read_bytes()[:-20])
            result = self.check(artifact)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("invalid release archive", result.stderr)
        self.assertNotIn("Traceback", result.stderr)

    def test_checker_rejects_crc_corruption_in_native_payload(self):
        with tempfile.TemporaryDirectory() as directory:
            notice = self.generated_notice(Path(directory))
            artifact = Path(directory) / "AeroSim-linux.zip"
            executable = b"\x7fELF" + b"a" * (1024**2) + b"crc-tail"
            self.write_linux_archive(
                artifact,
                notice,
                executable=executable,
                compression=ZIP_STORED,
            )
            damaged = artifact.read_bytes().replace(b"crc-tail", b"crc-fail", 1)
            self.assertNotEqual(damaged, artifact.read_bytes())
            artifact.write_bytes(damaged)
            result = self.check(artifact)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("invalid release archive", result.stderr)
        self.assertIn("CRC", result.stderr)
        self.assertNotIn("Traceback", result.stderr)

    def test_checker_rejects_encrypted_native_payload_without_password_fallback(self):
        with tempfile.TemporaryDirectory() as directory:
            notice = self.generated_notice(Path(directory))
            artifact = Path(directory) / "AeroSim-linux.zip"
            self.write_linux_archive(artifact, notice)
            self.mark_first_entry_encrypted(artifact)
            result = self.check(artifact)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("encrypted release archive entry", result.stderr)
        self.assertNotIn("Traceback", result.stderr)

    def test_checker_rejects_encrypted_notice_without_password_fallback(self):
        with tempfile.TemporaryDirectory() as directory:
            notice = self.generated_notice(Path(directory))
            artifact = Path(directory) / "AeroSim-linux.zip"
            with ZipFile(artifact, "w", ZIP_DEFLATED) as archive:
                archive.writestr(LINUX_NOTICE, notice)
                archive.writestr(LINUX_EXECUTABLE, b"\x7fELF executable")
                archive.writestr(LINUX_EXTENSION, b"\x7fELF extension")
                archive.writestr(LINUX_TERRAIN_EXTENSION, b"\x7fELF terrain extension")
            self.mark_first_entry_encrypted(artifact)
            result = self.check(artifact)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("encrypted release archive", result.stderr)
        self.assertNotIn("Traceback", result.stderr)

    def test_checker_rejects_unreadable_native_payload_without_skipping_it(self):
        with tempfile.TemporaryDirectory() as directory:
            notice = self.generated_notice(Path(directory))
            artifact = Path(directory) / "AeroSim-linux.zip"
            self.write_linux_archive(artifact, notice)
            self.set_first_entry_compression(artifact, 99)
            result = self.check(artifact)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unreadable release archive entry", result.stderr)
        self.assertNotIn("Traceback", result.stderr)

    def test_checker_rejects_unreadable_notice_without_skipping_it(self):
        with tempfile.TemporaryDirectory() as directory:
            notice = self.generated_notice(Path(directory))
            artifact = Path(directory) / "AeroSim-linux.zip"
            with ZipFile(artifact, "w", ZIP_DEFLATED) as archive:
                archive.writestr(LINUX_NOTICE, notice)
                archive.writestr(LINUX_EXECUTABLE, b"\x7fELF executable")
                archive.writestr(LINUX_EXTENSION, b"\x7fELF extension")
                archive.writestr(LINUX_TERRAIN_EXTENSION, b"\x7fELF terrain extension")
            self.set_first_entry_compression(artifact, 99)
            result = self.check(artifact)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unreadable release archive notice", result.stderr)
        self.assertNotIn("Traceback", result.stderr)

    def test_checker_rejects_libpython_sonames_in_native_payloads(self):
        sonames = (
            b"libpython.so",
            b"libpython3.so",
            b"libpython3.11.so.1.0",
            b"libpython3.13t.so.1.0",
        )
        with tempfile.TemporaryDirectory() as directory:
            notice = self.generated_notice(Path(directory))
            artifact = Path(directory) / "AeroSim-linux.zip"
            for soname in sonames:
                with self.subTest(soname=soname):
                    self.write_linux_archive(
                        artifact,
                        notice,
                        executable=b"\x7fELF DT_NEEDED " + soname + b"\x00",
                    )
                    result = self.check(artifact)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("libpython runtime dependency marker", result.stderr)

    def test_checker_rejects_cpython_lifecycle_and_execution_evidence(self):
        lifecycle = (
            b"Py_InitializeFromConfig",
            b"Py_InitializeEx",
            b"Py_Initialize",
            b"Py_FinalizeEx",
            b"Py_Finalize",
        )
        execution = (
            b"PyRun_SimpleString",
            b"PyImport_ImportModule",
            b"Py_BytesMain",
            b"Py_RunMain",
            b"Py_Main",
            b"PyEval_EvalCodeEx",
            b"PyEval_EvalCode",
        )
        with tempfile.TemporaryDirectory() as directory:
            notice = self.generated_notice(Path(directory))
            artifact = Path(directory) / "AeroSim-linux.zip"
            cases = [
                (marker, b"PyRun_SimpleString") for marker in lifecycle
            ] + [
                (b"Py_Initialize", marker) for marker in execution
            ]
            for lifecycle_marker, execution_marker in cases:
                with self.subTest(
                    lifecycle=lifecycle_marker,
                    execution=execution_marker,
                ):
                    self.write_linux_archive(
                        artifact,
                        notice,
                        executable=b"\x7fELF " + lifecycle_marker + b"\x00",
                        extension=b"\x7fELF " + execution_marker + b"\x00",
                    )
                    result = self.check(artifact)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("CPython lifecycle and execution markers", result.stderr)

    def test_checker_rejects_oracle_cache_path_in_native_payload(self):
        with tempfile.TemporaryDirectory() as directory:
            notice = self.generated_notice(Path(directory))
            artifact = Path(directory) / "AeroSim-linux.zip"
            self.write_linux_archive(
                artifact,
                notice,
                extension=(
                    b"\x7fELF oracles/gym_pybullet_drones_cache/9bc12bc/BaseAviary.py"
                ),
            )
            result = self.check(artifact)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Oracle cache path marker", result.stderr)

    def test_checker_rejects_complete_base_aviary_source_across_native_payloads(self):
        with tempfile.TemporaryDirectory() as directory:
            notice = self.generated_notice(Path(directory))
            artifact = Path(directory) / "AeroSim-linux.zip"
            self.write_linux_archive(
                artifact,
                notice,
                executable=(
                    b"\x7fELF\nclass BaseAviary(gym.Env):\n"
                    b"    def _drag(self, rpm):\n        pass\n"
                ),
                extension=(
                    b"\x7fELF\n    def _groundEffect(self, rpm):\n        pass\n"
                    b"    def _downwash(self):\n        pass\n"
                ),
            )
            result = self.check(artifact)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("BaseAviary source markers", result.stderr)

    def test_checker_accepts_isolated_cpython_markers_and_boundary_lookalikes(self):
        payloads = (
            b"\x7fELF Py_InitializeFromConfig Py_InitializeEx Py_Initialize "
            b"Py_FinalizeEx Py_Finalize",
            b"\x7fELF PyRun_SimpleString PyImport_ImportModule Py_BytesMain "
            b"Py_RunMain Py_Main PyEval_EvalCodeEx PyEval_EvalCode",
            b"\x7fELF MyPy_Initialize Py_Mainland xlibpython3.11.so.1.0",
        )
        with tempfile.TemporaryDirectory() as directory:
            notice = self.generated_notice(Path(directory))
            artifact = Path(directory) / "AeroSim-linux.zip"
            for payload in payloads:
                with self.subTest(payload=payload):
                    self.write_linux_archive(artifact, notice, executable=payload)
                    result = self.check(artifact)
                    self.assertEqual(result.returncode, 0, result.stderr)

    def test_checker_accepts_partial_base_aviary_source_evidence(self):
        method_definitions = (
            b"    def _drag(self):\n        pass\n",
            b"    def _groundEffect(self):\n        pass\n",
            b"    def _downwash(self):\n        pass\n",
        )
        with tempfile.TemporaryDirectory() as directory:
            notice = self.generated_notice(Path(directory))
            artifact = Path(directory) / "AeroSim-linux.zip"
            for omitted in range(len(method_definitions)):
                with self.subTest(omitted=omitted):
                    source = b"\x7fELF\nclass BaseAviary(gym.Env):\n" + b"".join(
                        definition
                        for index, definition in enumerate(method_definitions)
                        if index != omitted
                    )
                    self.write_linux_archive(artifact, notice, executable=source)
                    result = self.check(artifact)
                    self.assertEqual(result.returncode, 0, result.stderr)

            calls_only = (
                b"\x7fELF\nclass BaseAviary(gym.Env):\n"
                b"    self._drag(rpm)\n    self._groundEffect(rpm)\n"
                b"    self._downwash()\n"
            )
            self.write_linux_archive(artifact, notice, executable=calls_only)
            result = self.check(artifact)
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_checker_accepts_python_names_in_notice_and_native_provenance(self):
        with tempfile.TemporaryDirectory() as directory:
            notice = self.generated_notice(Path(directory)) + (
                "\nProvenance: Python formula reference BaseAviary.py "
                "gym_pybullet_drones at oracles/gym_pybullet_drones_cache/.\n"
            )
            artifact = Path(directory) / "AeroSim-linux.zip"
            self.write_linux_archive(
                artifact,
                notice,
                executable=(
                    b"\x7fELF provenance Python .py BaseAviary.py gym_pybullet_drones"
                ),
            )
            result = self.check(artifact)

        self.assertEqual(result.returncode, 0, result.stderr)


class DeferredReleaseNoticeArtifactsTest(ReleaseArtifactTestCase):
    def test_checker_accepts_deferred_windows_and_android_notice_paths(self):
        archive_paths = {
            "AeroSim-windows.zip": "AeroSim-windows/THIRD_PARTY_NOTICES.txt",
            "AeroSim-android.apk": "assets/THIRD_PARTY_NOTICES.txt",
        }
        for filename, notice_path in archive_paths.items():
            with self.subTest(artifact=filename):
                self.assert_checker_accepts_notice_path(filename, notice_path)


if __name__ == "__main__":
    unittest.main()
