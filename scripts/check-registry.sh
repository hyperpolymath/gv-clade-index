#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
#
# Registry integrity gate. Proves that the committed registry is one coherent
# artefact, from the hand-edited seed to the generated JSON the Worker serves.
#
#   1. repos.a2ml parses to exactly `total-repos` rows, with unique names.
#   2. worker/data/{repos,clades,index}.json are valid JSON.
#   3. worker/data is NOT stale: a fresh export into a scratch directory is
#      byte-identical (index.json compared without its `generated` stamp).
#   4. Counts agree across seed, repos.json and index.json.
#   5. Identity, for every entry: `uuid` is the UUIDv5 of
#      `github.com/<owner>/<name>` in the @url namespace, the /v1 identity
#      (additive-only, ADR 0004); `uuid_v8` is the ADR-008 profile C UUIDv8
#      of the same name in the `gv-clade-index` domain (D320), from
#      standards' shared generator (sync/uuid-v8.sh).
#
# Exit 0 only when every check passes. Never writes inside the repository.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SEED="$ROOT/verisim/seed/repos.a2ml"
DATA="$ROOT/worker/data"

fail() { echo "check-registry: FAIL: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || fail "required tool missing: $1"; }
need jq; need uuidgen; need cmp; need bun

# 1. Parse round-trip ------------------------------------------------------
rows=$(bash "$ROOT/sync/parse-repos.sh" "$SEED" | wc -l | tr -d ' ')
declared=$(grep -E '^total-repos *= *[0-9]+' "$SEED" | head -1 | sed -E 's/.*= *//')
[ -n "$declared" ] || fail "repos.a2ml has no 'total-repos = N' line"
[ "$rows" = "$declared" ] || fail "repos.a2ml declares total-repos = $declared but parses to $rows rows"
dups=$(bash "$ROOT/sync/parse-repos.sh" "$SEED" | cut -f1 | sort | uniq -d | tr '\n' ' ')
[ -z "$dups" ] || fail "duplicate repo names in repos.a2ml: $dups"
echo "check-registry: seed parses to $rows rows = total-repos, names unique"

# 2. JSON validity --------------------------------------------------------
for f in repos clades index; do
  [ -f "$DATA/$f.json" ] || fail "$DATA/$f.json is missing"
  jq empty "$DATA/$f.json" 2>/dev/null || fail "$DATA/$f.json is not valid JSON"
done
echo "check-registry: worker/data JSON valid"

# 3. Drift: fresh export must match the committed files -------------------
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
GV_EXPORT_OUT="$scratch" bash "$ROOT/sync/export-json.sh" >/dev/null 2>&1 \
  || fail "sync/export-json.sh failed on the current seed"
for f in repos clades; do
  cmp -s "$scratch/$f.json" "$DATA/$f.json" \
    || fail "worker/data/$f.json is stale: run 'bash sync/export-json.sh' and commit the result"
done
if ! diff -q <(jq -S 'del(.generated)' "$scratch/index.json") <(jq -S 'del(.generated)' "$DATA/index.json") >/dev/null; then
  fail "worker/data/index.json is stale: run 'bash sync/export-json.sh' and commit the result"
fi
echo "check-registry: worker/data matches a fresh export (no drift)"

# 4. Counts agree ---------------------------------------------------------
json_repos=$(jq 'length' "$DATA/repos.json")
idx_total=$(jq '.total_repos' "$DATA/index.json")
idx_names=$(jq '.by_name | length' "$DATA/index.json")
[ "$json_repos" = "$rows" ] || fail "repos.json has $json_repos entries, seed has $rows"
[ "$idx_total" = "$rows" ] || fail "index.json total_repos = $idx_total, seed has $rows"
[ "$idx_names" = "$rows" ] || fail "index.json by_name has $idx_names keys, seed has $rows"
echo "check-registry: counts agree ($rows)"

# 5. Identity -------------------------------------------------------------
# Every uuid is the UUIDv5 of github.com/<owner>/<name> in the @url namespace:
# the identity /v1 has always served, which ADR 0004 forbids retyping. Every
# uuid_v8 is the ADR-008 profile C id of the same name in the gv-clade-index
# domain (D320), from standards' shared generator; it is what a deed's #u8
# literal names.
while IFS=$'\t' read -r name github uuid; do
  expect=$(uuidgen --sha1 --namespace @url --name "github.com/$github")
  [ "$uuid" = "$expect" ] || fail "uuid for $name is ${uuid:-<missing>}, UUIDv5 derivation gives $expect"
done < <(jq -r '.[] | [.name, .github, (.uuid // "")] | @tsv' "$DATA/repos.json")
echo "check-registry: uuid re-derives as UUIDv5 for all $json_repos repos"
jq -r '.[] | .github | sub("/"; "\t")' "$DATA/repos.json" \
  | bash "$ROOT/sync/uuid-v8.sh" > "$scratch/v8.txt" || fail "sync/uuid-v8.sh failed"
while IFS=$'\t' read -r name uuid_v8 expect; do
  [ "$uuid_v8" = "$expect" ] || fail "uuid_v8 for $name is ${uuid_v8:-<missing>}, profile C derivation gives $expect"
done < <(paste <(jq -r '.[] | [.name, (.uuid_v8 // "")] | @tsv' "$DATA/repos.json") "$scratch/v8.txt")
echo "check-registry: uuid_v8 is profile C UUIDv8 for all $json_repos repos"

echo "check-registry: PASS"
