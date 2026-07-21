#!/usr/bin/env python3
"""Check the production UI catalog and authored text sinks."""

import csv
import re
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CATALOG = ROOT / "locales/ui.csv"
PRODUCTION_FILES = [
    ROOT / "common/flight/flight_runtime.gd",
    ROOT / "common/flight/status_diagram_debug.gd",
    ROOT / "levels/free_flight/industrial_yard.tscn",
    ROOT / "levels/smoke/smoke.tscn",
]
PLACEHOLDER = re.compile(r"%(?:[-+#0 ]*\d*(?:\.\d+)?)?[a-zA-Z]")
SINK = re.compile(r"\.(?:text|placeholder_text|tooltip_text)\s*=\s*\"([^\"]*)\"")
SCENE_TEXT = re.compile(r"^text\s*=\s*\"([^\"]*)\"$")
KEY_CALL = re.compile(r"\b(?:_t|_format|translate|format)\(\"([^\"]+)\"")


def placeholders(value: str) -> list[str]:
    return [token for token in PLACEHOLDER.findall(value) if token != "%%"]


def main() -> int:
    errors: list[str] = []
    with CATALOG.open(newline="", encoding="utf-8") as handle:
        rows = list(csv.DictReader(handle))
    if not rows or set(rows[0]) != {"keys", "en", "zh_TW"}:
        errors.append("catalog header must be keys,en,zh_TW")
    keys: set[str] = set()
    for line, row in enumerate(rows, 2):
        key = row.get("keys", "")
        if not key or key in keys:
            errors.append(f"line {line}: missing or duplicate key {key!r}")
        keys.add(key)
        if not row.get("en") or not row.get("zh_TW"):
            errors.append(f"line {line}: {key} has an empty locale")
        if placeholders(row.get("en", "")) != placeholders(row.get("zh_TW", "")):
            errors.append(f"line {line}: {key} has mismatched placeholders")

    for path in PRODUCTION_FILES:
        source = path.read_text(encoding="utf-8")
        text = source.splitlines()
        if path.suffix == ".gd" and re.search(r"create_tween|AnimationPlayer|Tween", source) and "offset_transform" not in source:
            errors.append(f"{path.relative_to(ROOT)}: UI animation must use Control offset transforms")
        for line_number, line in enumerate(text, 1):
            match = SINK.search(line) if path.suffix == ".gd" else SCENE_TEXT.search(line)
            if match and path.suffix == ".tscn" and match.group(1).startswith("ui.") and match.group(1) not in keys:
                errors.append(f"{path.relative_to(ROOT)}:{line_number}: missing catalog key {match.group(1)}")
            if match and match.group(1) not in {r"\n", "-"} and not match.group(1).startswith("ui."):
                errors.append(f"{path.relative_to(ROOT)}:{line_number}: authored UI literal {match.group(1)!r}")
            for key in KEY_CALL.findall(line):
                if "%" not in key and key not in keys:
                    errors.append(f"{path.relative_to(ROOT)}:{line_number}: missing catalog key {key}")

    if errors:
        print("UI localization check failed:")
        print("\n".join(f"- {error}" for error in errors))
        return 1
    print(f"UI localization check passed: {len(keys)} catalog keys and {len(PRODUCTION_FILES)} production files")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
