#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Parse repos.a2ml and emit TSV:
#   name\tprimary\tsecondary\tlineage\tparent\tdescription\towner\tformer
#
# `owner` is the forge owner/org that hosts the repo. It is OPTIONAL in
# repos.a2ml and defaults to "hyperpolymath", so every existing entry parses
# exactly as before and derives exactly the same uuid. Set it per-entry only for
# repos hosted elsewhere:
#
#   [repo.cadastra]
#   primary = "rm"
#   owner   = "metadatastician"
#
# `former` (column 8, after `owner`) is OPTIONAL too: the repo's earlier forge
# paths, oldest first, each as "owner/name@YYYY-MM-DD" (the date the registry
# recorded the move), for example
#
#   former = ["metadatastician/planer-1@2026-11-10"]
#
# It is emitted raw (the bracketed list, or empty). ADR 0007: a move remints
# the ids from the new path, and the earlier ids are archived for reference in
# worker/data/archive.json, never served.
#
# Consumers that read only the first six or seven fields are unaffected.

# Default to this repo's seed file (script lives in sync/, seed in verisim/seed/).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SEED_FILE="${1:-$SCRIPT_DIR/../verisim/seed/repos.a2ml}"

awk '
BEGIN { FS="=" }
/^\[repo\./ {
    if (current_repo != "") {
        printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", current_repo, primary, secondary, lineage, parent, description, owner, former
    }
    line = $0
    gsub(/^\[repo\./, "", line)
    gsub(/\]$/, "", line)
    gsub(/"/, "", line)
    current_repo = line
    primary = ""; secondary = "[]"; description = ""; lineage = "standalone"; parent = ""; owner = "hyperpolymath"; former = ""
}
current_repo != "" && /^primary / {
    val = $2
    gsub(/^ *"/, "", val); gsub(/".*$/, "", val)
    primary = val
}
current_repo != "" && /^secondary / {
    val = $0
    gsub(/^secondary *= */, "", val)
    secondary = val
}
current_repo != "" && /^description / {
    val = $0
    gsub(/^description *= *"/, "", val); gsub(/"$/, "", val)
    description = val
}
current_repo != "" && /^lineage / {
    val = $2
    gsub(/^ *"/, "", val); gsub(/".*$/, "", val)
    lineage = val
}
current_repo != "" && /^parent / {
    val = $2
    gsub(/^ *"/, "", val); gsub(/".*$/, "", val)
    parent = val
}
current_repo != "" && /^owner / {
    val = $2
    gsub(/^ *"/, "", val); gsub(/".*$/, "", val)
    owner = val
}
current_repo != "" && /^former / {
    val = $0
    gsub(/^former *= */, "", val)
    former = val
}
END {
    if (current_repo != "") {
        printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", current_repo, primary, secondary, lineage, parent, description, owner, former
    }
}
' "$SEED_FILE"
