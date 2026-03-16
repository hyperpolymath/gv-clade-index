#!/usr/bin/env bash
# SPDX-License-Identifier: PMPL-1.0-or-later
# deploy-clade-a2ml.sh — Batch deploy CLADE.a2ml to all repos in the seed file
#
# Reads verisimdb/seed/repos.a2ml, extracts repo name + clade assignments,
# writes .machine_readable/CLADE.a2ml to each repo, commits, and pushes.
#
# Usage: ./sync/deploy-clade-a2ml.sh [--dry-run]

set -uo pipefail

REPOS_DIR="/var/mnt/eclipse/repos"
SEED_FILE="$REPOS_DIR/gv-clade-index/verisimdb/seed/repos.a2ml"
DRY_RUN="${1:-}"
COMMIT_MSG="feat: add CLADE.a2ml — clade taxonomy declaration

Part of gv-clade-index Phase 1: every repo declares its identity,
primary clade, and forge mappings for the VeriSimDB central registry.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"

SUCCESS=0
SKIPPED=0
FAILED=0
ALREADY=0

# Parse repos.a2ml using the standalone parser
parse_repos() {
    bash "$REPOS_DIR/gv-clade-index/sync/parse-repos.sh" "$SEED_FILE"
}

deploy_clade() {
    local repo_name="$1"
    local primary="$2"
    local secondary="$3"
    local lineage="$4"
    local parent="$5"
    local description="$6"

    local repo_path="$REPOS_DIR/$repo_name"

    # Skip if repo doesn't exist on disk
    if [[ ! -d "$repo_path" ]]; then
        echo "SKIP (not on disk): $repo_name"
        ((SKIPPED++))
        return
    fi

    # Skip if not a git repo
    if [[ ! -d "$repo_path/.git" ]]; then
        echo "SKIP (not git): $repo_name"
        ((SKIPPED++))
        return
    fi

    # Skip gv-clade-index itself (already has CLADE.a2ml)
    if [[ "$repo_name" == "gv-clade-index" ]]; then
        echo "SKIP (self): $repo_name"
        ((SKIPPED++))
        return
    fi

    # Skip if CLADE.a2ml already exists
    if [[ -f "$repo_path/.machine_readable/CLADE.a2ml" ]]; then
        echo "ALREADY: $repo_name"
        ((ALREADY++))
        return
    fi

    # Generate deterministic UUID v5
    local uuid
    uuid=$(uuidgen --sha1 --namespace @url --name "github.com/hyperpolymath/$repo_name")

    # Determine prefixed name
    local prefixed="${primary}-${repo_name}"

    # Ensure .machine_readable/ exists
    mkdir -p "$repo_path/.machine_readable"

    # Write CLADE.a2ml
    cat > "$repo_path/.machine_readable/CLADE.a2ml" <<CLADE_EOF
# SPDX-License-Identifier: PMPL-1.0-or-later
# Clade declaration — part of the gv-clade-index registry
# See: https://github.com/hyperpolymath/gv-clade-index

[identity]
uuid = "$uuid"
primary-forge = "github"
primary-owner = "hyperpolymath"
canonical-name = "$repo_name"
prefixed-name = "$prefixed"

[clade]
primary = "$primary"
secondary = $secondary
assigned = "2026-03-16"
rationale = "$description"

[forges]
github = "hyperpolymath/$repo_name"
gitlab = "hyperpolymath/$repo_name"
bitbucket = "hyperpolymath/$repo_name"

[lineage]
type = "$lineage"
parent = "$parent"
born = "2026-03-16"
CLADE_EOF

    if [[ "$DRY_RUN" == "--dry-run" ]]; then
        echo "DRY-RUN: would deploy to $repo_name (clade: $primary)"
        rm "$repo_path/.machine_readable/CLADE.a2ml"
        ((SUCCESS++))
        return
    fi

    # Git add, commit, push
    cd "$repo_path"
    git add .machine_readable/CLADE.a2ml
    if git diff --cached --quiet; then
        echo "SKIP (no changes): $repo_name"
        ((SKIPPED++))
        return
    fi

    git commit -m "$COMMIT_MSG" --quiet 2>/dev/null
    if git push --quiet 2>/dev/null; then
        echo "OK: $repo_name (clade: $primary)"
        ((SUCCESS++))
    else
        echo "FAIL (push): $repo_name"
        ((FAILED++))
    fi
    cd "$REPOS_DIR/gv-clade-index"
}

echo "=== gv-clade-index Phase 1: Deploy CLADE.a2ml ==="
echo "Seed file: $SEED_FILE"
echo "Repos dir: $REPOS_DIR"
[[ "$DRY_RUN" == "--dry-run" ]] && echo "MODE: DRY RUN"
echo ""

while IFS=$'\t' read -r name primary secondary lineage parent description; do
    deploy_clade "$name" "$primary" "$secondary" "$lineage" "$parent" "$description"
done < <(parse_repos)

echo ""
echo "=== Summary ==="
echo "Success: $SUCCESS"
echo "Already: $ALREADY"
echo "Skipped: $SKIPPED"
echo "Failed:  $FAILED"
