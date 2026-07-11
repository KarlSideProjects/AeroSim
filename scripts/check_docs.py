#!/usr/bin/env python3
"""Docs lane 快速檢查：Markdown 相對連結必須指向存在的檔案。

僅用標準庫。掃描 repo 內所有 .md（排除 .deps/build 等產物目錄），
對 [text](path) 形式的相對連結驗證目標存在；http(s)/mailto/純錨點跳過。
發現壞連結時列出並以非零退出（fail loud）。
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

SKIP_DIRS = {".git", ".deps", "build", "bin", "node_modules", ".godot"}
LINK_RE = re.compile(r"\[[^\]]*\]\(([^)\s]+)\)")


def iter_md_files(root: Path):
    for path in root.rglob("*.md"):
        if any(part in SKIP_DIRS for part in path.parts):
            continue
        yield path


def check_file(root: Path, md: Path) -> list[str]:
    errors: list[str] = []
    in_fence = False
    for lineno, line in enumerate(md.read_text(encoding="utf-8").splitlines(), 1):
        if line.lstrip().startswith("```"):
            in_fence = not in_fence
            continue
        if in_fence:
            continue
        for target in LINK_RE.findall(line):
            if target.startswith(("http://", "https://", "mailto:", "#")):
                continue
            rel = target.split("#", 1)[0]
            if not rel:
                continue
            base = root if rel.startswith("/") else md.parent
            resolved = (base / rel.lstrip("/")).resolve()
            if not resolved.exists():
                errors.append(f"{md.relative_to(root)}:{lineno}: 壞連結 -> {target}")
    return errors


def main() -> int:
    root = Path(__file__).resolve().parent.parent
    errors: list[str] = []
    count = 0
    for md in iter_md_files(root):
        count += 1
        errors.extend(check_file(root, md))
    if errors:
        print(f"docs 檢查失敗（掃描 {count} 檔）：")
        print("\n".join(errors))
        return 1
    print(f"docs 檢查通過（掃描 {count} 檔，相對連結全數存在）")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
