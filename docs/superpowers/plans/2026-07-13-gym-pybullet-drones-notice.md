# gym-pybullet-drones NOTICE Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the pinned gym-pybullet-drones MIT attribution to the generated release NOTICE, with an explicit Formula Port-only scope and drift regression coverage.

**Architecture:** `third_party/licenses.json` remains the release-notice source. A narrow `attribution_scope` field records what the attribution covers; `scripts/check_licenses.py` validates it and renders it adjacent to the dependency notice. A Python regression test reads the manifest, the #117 oracle contract, and generated NOTICE so divergence fails under the existing CI license-scan step.

**Tech Stack:** Python 3 standard library, JSON manifest, shell CI test wrapper.

## Global Constraints

- Canonical repository URL: `https://github.com/learnsyslab/gym-pybullet-drones`.
- Pinned commit: `9bc12bc583fa3b28807b2f90a8cadf09fb06e1ff`.
- The entry is MIT and includes the complete upstream license text beginning `Copyright (c) 2020 Jacopo Panerati`.
- Attribution applies only to AeroSim source-code/formula ports; it does not grant redistribution rights for papers, experimental datasets, or upstream constants/parameter tables.
- Do not add PyBullet or any Python runtime dependency, or change native/runtime/collision/PRD/decision files.

---

### Task 1: Add Manifest, NOTICE, And Contract Drift Regression

**Files:**
- Create: `tests/test_gym_pybullet_drones_notice.py`
- Modify: `scripts/test_license_scan.sh`
- Modify: `third_party/licenses.json`

**Interfaces:**
- Consumes: `third_party/licenses.json`, `oracles/gym_pybullet_drones_contract.json`, and `scripts/check_licenses.py --notice-out <path>`.
- Produces: a regression test that CI executes through `scripts/test_license_scan.sh`.

- [ ] **Step 1: Write the failing test**

```python
entry = next(item for item in dependencies if item["name"] == "gym-pybullet-drones")
self.assertEqual(entry["homepage"], contract["repository_url"])
self.assertEqual(entry["version"], contract["commit"])
self.assertIn("Copyright (c) 2020 Jacopo Panerati", notice)
self.assertIn("Permission is hereby granted", notice)
self.assertIn("does not grant redistribution rights", entry["attribution_scope"])
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `python3 tests/test_gym_pybullet_drones_notice.py`

Expected: `FAIL` because the manifest has no `gym-pybullet-drones` entry.

- [ ] **Step 3: Write the minimal implementation**

```python
scope = dependency.get("attribution_scope")
if scope:
    lines.append(f"Attribution scope: {scope}")
```

```json
{
  "name": "gym-pybullet-drones",
  "version": "9bc12bc583fa3b28807b2f90a8cadf09fb06e1ff",
  "homepage": "https://github.com/learnsyslab/gym-pybullet-drones",
  "license": "MIT",
  "attribution_scope": "...",
  "notice": "MIT License\\n\\nCopyright (c) 2020 Jacopo Panerati..."
}
```

- [ ] **Step 4: Run focused checks to verify they pass**

Run: `python3 tests/test_gym_pybullet_drones_notice.py && scripts/test_license_scan.sh`

Expected: both commands exit 0; the generated notice contains the exact URL, commit, complete MIT text, and attribution scope.

### Task 2: Record The Scope Boundary And Verify The Release Checks

**Files:**
- Modify: `docs/python_oracles.md`

**Interfaces:**
- Consumes: the manifest ownership and scope from Task 1.
- Produces: the durable developer-facing boundary for source-code/formula ports versus non-redistributable upstream materials.

- [ ] **Step 1: Add the precise scope statement**

```markdown
The MIT attribution applies to AeroSim's ported source-code/formula implementations only. It does not claim a redistribution right for upstream papers/PDFs, experimental datasets, or constants/parameter tables.
```

- [ ] **Step 2: Run documentation and release checks**

Run: `python3 scripts/check_docs.py && python3 scripts/check_licenses.py && scripts/test_license_scan.sh && git diff --check`

Expected: all commands exit 0.
