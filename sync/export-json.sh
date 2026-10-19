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
PARSED="$(mktemp)"; IDS="$(mktemp)"
trap 'rm -f "$PARSED" "$IDS"' EXIT
bash "$SCRIPT_DIR/parse-repos.sh" "$SEED/repos.a2ml" > "$PARSED" \
  || { echo "export-json: parse-repos.sh failed" >&2; exit 1; }
# uuid_v8 is the ADR-008 profile C id (D320): domain gv-clade-index, name
# github.com/<owner>/<repo>, from standards' shared generator. The owner
# segment is part of the identity; it defaults to "hyperpolymath".
awk -F'\t' '{ print ($7 != "" ? $7 : "hyperpolymath") "\t" $1 }' "$PARSED" \
  | bash "$SCRIPT_DIR/uuid-v8.sh" > "$IDS" \
  || { echo "export-json: sync/uuid-v8.sh failed" >&2; exit 1; }
[ "$(wc -l < "$IDS")" = "$(wc -l < "$PARSED")" ] \
  || { echo "export-json: uuid-v8.sh returned $(wc -l < "$IDS") ids for $(wc -l < "$PARSED") repos" >&2; exit 1; }
command -v uuidgen >/dev/null 2>&1 \
  || { echo "export-json: uuidgen is required (package uuid-runtime / util-linux) for uuid" >&2; exit 1; }
if ! paste "$PARSED" "$IDS" | awk -F'\t' '
BEGIN { printf "[\n" }
NR > 1 { printf ",\n" }
{
    name = $1; primary = $2; secondary = $3; lineage = $4; parent = $5; desc = $6
    owner = ($7 != "" ? $7 : "hyperpolymath")
    uuid_v8 = $8
    gsub(/"/, "\\\"", desc)
    # uuid is the identity /v1 has always served: UUIDv5 of
    # github.com/<owner>/<repo> in the @url namespace. /v1 is additive-only
    # (docs/decisions/0004-api-versioning.adoc), so it keeps that value and
    # uuid_v8 is added beside it; /v2 makes the v8 id the uuid.
    cmd = "uuidgen --sha1 --namespace @url --name \"github.com/" owner "/" name "\""
    uuid = ""
    cmd | getline uuid
    close(cmd)
    # A failed derivation reads as an empty string, not an error, so check it:
    # an empty id must stop the export, never reach repos.json.
    if (uuid == "" || uuid_v8 == "") {
        printf "export-json: no %s derived for %s/%s\n", (uuid == "" ? "uuid" : "uuid_v8"), owner, name > "/dev/stderr"
        failed = 1; exit 1
    }
    # NB: no separate "owner" key. The github field already carries it as
    # "owner/name".
    printf "  {\"name\":\"%s\",\"uuid\":\"%s\",\"uuid_v8\":\"%s\",\"clade\":\"%s\",\"secondary\":%s,\"lineage\":\"%s\",\"parent\":\"%s\",\"description\":\"%s\",\"prefixed\":\"%s-%s\",\"github\":\"%s/%s\"}", name, uuid, uuid_v8, primary, secondary, lineage, parent, desc, primary, name, owner, name
}
END { if (failed) exit 1; printf "\n]\n" }
' > "$OUT/repos.json"; then
  echo "export-json: repos.json export failed" >&2
  exit 1
fi

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
