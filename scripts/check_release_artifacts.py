#!/usr/bin/env python3
"""Release checks; runtime markers are high-signal, not proof against obfuscation."""

import argparse
import json
from pathlib import Path
import re
import sys
import zlib
from zipfile import BadZipFile, ZipFile


MAX_BYTES = 300 * 1024 * 1024
NOTICE_PATHS = {
    "AeroSim-linux.zip": "AeroSim-linux/THIRD_PARTY_NOTICES.txt",
    "AeroSim-windows.zip": "AeroSim-windows/THIRD_PARTY_NOTICES.txt",
    "AeroSim-android.apk": "assets/THIRD_PARTY_NOTICES.txt",
    "AeroSim-android-production.apk": "assets/THIRD_PARTY_NOTICES.txt",
}
REQUIRED_NOTICE_TEXT = (
    "gym-pybullet-drones",
    "Terrain3D",
)
MANIFEST = Path(__file__).resolve().parents[1] / "third_party" / "licenses.json"
LINUX_RELEASE_ENTRIES = {
    "AeroSim-linux/AeroSim.x86_64",
    "AeroSim-linux/libaerosim_native.linux.template_release.x86_64.so",
    "AeroSim-linux/libterrain.linux.release.x86_64.so",
    "AeroSim-linux/THIRD_PARTY_NOTICES.txt",
    "AeroSim-linux/LICENSE",
    "AeroSim-linux/LICENSING.md",
}
LINUX_NATIVE_ENTRIES = (
    "AeroSim-linux/AeroSim.x86_64",
    "AeroSim-linux/libaerosim_native.linux.template_release.x86_64.so",
    "AeroSim-linux/libterrain.linux.release.x86_64.so",
)
LIBPYTHON_RE = re.compile(
    rb"(?<![A-Za-z0-9_])"
    rb"libpython(?:[0-9]+(?:\.[0-9]+)*(?:[a-z]+)?)?"
    rb"\.so(?:\.[0-9]+)*"
    rb"(?![A-Za-z0-9_.])"
)
CPYTHON_LIFECYCLE_RE = re.compile(
    rb"(?<![A-Za-z0-9_])"
    rb"(?:Py_InitializeFromConfig|Py_InitializeEx|Py_Initialize|"
    rb"Py_FinalizeEx|Py_Finalize)"
    rb"(?![A-Za-z0-9_])"
)
CPYTHON_EXECUTION_RE = re.compile(
    rb"(?<![A-Za-z0-9_])"
    rb"(?:PyRun_[A-Za-z0-9_]{1,255}|PyImport_[A-Za-z0-9_]{1,255}|"
    rb"Py_BytesMain|Py_RunMain|Py_Main|"
    rb"PyEval_EvalCodeEx|PyEval_EvalCode)"
    rb"(?![A-Za-z0-9_])"
)
ORACLE_CACHE_MARKER = b"oracles/gym_pybullet_drones_cache/"
BASE_AVIARY_CLASS_RE = re.compile(rb"(?m)^class BaseAviary\(gym\.Env\):[ \t]*\r?$")
BASE_AVIARY_DRAG_RE = re.compile(rb"(?m)^[ \t]+def[ \t]+_drag[ \t]*\(")
BASE_AVIARY_GROUND_EFFECT_RE = re.compile(
    rb"(?m)^[ \t]+def[ \t]+_groundEffect[ \t]*\("
)
BASE_AVIARY_DOWNWASH_RE = re.compile(rb"(?m)^[ \t]+def[ \t]+_downwash[ \t]*\(")
MAX_NOTICE_BYTES = 1 * 1024**2
MAX_NATIVE_BYTES = 256 * 1024**2
MAX_TOTAL_UNCOMPRESSED_BYTES = 300 * 1024**2
SCAN_CHUNK_BYTES = 1 * 1024**2
SCAN_OVERLAP_BYTES = 4096


def scan_native_payload(archive: ZipFile, name: str) -> tuple[bool, set[str]]:
    evidence = set()
    tail = b""
    first_chunk = True
    with archive.open(name) as stream:
        while chunk := stream.read(SCAN_CHUNK_BYTES):
            if first_chunk:
                if not chunk.startswith(b"\x7fELF"):
                    return False, evidence
                first_chunk = False
            window = tail + chunk
            for marker, pattern in (
                ("libpython", LIBPYTHON_RE),
                ("lifecycle", CPYTHON_LIFECYCLE_RE),
                ("execution", CPYTHON_EXECUTION_RE),
                ("class", BASE_AVIARY_CLASS_RE),
                ("drag", BASE_AVIARY_DRAG_RE),
                ("ground_effect", BASE_AVIARY_GROUND_EFFECT_RE),
                ("downwash", BASE_AVIARY_DOWNWASH_RE),
            ):
                if pattern.search(window):
                    evidence.add(marker)
            if ORACLE_CACHE_MARKER in window:
                evidence.add("oracle_cache")
            tail = window[-SCAN_OVERLAP_BYTES:]
    return not first_chunk, evidence


