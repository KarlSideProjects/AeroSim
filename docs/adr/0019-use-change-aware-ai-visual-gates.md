# Use change-aware AI visual gates

Deterministic scene structure, dependency, collision, rendering, and basic image checks will run on every pull request. Codex AI Visual Verification will run when scene, asset, material, lighting, or UI inputs change and for every release, using a versioned rubric with stored inputs, reviewer model identity, and JSON results. This keeps routine CI predictable while making semantic visual review mandatory whenever appearance can change and before shipping.
