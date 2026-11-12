#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Parse repos.a2ml and emit TSV:
#   name\tprimary\tsecondary\tlineage\tparent\tdescription\towner\tformer\tretired
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
# It is emitted raw (the bracketed list, or empty). ADR 0008: an id is minted
# once, from the birth path. The birth path is the first `former` entry, or the
# current path when there is none, and a move or rename never changes the id.
# The earlier paths are archived for reference in worker/data/archive.json,
# never served.
#
# `retired` (column 9) is OPTIONAL: forge paths whose derived ids the registry
# once served for this repo and has withdrawn, each as "owner/name@YYYY-MM-DD"
# (the date of withdrawal). They are the ids reminted under the superseded ADR
# 0007. A retired id is archived and is never minted again for any repo.
#
# Consumers that read only the first six, seven or eight fields are unaffected.

# Default to this repo's seed file (script lives in sync/, seed in verisim/seed/).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SEED_FILE="${1:-$SCRIPT_DIR/../verisim/seed/repos.a2ml}"

awk '
BEGIN { FS="=" }
/^\[repo\./ {
    if (current_repo != "") {
        printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", current_repo, primary, secondary, lineage, parent, description, owner, former, retired
    }
    line = $0
    gsub(/^\[repo\./, "", line)
    gsub(/\]$/, "", line)
    gsub(/"/, "", line)
    current_repo = line
    primary = ""; secondary = "[]"; description = ""; lineage = "standalone"; parent = ""; owner = "hyperpolymath"; former = ""; retired = ""
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
current_repo != "" && /^retired / {
    val = $0
    gsub(/^retired *= */, "", val)
    retired = val
}
END {
    if (current_repo != "") {
        printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", current_repo, primary, secondary, lineage, parent, description, owner, former, retired
    }
}
' "$SEED_FILE"
