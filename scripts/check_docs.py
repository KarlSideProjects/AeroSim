#!/usr/bin/env python3
"""Docs lane 快速檢查：Markdown 相對連結必須指向存在的檔案。

僅用標準庫。掃描 repo 內所有 .md（排除 .deps/build 等產物目錄），
對 [text](path) 形式的相對連結驗證目標存在；http(s)/mailto/純錨點跳過。
發現壞連結時列出並以非零退出（fail loud）。
"""
from __future__ import annotations

import re
import sys
from datetime import date
from pathlib import Path

SKIP_DIRS = {".git", ".deps", "build", "bin", "node_modules", ".godot"}
LINK_RE = re.compile(r"\[[^\]]*\]\(([^)\s]+)\)")
WIKI_PAGES = {
    "overview.md",
    "architecture.md",
    "capabilities.md",
    "flight-control-and-compatibility.md",
    "glossary.md",
    "maintenance.md",
}
WIKI_STATUSES = {"maintained", "historical", "superseded"}
ISSUE_SOURCE_RE = re.compile(
    r"https://github\.com/jhihweijhan/AeroSim/(?:issues|pull)/\d+/?$"
)


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


def check_workflows(root: Path) -> list[str]:
    try:
        import yaml
    except ImportError:
        return ["scripts/check_docs.py: 找不到 PyYAML，無法驗證 workflow YAML（fail loud）"]
    errors: list[str] = []
    for wf in sorted((root / ".github" / "workflows").glob("*.yml")):
        try:
            yaml.safe_load(wf.read_text(encoding="utf-8"))
        except yaml.YAMLError as exc:
            errors.append(f"{wf.relative_to(root)}: YAML 解析失敗 -> {exc}")
    return errors


def parse_front_matter(path: Path) -> tuple[dict[str, str | list[str]], list[str]]:
    lines = path.read_text(encoding="utf-8").splitlines()
    if not lines or lines[0] != "---":
        return {}, ["缺少 YAML front matter"]
    try:
        end = lines.index("---", 1)
    except ValueError:
        return {}, ["YAML front matter 未關閉"]

    metadata: dict[str, str | list[str]] = {}
    errors: list[str] = []
    list_key: str | None = None
    for line in lines[1:end]:
        if line.startswith("  - "):
            if list_key is None:
                errors.append("front matter list 缺少欄位")
                continue
            value = line.removeprefix("  - ").strip()
            if not value:
                errors.append(f"{list_key} 包含空值")
                continue
            values = metadata[list_key]
            assert isinstance(values, list)
            values.append(value)
            continue
        if ":" not in line:
            errors.append(f"front matter 無法解析 -> {line}")
            list_key = None
            continue
        key, value = (part.strip() for part in line.split(":", 1))
        if not key:
            errors.append("front matter 欄位名稱不可為空")
            list_key = None
            continue
        if value:
            metadata[key] = value.strip('"')
            list_key = None
        else:
            metadata[key] = []
            list_key = key
    return metadata, errors


def valid_source(root: Path, wiki: Path, source: str) -> bool:
    if ISSUE_SOURCE_RE.fullmatch(source):
        return True
    resolved = (root / source).resolve()
    try:
        resolved.relative_to(root)
    except ValueError:
        return False
    return resolved.exists() and wiki.resolve() not in resolved.parents


def indexed_wiki_pages(wiki: Path) -> set[str]:
    index = wiki / "README.md"
    if not index.exists():
        return set()
    pages: set[str] = set()
    for target in LINK_RE.findall(index.read_text(encoding="utf-8")):
        relative = target.split("#", 1)[0]
        if not relative or relative.startswith(("http://", "https://", "#")):
            continue
        resolved = (index.parent / relative).resolve()
        if resolved.parent == wiki.resolve() and resolved.suffix == ".md":
            pages.add(resolved.name)
    return pages


def check_wiki(root: Path) -> list[str]:
    wiki = root / "docs" / "wiki"
    if not wiki.is_dir():
        return ["docs/wiki: 缺少可索引 Wiki"]

    errors: list[str] = []
    existing = {page.name for page in wiki.glob("*.md") if page.name != "README.md"}
    for page in sorted(WIKI_PAGES - existing):
        errors.append(f"docs/wiki: 缺少核心頁面 -> {page}")

    indexed = indexed_wiki_pages(wiki)
    for page in sorted(existing - indexed):
        errors.append(f"docs/wiki/README.md: 索引遺漏 -> {page}")

    aliases: dict[str, Path] = {}
    for page in sorted(wiki.glob("*.md")):
        if page.name == "README.md":
            continue
        metadata, page_errors = parse_front_matter(page)
        prefix = str(page.relative_to(root))
        errors.extend(f"{prefix}: {error}" for error in page_errors)
        required_types = {
            "title": str,
            "aliases": list,
            "status": str,
            "sources": list,
            "last_verified": str,
        }
        for key, expected_type in required_types.items():
            if key not in metadata or not metadata[key]:
                errors.append(f"{prefix}: 缺少 {key}")
            elif not isinstance(metadata[key], expected_type):
                kind = "清單" if expected_type is list else "文字"
                errors.append(f"{prefix}: {key} 必須是{kind}")

        status = metadata.get("status")
        if isinstance(status, str) and status not in WIKI_STATUSES:
            errors.append(f"{prefix}: 無效 status -> {status}")

        last_verified = metadata.get("last_verified")
        if isinstance(last_verified, str):
            try:
                date.fromisoformat(last_verified)
            except ValueError:
                errors.append(f"{prefix}: 無效 last_verified -> {last_verified}")

        page_aliases = metadata.get("aliases")
        if isinstance(page_aliases, list):
            if not any(re.search(r"[A-Za-z]", alias) for alias in page_aliases):
                errors.append(f"{prefix}: aliases 必須包含英文 alias")
            for alias in page_aliases:
                key = alias.casefold()
                if key in aliases:
                    errors.append(
                        f"{prefix}: 重複 alias -> {alias}（已在 {aliases[key].relative_to(root)}）"
                    )
                else:
                    aliases[key] = page

        sources = metadata.get("sources")
        if isinstance(sources, list):
            for source in sources:
                if not valid_source(root, wiki, source):
                    errors.append(f"{prefix}: 無效 source -> {source}")
    return errors


def main() -> int:
    root = Path(__file__).resolve().parent.parent
    errors: list[str] = []
    count = 0
    for md in iter_md_files(root):
        count += 1
        errors.extend(check_file(root, md))
    errors.extend(check_workflows(root))
    errors.extend(check_wiki(root))
    if errors:
        print(f"docs 檢查失敗（掃描 {count} 檔）：")
        print("\n".join(errors))
        return 1
    print(f"docs 檢查通過（掃描 {count} 檔，相對連結全數存在）")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
