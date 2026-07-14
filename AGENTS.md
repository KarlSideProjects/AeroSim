# Repository Guidelines

## Project Structure & Module Organization

This is a Godot 4.7 drone-simulation project with a C++17 GDExtension. Native simulation, flight control, IMU, collision, and replay code live in `src/native/`; public Godot bindings are registered in `register_types.cpp`. Godot gameplay code is in `common/flight/`, and the smoke scene is `levels/smoke/smoke.tscn`. Keep airframe presets and schema data in `config/drones/` and `config/drone_schema.json`; do not add airframe constants to runtime code. Native tests live in `tests/native/`, while headless integration coverage is `common/smoke/headless_smoke.gd`. Design notes and release material belong in `docs/`.

## Build, Test, and Development Commands

- `scripts/test_native.sh` compiles every `tests/native/test_*.cpp` with C++17 warnings as errors, then runs it.
- `scripts/check_hardcoded_airframe_constants.sh` rejects model constants outside the hardware configuration path.
- `scripts/test_license_scan.sh` verifies dependency-license scanning, including its GPL rejection fixture.
- `python3 -m unittest license_server.test_license_server` runs the license-server API tests.
- `GODOT_CPP_DIR=/path/to/godot-cpp scons target=template_debug platform=linux` builds the Linux GDExtension.
- `GODOT_BIN=/path/to/Godot_v4.7-stable_linux.x86_64 scripts/run_headless_smoke.sh --output build/headless_smoke.json --frames 5` runs the Godot/native smoke path.

For the full Linux gate, set `RUNNER_TEMP` and run `GODOT_BIN=... RUNNER_TEMP=/tmp/aerosim-ci scripts/verify_issue_11.sh`. It fetches the pinned `godot-cpp` revision and creates build artifacts.

## Coding Style & Naming Conventions

Use four spaces in C++ and GDScript. Keep C++ in the `aerosim` namespace; use `PascalCase` types, `snake_case` functions and variables, and `kPascalCase` constants. GDScript uses `PascalCase` preloads/classes, `snake_case` members and functions, and typed declarations where practical. Preserve deterministic flags (`-ffp-contract=off` or `/fp:strict`) and route hardware values through `hardware_config.gd` and JSON presets.

## Testing Guidelines

Name native tests `tests/native/test_<area>.cpp`; each is a standalone executable that returns failure with a reason. Add a behavior-focused assertion for each simulation change, especially deterministic replay or configuration behavior. Run the narrow test first, then `scripts/test_native.sh`; run headless smoke for binding, scene, or GDScript changes. CI runs the Linux native, headed, release, replay, and recovery gates; other platform work remains explicitly deferred or build-only until its workflow is restored.

## Commits & Pull Requests

Use short imperative subjects, matching history: `Fix ACRO collision authority handoff` or `feat: add hardware parameter config`. Include an issue number when applicable. PRs should state the behavior changed, link the issue, list commands run and results, and include screenshots or recordings for visible Godot UI changes. Keep unrelated working-tree changes out of the PR.

## Development Reference & Agent Policy

Use the project Codex configuration in `.codex/config.toml`: implementation work defaults to `gpt-5.6-luna` with high reasoning effort. For a bounded, ambiguous, high-value implementation question, the main agent may ask the read-only `sol_advisor` custom agent, which uses `gpt-5.6-sol` with high reasoning effort. The main agent remains responsible for checking the answer and making the decision. If the selected model is unavailable, report that fact; do not silently claim that a different model was used.

The read-only AirSim reference checkout lives outside this repository at the main checkout root's sibling `../AirSim-reference`, pinned to tag `v1.8.1`, commit `96235148a332fe7cb3d3525a0720e26faaca99e0`. Resolve it from the main checkout root (the parent of `git rev-parse --git-common-dir`) so linked worktrees use the same checkout. Before adapting AirSim code or behavior, follow `docs/airsim_reference_policy.md`: identify the exact source path and symbol, search relevant open and closed Microsoft AirSim issues, and record the sources, issue findings, license disposition, and resulting tests in the implementing issue or pull request.

Do not request human visual or usability review until the Playable Game Milestone in CAP-006 passes. Before that milestone, deterministic checks and Codex AI Visual Verification still run and produce provisional evidence. After it passes, a person performs the first formal game review and approves the initial visual reference.
