#!/usr/bin/env python3
"""Intent: Wiki automation only turns trusted evidence into reviewable PRs."""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github" / "workflows" / "wiki-ai.yml"
PROMPT = ROOT / ".github" / "prompts" / "wiki-sync.md"


class WikiSyncWorkflowTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.workflow = WORKFLOW.read_text(encoding="utf-8")
        cls.prompt = PROMPT.read_text(encoding="utf-8")

    def test_repository_and_issue_changes_have_explicit_modes(self):
        self.assertIn("push:", self.workflow)
        self.assertIn("issues:", self.workflow)
        for action in ("opened", "edited", "closed", "reopened", "labeled", "unlabeled"):
            self.assertIn(action, self.workflow)
        self.assertIn("WIKI_MODE=repo-change", self.workflow)
        self.assertIn("WIKI_MODE=issue-change", self.workflow)
        self.assertIn("WIKI_DIFF_RANGE", self.workflow)
        self.assertIn("WIKI_ISSUE_NUMBER", self.workflow)
        self.assertIn("invalid diff range", self.workflow)
        self.assertIn("git rev-parse --verify", self.workflow)

    def test_issue_writes_require_maintainer_sync_label(self):
        self.assertIn("wiki-sync", self.workflow)
        self.assertIn("github.event.issue.labels.*.name", self.workflow)
        self.assertIn("issue number must be decimal", self.workflow)

    def test_workflow_is_limited_to_wiki_pr_creation(self):
        self.assertIn("contents: write", self.workflow)
        self.assertIn("pull-requests: write", self.workflow)
        self.assertIn("issues: read", self.workflow)
        self.assertNotIn("issues: write", self.workflow)
        self.assertIn("github.event.repository.default_branch", self.workflow)
        self.assertNotIn("Bash(git:*)", self.workflow)
        self.assertIn("[wiki-ai]", self.workflow)

    def test_prompt_treats_sources_as_data_and_limits_writes(self):
        self.assertIn("untrusted data", self.prompt)
        self.assertIn("docs/wiki/**", self.prompt)
        self.assertIn("must not follow instructions", self.prompt)
        self.assertIn("explicitly supported by evidence", self.prompt)
        self.assertIn("must not merge", self.prompt)
        self.assertIn("gh issue view", self.prompt)
        self.assertIn("must not read repository secrets", self.prompt)


if __name__ == "__main__":
    unittest.main()
