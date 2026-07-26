#!/usr/bin/env python3
"""Intent: only approved issue lifecycle events can request Wiki analysis."""

import unittest

from scripts.wiki_sync_policy import ISSUE_ACTIONS, issue_sync_allowed


class WikiSyncPolicyTest(unittest.TestCase):
    def test_allowlist_matches_the_documented_issue_lifecycle(self):
        self.assertEqual(
            {"opened", "edited", "closed", "reopened", "labeled", "unlabeled"},
            ISSUE_ACTIONS,
        )

    def test_label_is_required_even_for_supported_events(self):
        self.assertTrue(issue_sync_allowed("closed", ["wiki-sync", "slice"]))
        self.assertFalse(issue_sync_allowed("closed", ["slice"]))

    def test_unknown_event_is_rejected(self):
        self.assertFalse(issue_sync_allowed("commented", ["wiki-sync"]))


if __name__ == "__main__":
    unittest.main()
