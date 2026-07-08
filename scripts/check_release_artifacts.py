#!/usr/bin/env python3
import argparse
from pathlib import Path
import sys


MAX_BYTES = 300 * 1024 * 1024


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

    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
