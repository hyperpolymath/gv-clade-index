#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Parse repos.a2ml and emit TSV:
#   name\tprimary\tsecondary\tlineage\tparent\tdescription\towner
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
# It is the LAST column: consumers that read only the first six fields are
# unaffected by its presence.

# Default to this repo's seed file (script lives in sync/, seed in verisim/seed/).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SEED_FILE="${1:-$SCRIPT_DIR/../verisim/seed/repos.a2ml}"

awk '
BEGIN { FS="=" }
/^\[repo\./ {
    if (current_repo != "") {
        printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n", current_repo, primary, secondary, lineage, parent, description, owner
    }
    line = $0
    gsub(/^\[repo\./, "", line)
    gsub(/\]$/, "", line)
    gsub(/"/, "", line)
    current_repo = line
    primary = ""; secondary = "[]"; description = ""; lineage = "standalone"; parent = ""; owner = "hyperpolymath"
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
END {
    if (current_repo != "") {
        printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n", current_repo, primary, secondary, lineage, parent, description, owner
    }
}
' "$SEED_FILE"
