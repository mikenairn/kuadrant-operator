#!/usr/bin/env bash
#
# find-target-branches.sh — find kuadrant-operator branches that track
# a given component at a given ref.
#
# Usage:
#   find-target-branches.sh <owner/repo> <component> <ref> [min-release-version]
#
# Example:
#   find-target-branches.sh Kuadrant/kuadrant-operator dns-operator main 1.5
#
# Output: JSON array of matching branch objects, e.g.
#   [{"branch":"main","auto-merge":true}]
#
# Requires: gh (GitHub CLI), go, jq

set -euo pipefail

REPO="${1:?Usage: find-target-branches.sh <owner/repo> <component> <ref> [min-release-version]}"
COMPONENT="${2:?Usage: find-target-branches.sh <owner/repo> <component> <ref> [min-release-version]}"
REF="${3:?Usage: find-target-branches.sh <owner/repo> <component> <ref> [min-release-version]}"
MIN_VERSION="${4:-1.5}"

MIN_MAJOR="${MIN_VERSION%%.*}"
MIN_MINOR="${MIN_VERSION##*.}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# List candidate branches: main + release-X.Y where X.Y >= MIN_VERSION
candidates() {
    gh api "repos/${REPO}/branches" --paginate --jq '.[].name' | while read -r branch; do
        if [ "$branch" = "main" ]; then
            echo "$branch"
        elif [[ "$branch" =~ ^release-([0-9]+)\.([0-9]+)$ ]]; then
            major="${BASH_REMATCH[1]}"
            minor="${BASH_REMATCH[2]}"
            if [ "$major" -gt "$MIN_MAJOR" ] || { [ "$major" -eq "$MIN_MAJOR" ] && [ "$minor" -ge "$MIN_MINOR" ]; }; then
                echo "$branch"
            fi
        fi
    done
}

MATCHES="[]"

for branch in $(candidates); do
    # Fetch sync.yaml from this branch via GitHub API
    SYNC_YAML=$(gh api "repos/${REPO}/contents/component-charts/sync.yaml?ref=${branch}" \
        --jq '.content' 2>/dev/null | base64 -d 2>/dev/null) || true

    if [ -z "$SYNC_YAML" ]; then
        continue
    fi

    # Write to temp file so the Go tool can read it
    TMPFILE=$(mktemp)
    echo "$SYNC_YAML" > "$TMPFILE"

    # Use the Go sync tool to query the component's tracking info
    COMP_CFG=$(go run "$SCRIPT_DIR/" --config "$TMPFILE" --query "$COMPONENT" 2>/dev/null) || true
    rm -f "$TMPFILE"

    if [ -z "$COMP_CFG" ]; then
        continue
    fi

    TRACKED=$(echo "$COMP_CFG" | jq -r '.["tracked-branch"]')
    AUTO_MERGE=$(echo "$COMP_CFG" | jq -r '.["auto-merge"]')

    if [ "$TRACKED" = "$REF" ]; then
        MATCHES=$(echo "$MATCHES" | jq \
            --arg b "$branch" \
            --argjson am "${AUTO_MERGE:-false}" \
            '. + [{"branch": $b, "auto-merge": $am}]')
    fi
done

echo "$MATCHES"
