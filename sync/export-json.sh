#!/usr/bin/env bash
# SPDX-License-Identifier: PMPL-1.0-or-later
# export-json.sh — Convert seed A2ML to JSON for Cloudflare KV
#
# Produces:
#   worker/data/repos.json   — all repos with clade assignments
#   worker/data/clades.json  — clade definitions
#   worker/data/index.json   — lookup tables (by-name, by-clade)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SEED="$ROOT/verisimdb/seed"
OUT="$ROOT/worker/data"

mkdir -p "$OUT"

# Parse repos.a2ml into JSON array
echo "Exporting repos..."
bash "$SCRIPT_DIR/parse-repos.sh" "$SEED/repos.a2ml" | awk -F'\t' '
BEGIN { printf "[\n" }
NR > 1 { printf ",\n" }
{
    name = $1; primary = $2; secondary = $3; lineage = $4; parent = $5; desc = $6
    gsub(/"/, "\\\"", desc)
    # Generate UUID deterministically
    cmd = "uuidgen --sha1 --namespace @url --name \"github.com/hyperpolymath/" name "\""
    cmd | getline uuid
    close(cmd)
    printf "  {\"name\":\"%s\",\"uuid\":\"%s\",\"clade\":\"%s\",\"secondary\":%s,\"lineage\":\"%s\",\"parent\":\"%s\",\"description\":\"%s\",\"prefixed\":\"%s-%s\",\"github\":\"hyperpolymath/%s\"}", name, uuid, primary, secondary, lineage, parent, desc, primary, name, name
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
python3 -c "
import json, sys

with open('$OUT/repos.json') as f:
    repos = json.load(f)
with open('$OUT/clades.json') as f:
    clades = json.load(f)

by_clade = {}
for r in repos:
    c = r['clade']
    if c not in by_clade:
        by_clade[c] = []
    by_clade[c].append(r['name'])

by_name = {r['name']: r for r in repos}

clade_stats = []
for c in clades:
    members = by_clade.get(c['code'], [])
    clade_stats.append({
        **c,
        'member_count': len(members),
        'members': members
    })

index = {
    'total_repos': len(repos),
    'total_clades': len(clades),
    'generated': '$(date -u +%Y-%m-%dT%H:%M:%SZ)',
    'clades': clade_stats,
    'by_name': by_name
}

with open('$OUT/index.json', 'w') as f:
    json.dump(index, f, indent=2)

print(f'  Index: {len(repos)} repos across {len(clades)} clades')
" 2>&1

echo "Done. Output in $OUT/"
ls -lh "$OUT/"
