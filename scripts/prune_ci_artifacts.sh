#!/usr/bin/env bash
# Keep only the most recent CI evidence runs for one repository.
#
# The self-hosted runner stores a full evidence copy per run under
# $AEROSIM_CI_ARTIFACT_ROOT (default $HOME/aerosim-ci-artifacts) and nothing ever
# removed them. Three weeks of runs reached 504 directories and 18 GB, which
# exhausted the home-directory quota and made unrelated desktop applications
# abort on failed writes. This caps the store instead.
#
# Usage: prune_ci_artifacts.sh <repo-evidence-dir> [keep-count] [protected-dir]
set -euo pipefail

evidence_dir="${1:?usage: prune_ci_artifacts.sh <repo-evidence-dir> [keep] [protected-dir]}"
keep="${2:-${AEROSIM_CI_ARTIFACT_KEEP:-20}}"
protected="${3:-}"

case "$keep" in
    ''|*[!0-9]*)
        echo "prune_ci_artifacts: keep count must be a non-negative integer: $keep" >&2
        exit 1
        ;;
esac

if [ ! -d "$evidence_dir" ]; then
    exit 0
fi

# Refuse to operate on a root-level or suspiciously shallow path.
case "$evidence_dir" in
    /|/home|/home/*/|"$HOME")
        echo "prune_ci_artifacts: refusing to prune $evidence_dir" >&2
        exit 1
        ;;
esac

removed=0
while IFS= read -r stale; do
    stale="${stale%/}"
    if [ -n "$protected" ] && [ "$stale" = "${protected%/}" ]; then
        continue
    fi
    rm -rf -- "$stale"
    removed=$((removed + 1))
done < <(find "$evidence_dir" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %p\n' \
    | sort -rn \
    | tail -n +$((keep + 1)) \
    | cut -d' ' -f2-)

if [ "$removed" -gt 0 ]; then
    echo "prune_ci_artifacts: removed $removed run directories, kept $keep in $evidence_dir"
fi
