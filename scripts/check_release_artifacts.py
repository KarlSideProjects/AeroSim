#!/usr/bin/env python3
import argparse
import json
from pathlib import Path
import sys
from zipfile import BadZipFile, ZipFile


MAX_BYTES = 300 * 1024 * 1024
NOTICE_PATHS = {
    "AeroSim-linux.zip": "AeroSim-linux/THIRD_PARTY_NOTICES.txt",
    "AeroSim-windows.zip": "AeroSim-windows/THIRD_PARTY_NOTICES.txt",
    "AeroSim-android.apk": "assets/THIRD_PARTY_NOTICES.txt",
}
REQUIRED_NOTICE_TEXT = (
    "gym-pybullet-drones",
)
MANIFEST = Path(__file__).resolve().parents[1] / "third_party" / "licenses.json"


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
            notice = archive.read(notice_path).decode("utf-8")
    except (BadZipFile, UnicodeDecodeError) as error:
        return f"{path}: invalid release archive notice: {error}"

    for required_text in required_notice_text():
        if required_text not in notice:
            return f"{path}: THIRD_PARTY_NOTICES.txt missing required text: {required_text}"
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

    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
