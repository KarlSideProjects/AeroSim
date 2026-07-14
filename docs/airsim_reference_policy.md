# AirSim Reference Policy

This policy controls how AeroSim may use Microsoft AirSim as an implementation and compatibility reference. AirSim is a reference, not a runtime dependency or a scene source.

## Pinned reference checkout

| Field | Value |
|---|---|
| Repository | `https://github.com/microsoft/airsim.git` |
| Local checkout | sibling of the main checkout root: `../AirSim-reference` |
| Tag | `v1.8.1` |
| Commit | `96235148a332fe7cb3d3525a0720e26faaca99e0` |
| License | MIT; retain required notices for adapted code |

The checkout is read-only working material and must not be committed or copied wholesale into AeroSim. Unreal maps, packaged `.pak` files, UMG, Blueprint, engine integration, and release binaries are not production inputs. Godot UI remains native `Control` scenes, and production world assets remain approved glTF or GLB inputs.

## Required audit before adaptation

Before adapting an AirSim source path, symbol, protocol behavior, setting, or test fixture:

1. Record the exact AirSim path, symbol or setting name, tag, and commit.
2. Search the Microsoft AirSim repository's open and closed issues for the exact symbol or setting and for behavior-level synonyms. Include platform, sensor, coordinate, timing, or concurrency terms when relevant.
3. Read relevant linked pull requests, documentation, and maintainer conclusions. An empty search result is evidence of a search, not evidence that the behavior is correct.
4. In the implementing AeroSim issue or pull request, record the queries, relevant issue URLs, applicability assessment, license or attribution disposition, and the AeroSim tests created from the findings.
5. Implement against AeroSim's frozen compatibility manifest and observable behavior. Do not copy an upstream assumption merely because it exists in AirSim code.

Resolve the reference from the main checkout root so the commands work in linked worktrees. An explicit `AEROSIM_AIRSIM_REFERENCE` override is supported for CI or nonstandard layouts:

```bash
AEROSIM_GIT_COMMON_DIR="$(git rev-parse --path-format=absolute --git-common-dir)"
AEROSIM_REPO_ROOT="$(dirname "$AEROSIM_GIT_COMMON_DIR")"
AEROSIM_AIRSIM_REFERENCE="${AEROSIM_AIRSIM_REFERENCE:-$AEROSIM_REPO_ROOT/../AirSim-reference}"
```

Useful read-only commands then include:

```bash
git -C "$AEROSIM_AIRSIM_REFERENCE" show --stat v1.8.1
gh issue list --repo microsoft/AirSim --state all --search 'SYMBOL_OR_BEHAVIOR' --limit 100
gh issue view ISSUE_NUMBER --repo microsoft/AirSim --comments
```

## Pull request evidence template

```text
AirSim reference: v1.8.1 @ 96235148a332fe7cb3d3525a0720e26faaca99e0
Paths/symbols:
Issue searches:
Relevant upstream issues and disposition:
License/attribution:
AeroSim tests derived from findings:
```

If an upstream issue shows that the reference behavior is broken, unstable, platform-specific, or internally inconsistent, the AeroSim issue must explicitly choose one of: preserve it for client compatibility, correct it behind an AeroSim extension, or mark it unsupported with an actionable error.
