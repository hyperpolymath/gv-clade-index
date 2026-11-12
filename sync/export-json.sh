#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# export-json.sh — Convert seed A2ML to JSON for Cloudflare KV
#
# Produces:
#   worker/data/repos.json   — all repos with clade assignments
#   worker/data/clades.json  — clade definitions
#   worker/data/index.json   — lookup tables (by-name, by-clade)
#   worker/data/archive.json — birth and earlier paths of moved repos, and
#                              retired ids (ADR 0008; never served)

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
PARSED="$(mktemp)"; BIRTH="$(mktemp)"; IDS="$(mktemp)"; FORMER="$(mktemp)"; RETIRED="$(mktemp)"; RETIRED_V8="$(mktemp)"
trap 'rm -f "$PARSED" "$BIRTH" "$IDS" "$FORMER" "$RETIRED" "$RETIRED_V8"' EXIT
bash "$SCRIPT_DIR/parse-repos.sh" "$SEED/repos.a2ml" > "$PARSED" \
  || { echo "export-json: parse-repos.sh failed" >&2; exit 1; }
# Identity is minted once, from the BIRTH path (ADR 0008): the first `former`
# entry when the repo has moved or been renamed, else the current
# github.com/<owner>/<repo>. The owner defaults to "hyperpolymath". A move or
# rename changes the location only, never the id.
awk -F'\t' '{
    owner = ($7 != "" ? $7 : "hyperpolymath"); path = owner "/" $1
    if ($8 != "" && match($8, /"[^"@]*@/)) path = substr($8, RSTART + 1, RLENGTH - 2)
    print path
}' "$PARSED" > "$BIRTH"
# uuid_v8 is the ADR-008 profile C id (D320): domain gv-clade-index, name
# github.com/<birth owner>/<birth name>, from standards' shared generator.
sed 's#/#\t#' "$BIRTH" | bash "$SCRIPT_DIR/uuid-v8.sh" > "$IDS" \
  || { echo "export-json: sync/uuid-v8.sh failed" >&2; exit 1; }
[ "$(wc -l < "$IDS")" = "$(wc -l < "$PARSED")" ] \
  || { echo "export-json: uuid-v8.sh returned $(wc -l < "$IDS") ids for $(wc -l < "$PARSED") repos" >&2; exit 1; }
command -v uuidgen >/dev/null 2>&1 \
  || { echo "export-json: uuidgen is required (package uuid-runtime / util-linux) for uuid" >&2; exit 1; }
if ! paste "$PARSED" "$BIRTH" "$IDS" | awk -F'\t' '
BEGIN { printf "[\n" }
NR > 1 { printf ",\n" }
{
    name = $1; primary = $2; secondary = $3; lineage = $4; parent = $5; desc = $6
    owner = ($7 != "" ? $7 : "hyperpolymath")
    birth = $10; uuid_v8 = $11
    gsub(/"/, "\\\"", desc)
    # uuid is the UUIDv5 of github.com/<birth path> in the @url namespace. It
    # is minted once and never changes (ADR 0008, which restores the ADR 0006
    # immortal rule): a move or rename changes `github`, never the id. The
    # birth path is not served; it stays in archive.json. uuid_v8 is added
    # beside uuid under the /v1 additive-only rule; /v2 makes the v8 id the uuid.
    cmd = "uuidgen --sha1 --namespace @url --name \"github.com/" birth "\""
    uuid = ""
    cmd | getline uuid
    close(cmd)
    # A failed derivation reads as an empty string, not an error, so check it:
    # an empty id must stop the export, never reach repos.json.
    if (uuid == "" || uuid_v8 == "") {
        printf "export-json: no %s derived for %s\n", (uuid == "" ? "uuid" : "uuid_v8"), birth > "/dev/stderr"
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

# Build archive.json: where moved or renamed repos have been, and which ids
# were withdrawn (ADR 0008).
#
# An id is minted once, from the birth path, and never changes. This file
# keeps, for reference only, each moved repo's earlier paths (`former`, oldest
# first; generation 1 is the birth path and the current path is generation
# n+1) and the ids the registry once served for it and withdrew (`retired`:
# the ADR 0007 remints). It is not loaded into KV, no route serves it, and
# nothing resolves an id through it. Seed entries in both lists are
# "owner/name@YYYY-MM-DD". Always written, even empty, so the drift check
# covers it.
echo "Exporting archive..."
# Emit one TSV row per entry of a bracketed seed list:
#   name  owner  index  entry-owner  entry-name  date
# $1 is the parsed column (8 = former, 9 = retired) and $2 its seed name;
# dates must not go backwards.
seed_list() {
  local col="$1" field="$2"
  while IFS=$'\t' read -r name owner list; do
    case "$list" in
      '['*']') ;;
      *) echo "export-json: $name: $field must be a bracketed list, got: $list" >&2; return 1 ;;
    esac
    local n=0 prev="" entry until_date
    while IFS= read -r entry; do
      if [[ ! "$entry" =~ ^([A-Za-z0-9._-]+)/([A-Za-z0-9._-]+)@([0-9]{4}-[0-9]{2}-[0-9]{2})$ ]]; then
        echo "export-json: $name: $field entry '$entry' is not \"owner/name@YYYY-MM-DD\"" >&2; return 1
      fi
      until_date="${BASH_REMATCH[3]}"
      if [[ -n "$prev" ]] && [[ "$until_date" < "$prev" ]]; then
        echo "export-json: $name: $field entries must be oldest first ($until_date after $prev)" >&2; return 1
      fi
      prev="$until_date"; n=$((n + 1))
      printf '%s\t%s\t%d\t%s\t%s\t%s\n' "$name" "$owner" "$n" "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "$until_date"
    done < <(grep -oE '"[^"]*"' <<<"$list" | tr -d '"')
    if [[ "$n" -eq 0 ]]; then
      echo "export-json: $name: $field is present but lists no entries" >&2; return 1
    fi
  done < <(awk -F'\t' -v c="$col" '$c != "" { print $1 "\t" ($7 != "" ? $7 : "hyperpolymath") "\t" $c }' "$PARSED")
}
seed_list 8 former > "$FORMER" || exit 1
seed_list 9 retired > "$RETIRED" || exit 1

