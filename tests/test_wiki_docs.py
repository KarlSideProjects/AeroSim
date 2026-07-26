#!/usr/bin/env python3
"""Intent: the developer Wiki stays indexed, traceable, and reviewable."""

from pathlib import Path
import tempfile
import unittest

from scripts import check_docs


WIKI_PAGES = tuple(sorted(check_docs.WIKI_PAGES))


class WikiDocsTest(unittest.TestCase):
    def write_valid_wiki(self, root: Path) -> Path:
        (root / "PRD_AeroSim.md").write_text("# PRD\n", encoding="utf-8")
        wiki = root / "docs" / "wiki"
        wiki.mkdir(parents=True)
        links = "\n".join(
            f"- [{page.removesuffix('.md').replace('-', ' ').title()}]({page})"
            for page in WIKI_PAGES
        )
        (wiki / "README.md").write_text(
            "# Wiki\n\n" + links + "\n", encoding="utf-8"
        )
        for page in WIKI_PAGES:
            name = page.removesuffix(".md")
            (wiki / page).write_text(
                "---\n"
                f"title: {name}\n"
                "aliases:\n"
                f"  - {name}\n"
                "status: maintained\n"
                "sources:\n"
                "  - PRD_AeroSim.md\n"
                "last_verified: 2026-07-26\n"
                "---\n\n"
                f"# {name}\n",
                encoding="utf-8",
            )
        return wiki

    def test_valid_indexed_wiki_passes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.write_valid_wiki(root)
            self.assertEqual([], check_docs.check_wiki(root))

    def test_metadata_and_sources_fail_loud(self):
        with tempfile.TemporaryDirectory() as directory:
            wiki = self.write_valid_wiki(Path(directory))
            page = wiki / "overview.md"
            page.write_text(
                page.read_text(encoding="utf-8")
                .replace("status: maintained", "status: invented")
                .replace("  - PRD_AeroSim.md", "  - missing.md"),
                encoding="utf-8",
            )

            errors = check_docs.check_wiki(Path(directory))

        self.assertTrue(any("無效 status" in error for error in errors), errors)
        self.assertTrue(any("無效 source" in error for error in errors), errors)

    def test_index_alias_and_date_drift_fail_loud(self):
        with tempfile.TemporaryDirectory() as directory:
            wiki = self.write_valid_wiki(Path(directory))
            overview = wiki / "overview.md"
            overview.write_text(
                overview.read_text(encoding="utf-8").replace(
                    "last_verified: 2026-07-26", "last_verified: not-a-date"
                ),
                encoding="utf-8",
            )
            architecture = wiki / "architecture.md"
            architecture.write_text(
                architecture.read_text(encoding="utf-8").replace(
                    "  - architecture", "  - overview"
                ),
                encoding="utf-8",
            )
            (wiki / "README.md").write_text("# Wiki\n", encoding="utf-8")

            errors = check_docs.check_wiki(Path(directory))

        self.assertTrue(any("無效 last_verified" in error for error in errors), errors)
        self.assertTrue(any("重複 alias" in error for error in errors), errors)
        self.assertTrue(any("索引遺漏" in error for error in errors), errors)

    def test_scalar_metadata_cannot_bypass_alias_or_source_validation(self):
        with tempfile.TemporaryDirectory() as directory:
            wiki = self.write_valid_wiki(Path(directory))
            page = wiki / "overview.md"
            page.write_text(
                page.read_text(encoding="utf-8")
                .replace("aliases:\n  - overview", "aliases: overview")
                .replace("sources:\n  - PRD_AeroSim.md", "sources: missing.md"),
                encoding="utf-8",
            )

            errors = check_docs.check_wiki(Path(directory))

        self.assertTrue(any("aliases 必須是清單" in error for error in errors), errors)
        self.assertTrue(any("sources 必須是清單" in error for error in errors), errors)

    def test_aliases_require_an_english_search_term(self):
        with tempfile.TemporaryDirectory() as directory:
            wiki = self.write_valid_wiki(Path(directory))
            page = wiki / "overview.md"
            page.write_text(
                page.read_text(encoding="utf-8").replace(
                    "  - overview", "  - 專案總覽"
                ),
                encoding="utf-8",
            )

            errors = check_docs.check_wiki(Path(directory))

        self.assertTrue(any("必須包含英文 alias" in error for error in errors), errors)

    def test_missing_metadata_and_relative_links_fail_loud(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            wiki = self.write_valid_wiki(root)
            page = wiki / "overview.md"
            page.write_text(
                page.read_text(encoding="utf-8")
                .replace("title: overview\n", "")
                + "\n[Broken](missing.md)\n",
                encoding="utf-8",
            )

            errors = check_docs.check_wiki(root) + check_docs.check_file(root, page)

        self.assertTrue(any("缺少 title" in error for error in errors), errors)
        self.assertTrue(any("壞連結" in error for error in errors), errors)


if __name__ == "__main__":
    unittest.main()
