# GSP Three.js runtime

- Source package: `three` 0.180.0
- License: MIT; see `THREE-LICENSE`.
- Generated runtime: `three-0.180.0.global.min.js`
- Generated SHA-256: `9e80ed95a3bcbb77bb1d6024de9f7f4cc7d6a9745a322f88052edd29e9faa737`
- Build entry: `scripts/gsp_three_entry.js`
- Build command: `npx esbuild scripts/gsp_three_entry.js --bundle --format=iife --global-name=THREE --minify --outfile=common/gsp/assets/three-0.180.0.global.min.js`
- Runtime scope: a self-contained classic script for GSP's `file://` panel; it exports `THREE` and `RoomEnvironment` without network access.