# A retired id is the id once derived from that path: UUIDv5 (@url) and
# profile C UUIDv8, as the registry served it before the withdrawal.
if [[ -s "$RETIRED" ]]; then
  cut -f4,5 "$RETIRED" | bash "$SCRIPT_DIR/uuid-v8.sh" > "$RETIRED_V8" \
    || { echo "export-json: sync/uuid-v8.sh failed for retired ids" >&2; exit 1; }
  [[ "$(wc -l < "$RETIRED_V8")" = "$(wc -l < "$RETIRED")" ]] \
    || { echo "export-json: uuid-v8.sh returned the wrong number of retired ids" >&2; exit 1; }
fi
{
  awk -F'\t' '{ printf "F\t%s\t%s\t%s\t%s/%s\t\t\t%s\n", $1, $2, $3, $4, $5, $6 }' "$FORMER"
  paste "$RETIRED" "$RETIRED_V8" | while IFS=$'\t' read -r name owner n rowner rname until_date v8; do
    [[ -n "$name" ]] || continue
    v5="$(uuidgen --sha1 --namespace @url --name "github.com/$rowner/$rname")"
    [[ -n "$v5" ]] && [[ -n "$v8" ]] || { echo "export-json: no retired id derived for $rowner/$rname" >&2; exit 1; }
    printf 'R\t%s\t%s\t%s\t%s/%s\t%s\t%s\t%s\n' "$name" "$owner" "$n" "$rowner" "$rname" "$v5" "$v8" "$until_date"
  done
} | jq -R -s --slurpfile repos "$OUT/repos.json" '
  ($repos[0] | map({key: .name, value: .}) | from_entries) as $cur
  | split("\n") | map(select(length > 0) | split("\t")
    | {kind: .[0], name: .[1], github: "\(.[2])/\(.[1])", n: (.[3] | tonumber),
       path: .[4], uuid: .[5], uuid_v8: .[6], until: .[7]})
  | group_by(.name)
  | map((map(select(.kind == "F")) | sort_by(.n)) as $f
        | (map(select(.kind == "R")) | sort_by(.n)) as $r
        | {name: .[0].name, github: .[0].github,
           uuid: $cur[.[0].name].uuid, uuid_v8: $cur[.[0].name].uuid_v8,
           birth: (if ($f | length) > 0 then $f[0].path else .[0].github end),
           generation: (($f | length) + 1),
           former: ($f | map({generation: .n, github: .path, until: .until})),
           retired: ($r | map({github: .path, uuid: .uuid, uuid_v8: .uuid_v8, until: .until}))})' \
  > "$OUT/archive.json" \
  || { echo "export-json: archive.json export failed" >&2; exit 1; }
echo "  $(jq length "$OUT/archive.json") repos in the archive"

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
