#!/usr/bin/env python3
"""Small, testable policy shared by the trusted Wiki-sync workflow step."""

import sys

ISSUE_ACTIONS = {"opened", "edited", "closed", "reopened", "labeled", "unlabeled"}


def issue_sync_allowed(action: str, labels: list[str]) -> bool:
    return action in ISSUE_ACTIONS and "wiki-sync" in labels


def main(args: list[str]) -> int:
    if len(args) != 2:
        return 2
    return 0 if issue_sync_allowed(args[0], args[1].split(",")) else 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
