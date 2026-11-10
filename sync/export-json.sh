#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# export-json.sh — Convert seed A2ML to JSON for Cloudflare KV
#
# Produces:
#   worker/data/repos.json   — all repos with clade assignments
#   worker/data/clades.json  — clade definitions
#   worker/data/index.json   — lookup tables (by-name, by-clade)
#   worker/data/archive.json — earlier ids of moved repos (ADR 0007; never served)

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
PARSED="$(mktemp)"; IDS="$(mktemp)"; FORMER="$(mktemp)"; FORMER_V8="$(mktemp)"
trap 'rm -f "$PARSED" "$IDS" "$FORMER" "$FORMER_V8"' EXIT
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
    uuid_v8 = $9
    gsub(/"/, "\\\"", desc)
    # uuid is the UUIDv5 of the CURRENT github.com/<owner>/<repo> in the @url
    # namespace. A move or rename remints it (ADR 0007, an explicit exception
    # to the /v1 additive-only rule of ADR 0004 for uuid and uuid_v8 only); the
    # earlier ids go to archive.json and are never served. uuid_v8 is added
    # beside it; /v2 makes the v8 id the uuid.
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

# Build archive.json: earlier ids of moved or renamed repos (ADR 0007).
#
# A repo's ids derive from its CURRENT forge path, so a move mints new ones.
# The earlier ids are kept here for reference only: this file is not loaded
# into KV, no route serves it, and nothing resolves an old id. Each `former`
# entry in the seed is "owner/name@YYYY-MM-DD", oldest first; generation 1 is
# the birth path and the current path is generation (number of entries + 1).
# Always written, even empty, so the drift check covers it.
echo "Exporting archive..."
while IFS=$'\t' read -r name owner list; do
  case "$list" in
    '['*']') ;;
    *) echo "export-json: $name: former must be a bracketed list, got: $list" >&2; exit 1 ;;
  esac
  gen=0; prev=""
  while IFS= read -r entry; do
    if [[ ! "$entry" =~ ^([A-Za-z0-9._-]+)/([A-Za-z0-9._-]+)@([0-9]{4}-[0-9]{2}-[0-9]{2})$ ]]; then
      echo "export-json: $name: former entry '$entry' is not \"owner/name@YYYY-MM-DD\"" >&2; exit 1
    fi
    until_date="${BASH_REMATCH[3]}"
    if [[ -n "$prev" ]] && [[ "$until_date" < "$prev" ]]; then
      echo "export-json: $name: former entries must be oldest first ($until_date after $prev)" >&2; exit 1
    fi
    prev="$until_date"; gen=$((gen + 1))
    printf '%s\t%s\t%d\t%s\t%s\t%s\n' "$name" "$owner" "$gen" "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "$until_date"
  done < <(grep -oE '"[^"]*"' <<<"$list" | tr -d '"')
  if [[ "$gen" -eq 0 ]]; then
    echo "export-json: $name: former is present but lists no entries" >&2; exit 1
  fi
done < <(awk -F'\t' '$8 != "" { print $1 "\t" ($7 != "" ? $7 : "hyperpolymath") "\t" $8 }' "$PARSED") > "$FORMER"

if [[ -s "$FORMER" ]]; then
  cut -f4,5 "$FORMER" | bash "$SCRIPT_DIR/uuid-v8.sh" > "$FORMER_V8" \
    || { echo "export-json: sync/uuid-v8.sh failed for archive entries" >&2; exit 1; }
  [[ "$(wc -l < "$FORMER_V8")" = "$(wc -l < "$FORMER")" ]] \
    || { echo "export-json: uuid-v8.sh returned the wrong number of archive ids" >&2; exit 1; }
fi
paste "$FORMER" "$FORMER_V8" | while IFS=$'\t' read -r name owner gen fowner fname until_date v8; do
  [[ -n "$name" ]] || continue
  v5="$(uuidgen --sha1 --namespace @url --name "github.com/$fowner/$fname")"
  [[ -n "$v5" ]] && [[ -n "$v8" ]] || { echo "export-json: no archive id derived for $fowner/$fname" >&2; exit 1; }
  printf '%s\t%s\t%s\t%s/%s\t%s\t%s\t%s\n' "$name" "$owner" "$gen" "$fowner" "$fname" "$v5" "$v8" "$until_date"
done | jq -R -s '
  split("\n") | map(select(length > 0) | split("\t")
    | {name: .[0], github: "\(.[1])/\(.[0])",
       record: {generation: (.[2] | tonumber), github: .[3], uuid: .[4], uuid_v8: .[5], until: .[6]}})
  | group_by(.name)
  | map({name: .[0].name, github: .[0].github,
         generation: ((map(.record) | length) + 1),
         former: (map(.record) | sort_by(.generation))})' > "$OUT/archive.json" \
  || { echo "export-json: archive.json export failed" >&2; exit 1; }
echo "  $(jq length "$OUT/archive.json") repos with archived ids"

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
