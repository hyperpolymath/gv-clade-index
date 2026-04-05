#!/usr/bin/env bash
# SPDX-License-Identifier: PMPL-1.0-or-later
# Parse repos.a2ml and emit TSV: name\tprimary\tsecondary\tlineage\tparent\tdescription

SEED_FILE="${1:-/var$REPOS_DIR/gv-clade-index/verisim/seed/repos.a2ml}"

awk '
BEGIN { FS="=" }
/^\[repo\./ {
    if (current_repo != "") {
        printf "%s\t%s\t%s\t%s\t%s\t%s\n", current_repo, primary, secondary, lineage, parent, description
    }
    line = $0
    gsub(/^\[repo\./, "", line)
    gsub(/\]$/, "", line)
    gsub(/"/, "", line)
    current_repo = line
    primary = ""; secondary = "[]"; description = ""; lineage = "standalone"; parent = ""
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
END {
    if (current_repo != "") {
        printf "%s\t%s\t%s\t%s\t%s\t%s\n", current_repo, primary, secondary, lineage, parent, description
    }
}
' "$SEED_FILE"
