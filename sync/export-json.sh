#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# export-json.sh — Convert seed A2ML to JSON for Cloudflare KV
#
# Produces:
#   worker/data/repos.json   — all repos with clade assignments
#   worker/data/clades.json  — clade definitions
#   worker/data/index.json   — lookup tables (by-name, by-clade)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SEED="$ROOT/verisim/seed"
# GV_EXPORT_OUT lets the drift gate (scripts/check-registry.sh) export to a scratch
# directory and compare, instead of overwriting the committed files.
OUT="${GV_EXPORT_OUT:-$ROOT/worker/data}"

mkdir -p "$OUT"

# Parse repos.a2ml into JSON array
echo "Exporting repos..."
bash "$SCRIPT_DIR/parse-repos.sh" "$SEED/repos.a2ml" | awk -F'\t' '
BEGIN { printf "[\n" }
NR > 1 { printf ",\n" }
{
    name = $1; primary = $2; secondary = $3; lineage = $4; parent = $5; desc = $6
    owner = ($7 != "" ? $7 : "hyperpolymath")
    gsub(/"/, "\\\"", desc)
    # Generate UUID deterministically. The owner segment is part of the derived
    # name, so it is part of the identity; it was hardcoded to "hyperpolymath",
    # which produced a wrong uuid for any repo hosted elsewhere. Defaults to
    # "hyperpolymath", so entries without an explicit owner are unchanged.
    cmd = "uuidgen --sha1 --namespace @url --name \"github.com/" owner "/" name "\""
    cmd | getline uuid
    close(cmd)
    # NB: no separate "owner" key — the schema is unchanged on purpose. The
    # github field already carries it as "owner/name", so entries without an
    # explicit owner serialise byte-identically to before this change.
    printf "  {\"name\":\"%s\",\"uuid\":\"%s\",\"clade\":\"%s\",\"secondary\":%s,\"lineage\":\"%s\",\"parent\":\"%s\",\"description\":\"%s\",\"prefixed\":\"%s-%s\",\"github\":\"%s/%s\"}", name, uuid, primary, secondary, lineage, parent, desc, primary, name, owner, name
}
END { printf "\n]\n" }
' > "$OUT/repos.json"

REPO_COUNT=$(grep -c '"name"' "$OUT/repos.json")
echo "  $REPO_COUNT repos exported"

# Build clades.json from clades.a2ml
echo "Exporting clades..."
awk '
BEGIN { FS="="; printf "[\n"; first=1 }
/^\[clade\./ {
    if (!first) printf ",\n"
    first=0
    code = $0; gsub(/^\[clade\./, "", code); gsub(/\]$/, "", code)
    printf "  {\"code\":\"%s\"", code
}
/^name = / { val=$2; gsub(/^ *"/, "", val); gsub(/".*$/, "", val); printf ",\"name\":\"%s\"", val }
/^description = / { val=$2; gsub(/^ *"/, "", val); gsub(/".*$/, "", val); printf ",\"description\":\"%s\"", val }
/^colour = / { val=$2; gsub(/^ *"/, "", val); gsub(/".*$/, "", val); printf ",\"colour\":\"%s\"", val }
/^icon = / { val=$2; gsub(/^ *"/, "", val); gsub(/".*$/, "", val); printf ",\"icon\":\"%s\"", val }
/^keywords = / {
    val=$0; gsub(/^keywords *= */, "", val)
    printf ",\"keywords\":%s}", val
}
END { printf "\n]\n" }
' "$SEED/clades.a2ml" > "$OUT/clades.json"

CLADE_COUNT=$(grep -c '"code"' "$OUT/clades.json")
echo "  $CLADE_COUNT clades exported"

# Build index — repos grouped by clade
echo "Building index..."
jq -n \
  --slurpfile repos "$OUT/repos.json" \
  --slurpfile clades "$OUT/clades.json" \
  --arg generated "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
  $repos[0] as $r
  | $clades[0] as $c
  | ($r | group_by(.clade) | map({key: .[0].clade, value: map(.name)}) | from_entries) as $by_clade
  | {
      total_repos: ($r | length),
      total_clades: ($c | length),
      generated: $generated,
      clades: ($c | map(. + {member_count: (($by_clade[.code] // []) | length), members: ($by_clade[.code] // [])})),
      by_name: ($r | map({key: .name, value: .}) | from_entries)
    }' > "$OUT/index.json"
echo "  Index: $(jq .total_repos "$OUT/index.json") repos across $(jq .total_clades "$OUT/index.json") clades"

echo "Done. Output in $OUT/"
ls -lh "$OUT/"
