#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# deploy-clade-a2ml.sh — Batch deploy CLADE.a2ml to all repos in the seed file
#
# Reads verisim/seed/repos.a2ml, extracts repo name + clade assignments,
# writes .machine_readable/CLADE.a2ml to each repo, commits, and pushes.
#
# Usage: ./sync/deploy-clade-a2ml.sh [--dry-run]

set -uo pipefail

# REPOS_DIR is the directory that contains all hyperpolymath repo clones,
# including gv-clade-index itself. Defaults to the parent of this checkout
# (repos checked out as siblings); override by exporting REPOS_DIR.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOS_DIR="${REPOS_DIR:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
SEED_FILE="$REPOS_DIR/gv-clade-index/verisim/seed/repos.a2ml"
DRY_RUN="${1:-}"

if [[ ! -d "$REPOS_DIR" ]]; then
    echo "ERROR: REPOS_DIR '$REPOS_DIR' is not a directory." >&2
    echo "Export REPOS_DIR to the folder containing your repo clones." >&2
    exit 1
fi
COMMIT_MSG="feat: add CLADE.a2ml — clade taxonomy declaration

Part of gv-clade-index Phase 1: every repo declares its identity,
primary clade, and forge mappings for the VeriSimDB central registry."

SUCCESS=0
SKIPPED=0
FAILED=0
ALREADY=0

# Parse repos.a2ml using the standalone parser
parse_repos() {
    bash "$REPOS_DIR/gv-clade-index/sync/parse-repos.sh" "$SEED_FILE"
}

# The taxonomy's name for a clade code. Authority: verisim/seed/clades.a2ml.
#
# Emitted into every CLADE.a2ml as `primary-name` so the code never travels
# without its meaning. CLADE-003 can only check a code is one of the 12 — it
# cannot check the author meant that clade, which is how `pt` ("PainT-type",
# actually Protocols & Interop) and `gv` ("Graphical/Visual", actually
# GoVernance) were filed under categories they have nothing to do with. Writing
# the name down makes the belief checkable; CLADE-006 enforces the pair.
clade_name() {
    case "$1" in
        fv) echo "Formal Verification & Proofs" ;;
        nl) echo "Nextgen Languages" ;;
        rm) echo "Repo Management & Tooling" ;;
        gv) echo "Governance & Standards" ;;
        db) echo "Databases" ;;
        ap) echo "Applications" ;;
        ix) echo "Infrastructure & Cloud" ;;
        dx) echo "Developer Ecosystem" ;;
        pt) echo "Protocols & Interop" ;;
        ax) echo "AI & Neurosymbolic" ;;
        gm) echo "Games & Interactive" ;;
        sc) echo "Security" ;;
        *)  echo "" ;;
    esac
}