def required_notice_text() -> tuple[str, ...]:
    dependencies = json.loads(MANIFEST.read_text(encoding="utf-8"))["dependencies"]
    entries = {
        item["name"]: item
        for item in dependencies
        if item["name"] in {"gym-pybullet-drones", "Terrain3D"}
    }
    gym = entries["gym-pybullet-drones"]
    terrain = entries["Terrain3D"]
    return (
        *REQUIRED_NOTICE_TEXT,
        f"Attribution scope: {gym['attribution_scope']}",
        gym["notice"],
        f"Attribution scope: {terrain['attribution_scope']}",
        terrain["notice"],
    )


def check_notice(path: Path) -> str | None:
    notice_path = NOTICE_PATHS.get(path.name)
    if not notice_path:
        return None
    try:
        with ZipFile(path) as archive:
            if notice_path not in archive.namelist():
                return f"{path}: missing THIRD_PARTY_NOTICES.txt at {notice_path}"
            if archive.getinfo(notice_path).flag_bits & 1:
                return f"{path}: encrypted release archive notice: {notice_path}"
            notice = archive.read(notice_path).decode("utf-8")
    except (BadZipFile, UnicodeDecodeError, zlib.error) as error:
        return f"{path}: invalid release archive notice: {error}"
    except (NotImplementedError, OSError, RuntimeError) as error:
        return f"{path}: unreadable release archive notice: {error}"

    for required_text in required_notice_text():
        if required_text not in notice:
            return f"{path}: THIRD_PARTY_NOTICES.txt missing required text: {required_text}"
    return None


def check_linux_release(path: Path) -> str | None:
    if path.name != "AeroSim-linux.zip":
        return None
    try:
        with ZipFile(path) as archive:
            names = archive.namelist()
            entries = set(names)
            if len(names) != len(entries):
                return f"{path}: duplicate release archive entry"
            if NOTICE_PATHS[path.name] not in entries:
                return f"{path}: missing THIRD_PARTY_NOTICES.txt at {NOTICE_PATHS[path.name]}"
            if entries != LINUX_RELEASE_ENTRIES:
                return f"{path}: unexpected release archive entries"
            infos = {info.filename: info for info in archive.infolist()}
            if infos[NOTICE_PATHS[path.name]].file_size > MAX_NOTICE_BYTES:
                return f"{path}: release archive notice exceeds 1 MB"
            for name in LINUX_NATIVE_ENTRIES:
                if infos[name].file_size > MAX_NATIVE_BYTES:
                    return f"{path}: native payload exceeds 256 MB: {name}"
            if sum(info.file_size for info in infos.values()) > MAX_TOTAL_UNCOMPRESSED_BYTES:
                return f"{path}: release archive exceeds 300 MB uncompressed"
            for info in infos.values():
                if info.flag_bits & 1:
                    return f"{path}: encrypted release archive entry: {info.filename}"
            for filename in ("LICENSE", "LICENSING.md"):
                name = f"AeroSim-linux/{filename}"
                expected = (MANIFEST.parent.parent / filename).read_bytes()
                if infos[name].file_size != len(expected) or archive.read(name) != expected:
                    return f"{path}: release {filename} does not match repository terms"
            evidence = set()
            for name in LINUX_NATIVE_ENTRIES:
                is_elf, payload_evidence = scan_native_payload(archive, name)
                if not is_elf:
                    return f"{path}: native payload is not ELF: {name}"
                evidence.update(payload_evidence)
            if "libpython" in evidence:
                return f"{path}: libpython runtime dependency marker in native payload"
            if {"lifecycle", "execution"} <= evidence:
                return f"{path}: CPython lifecycle and execution markers in native payloads"
            if "oracle_cache" in evidence:
                return f"{path}: Oracle cache path marker in native payload"
            if {"class", "drag", "ground_effect", "downwash"} <= evidence:
                return f"{path}: BaseAviary source markers in native payloads"
    except (BadZipFile, zlib.error) as error:
        return f"{path}: invalid release archive entry (corrupt or malformed): {error}"
    except (NotImplementedError, OSError, RuntimeError) as error:
        return f"{path}: unreadable release archive entry: {error}"
    return None


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("artifacts", nargs="+")
    parser.add_argument("--max-mb", type=int, default=300)
    args = parser.parse_args()

    max_bytes = args.max_mb * 1024 * 1024
    ok = True
    for artifact in args.artifacts:
        path = Path(artifact)
        if not path.is_file():
            print(f"missing artifact: {path}", file=sys.stderr)
            ok = False
            continue
        size = path.stat().st_size
        print(f"{path}: {size} bytes")
        if size > max_bytes:
            print(
                f"artifact too large: {path} exceeds {args.max_mb} MB",
                file=sys.stderr,
            )
            ok = False
            continue
        try:
            linux_error = check_linux_release(path)
            if linux_error:
                print(linux_error, file=sys.stderr)
                ok = False
                continue
            notice_error = check_notice(path)
            if notice_error:
                print(notice_error, file=sys.stderr)
                ok = False
        except MemoryError:
            print(f"{path}: resource limit exceeded while checking artifact", file=sys.stderr)
            ok = False

    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
