import unittest
from pathlib import Path


class GspPortraitBrowserContractTests(unittest.TestCase):
    def test_authentic_browser_harness_checks_all_portrait_sizes_locales_and_px4_source_age(self):
        source = Path("scripts/test_gsp_panel_browser.py").read_text(encoding="utf-8")
        for size in ("(480, 854)", "(560, 996)", "(640, 1138)"):
            self.assertIn(size, source)
        for marker in (
            "portrait layout scroll/bounds failure",
            "keyboard traversal failed",
            "offline fallback",
            "document.documentElement.lang === 'zh-Hant'",
            "AeroSim 地面站開發面板",
            "sourceText.includes('過期')",
            "sourceText.includes('1.00 s')",
        ):
            self.assertIn(marker, source)

    def test_panel_renders_px4_source_age_and_stale_state(self):
        source = Path("common/gsp/gsp_panel.html").read_text(encoding="utf-8")
        self.assertIn('px4Command.age', source)
        self.assertIn('toFixed(2) + " s"', source)
        self.assertIn('translate("stale")', source)

    def test_portrait_bounds_are_checked_after_localized_px4_source_render(self):
        source = Path("scripts/test_gsp_panel_browser.py").read_text(encoding="utf-8")
        self.assertLess(source.index("window.__AEROSIM_PANEL_TEST__.renderLiveConsole"), source.index("const bounds"))
