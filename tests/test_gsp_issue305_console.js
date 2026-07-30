const assert = require("node:assert/strict");
const fs = require("node:fs");

const panel = fs.readFileSync("common/gsp/gsp_panel.html", "utf8");

for (const text of ["即時狀態", "工程設定", "Nominal geometry", "Commanded", "Ground truth", "Estimated", "Measured", "wind-preview", "wind-apply", "command-chart", "rpm-chart"]) {
    assert.match(panel, new RegExp(text));
}
assert.match(panel, /#live-console\s*\{[^}]*overflow:\s*hidden/);
assert.match(panel, /@media \(prefers-reduced-motion: reduce\)/);
assert.doesNotMatch(panel, /https?:\/\//);
assert.doesNotMatch(panel, /<script[^>]+src="(?!assets\/)/);
console.log("GSP issue 305 console contract passed");