deploy_clade() {
    local repo_name="$1"
    local primary="$2"
    local secondary="$3"
    local lineage="$4"
    local parent="$5"
    local description="$6"
    # Forge owner/org hosting this repo. Optional in repos.a2ml; parse-repos.sh
    # defaults it to "hyperpolymath", so existing entries are unaffected.
    local owner="${7:-hyperpolymath}"

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

    # Skip if CLADE.a2ml already exists.
    #
    # Check BOTH known layouts. Two are in use across the estate and the canon
    # does not yet agree which is authoritative:
    #   .machine_readable/CLADE.a2ml               — this script + the CLADE-001 contractile
    #   .machine_readable/descriptiles/CLADE.a2ml  — rsr-template-repo + chronicles-of-slavia
    # Checking only the first meant a repo using the descriptiles layout looked
    # like it had no CLADE at all, so this script would write a SECOND one — two
    # files, two identities, no error. That disagreement is unresolved and is the
    # owner's to settle; until then, refusing to write over an existing
    # declaration is the safe reading.
    local existing
    for existing in "$repo_path/.machine_readable/CLADE.a2ml" \
                    "$repo_path/.machine_readable/descriptiles/CLADE.a2ml"; do
        if [[ -f "$existing" ]]; then
            echo "ALREADY: $repo_name (${existing#$repo_path/})"
            ((ALREADY++))
            return
        fi
    done

    # Generate deterministic UUID v5.
    #
    # The owner segment is part of the derived name, so it is part of the
    # IDENTITY — get it wrong and the repo gets a uuid that belongs to nothing.
    # It was hardcoded to "hyperpolymath", which silently produced a wrong uuid
    # for any repo hosted elsewhere (e.g. the metadatastician org). Now sourced
    # from the registry entry, still defaulting to "hyperpolymath" so every
    # existing entry derives byte-identically.
    local uuid
    uuid=$(uuidgen --sha1 --namespace @url --name "github.com/$owner/$repo_name")

    # Fail loudly if the registry disagrees with the repo's actual remote — a
    # silently wrong owner means a silently wrong identity, which is worse than
    # no identity at all.
    local remote_owner
    remote_owner=$(git -C "$repo_path" remote get-url origin 2>/dev/null \
        | sed -nE 's#^(https?://[^/]+/|[^@]+@[^:]+:)([^/]+)/.*$#\2#p')
    if [[ -n "$remote_owner" && "$remote_owner" != "$owner" ]]; then
        echo "WARN: $repo_name — registry says owner='$owner' but origin says '$remote_owner'." >&2
        echo "      The uuid is derived FROM the owner, so one of them is wrong." >&2
        echo "      Set 'owner = \"$remote_owner\"' in repos.a2ml, or fix the remote. Skipping." >&2
        ((FAILED++))
        return
    fi

    # Determine prefixed name
    local prefixed="${primary}-${repo_name}"

    # Refuse to write an identity we cannot name. An unknown code here means the
    # seed disagrees with the taxonomy — fail loudly rather than emit a CLADE.a2ml
    # that would fail CLADE-006 downstream in someone else's repo.
    local primary_name
    primary_name=$(clade_name "$primary")
    if [[ -z "$primary_name" ]]; then
        echo "ERROR: $repo_name — clade code '$primary' is not one of the 12 in clades.a2ml. Skipping." >&2
        ((FAILED++))
        return
    fi

    # Ensure .machine_readable/ exists
    mkdir -p "$repo_path/.machine_readable"

    # Write CLADE.a2ml
    cat > "$repo_path/.machine_readable/CLADE.a2ml" <<CLADE_EOF
# SPDX-License-Identifier: MPL-2.0
# Clade declaration — part of the gv-clade-index registry
# See: https://github.com/hyperpolymath/gv-clade-index

[identity]
uuid = "$uuid"
primary-forge = "github"
primary-owner = "$owner"
canonical-name = "$repo_name"
prefixed-name = "$prefixed"

[clade]
# The 2 letters abbreviate the CLADE's name below — never the repo's name.
# See gv-clade-index: verisim/seed/clades.a2ml for all 12 codes.
primary = "$primary"
primary-name = "$primary_name"
secondary = $secondary
assigned = "2026-03-16"
rationale = "$description"

[forges]
github = "$owner/$repo_name"
gitlab = "$owner/$repo_name"
bitbucket = "$owner/$repo_name"

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

# Read the parser's TSV with the tabs translated to US (0x1f) first.
#
# TAB IS IFS WHITESPACE, so `IFS=$'\t' read` COLLAPSES a run of tabs into one
# delimiter and empty fields vanish, shifting every field after them. 316 of the
# 319 seed entries have an empty `parent`, so for nearly the whole registry:
#
#   proven <tab> fv <tab> [] <tab> standalone <tab><tab> Formally verified… <tab> hyperpolymath
#                                                     ^^ empty parent collapses
#   ->  parent="Formally verified…"   description="hyperpolymath"   owner=""
#
# The damage is real and committed: 153 CLADE.a2ml files across the estate carry
# `rationale = ""` with the repo's DESCRIPTION sitting in `parent` (panic-attack,
# flat-mate, rpa-elysium, live-files, …). Repairing those files is a separate,
# owner-facing job — this only stops the script producing more.
#
# It also silently defeated the `owner` support added in #48: $7 was always empty,
# so `owner` always fell back to "hyperpolymath" and an explicit
# `owner = "metadatastician"` in the seed was ignored. export-json.sh never had
# this bug — awk -F'\t' does not collapse — which is why the two derivation sites
# disagreed and why #48's byte-identical regression test did not catch it.
#
# US (0x1f) is not IFS whitespace, so runs are not collapsed and empty fields
# survive. It cannot occur in the data (checked: 0 occurrences in repos.a2ml) and
# is exactly what the ASCII unit separator is for.
while IFS=$'\037' read -r name primary secondary lineage parent description owner; do
    deploy_clade "$name" "$primary" "$secondary" "$lineage" "$parent" "$description" "$owner"
done < <(parse_repos | tr '\t' '\037')

echo ""
echo "=== Summary ==="
echo "Success: $SUCCESS"
echo "Already: $ALREADY"
echo "Skipped: $SKIPPED"
echo "Failed:  $FAILED"
