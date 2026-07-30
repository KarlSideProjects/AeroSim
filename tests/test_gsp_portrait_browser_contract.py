import unittest
from pathlib import Path


class GspPortraitBrowserContractTests(unittest.TestCase):
    def test_authentic_browser_harness_checks_all_portrait_sizes_and_offline_state(self):
        source = Path("scripts/test_gsp_panel_browser.py").read_text(encoding="utf-8")
        for size in ("(480, 854)", "(560, 996)", "(640, 1138)"):
            self.assertIn(size, source)
        for marker in ("portrait layout scroll/bounds failure", "keyboard traversal failed", "offline fallback", "language-zh", "language-en", "source-commanded"):
            self.assertIn(marker, source)
