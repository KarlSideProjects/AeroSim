#!/usr/bin/env python3
"""Release checks; runtime markers are high-signal, not proof against obfuscation."""

import argparse
import json
from pathlib import Path
import re
import sys
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
)
MANIFEST = Path(__file__).resolve().parents[1] / "third_party" / "licenses.json"
LINUX_RELEASE_ENTRIES = {
    "AeroSim-linux/AeroSim.x86_64",
    "AeroSim-linux/libaerosim_native.linux.template_release.x86_64.so",
    "AeroSim-linux/THIRD_PARTY_NOTICES.txt",
}
LINUX_NATIVE_ENTRIES = (
    "AeroSim-linux/AeroSim.x86_64",
    "AeroSim-linux/libaerosim_native.linux.template_release.x86_64.so",
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
    rb"(?:PyRun_[A-Za-z0-9_]+|PyImport_[A-Za-z0-9_]+|"
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


def required_notice_text() -> tuple[str, ...]:
    dependencies = json.loads(MANIFEST.read_text(encoding="utf-8"))["dependencies"]
    entry = next(item for item in dependencies if item["name"] == "gym-pybullet-drones")
    return (
        *REQUIRED_NOTICE_TEXT,
        f"Attribution scope: {entry['attribution_scope']}",
        entry["notice"],
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
    except (BadZipFile, UnicodeDecodeError) as error:
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
            if entries != LINUX_RELEASE_ENTRIES:
                return f"{path}: unexpected release archive entries"
            for info in archive.infolist():
                if info.flag_bits & 1:
                    return f"{path}: encrypted release archive entry: {info.filename}"
            native_payloads = tuple(archive.read(name) for name in LINUX_NATIVE_ENTRIES)
            for name, payload in zip(LINUX_NATIVE_ENTRIES, native_payloads):
                if not payload.startswith(b"\x7fELF"):
                    return f"{path}: native payload is not ELF: {name}"
            if any(LIBPYTHON_RE.search(payload) for payload in native_payloads):
                return f"{path}: libpython runtime dependency marker in native payload"
            if (
                any(CPYTHON_LIFECYCLE_RE.search(payload) for payload in native_payloads)
                and any(CPYTHON_EXECUTION_RE.search(payload) for payload in native_payloads)
            ):
                return f"{path}: CPython lifecycle and execution markers in native payloads"
            if any(ORACLE_CACHE_MARKER in payload for payload in native_payloads):
                return f"{path}: Oracle cache path marker in native payload"
            if all(
                any(marker.search(payload) for payload in native_payloads)
                for marker in (
                    BASE_AVIARY_CLASS_RE,
                    BASE_AVIARY_DRAG_RE,
                    BASE_AVIARY_GROUND_EFFECT_RE,
                    BASE_AVIARY_DOWNWASH_RE,
                )
            ):
                return f"{path}: BaseAviary source markers in native payloads"
    except BadZipFile as error:
        return f"{path}: invalid release archive: {error}"
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
        notice_error = check_notice(path)
        if notice_error:
            print(notice_error, file=sys.stderr)
            ok = False
        linux_error = check_linux_release(path)
        if linux_error:
            print(linux_error, file=sys.stderr)
            ok = False

    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
