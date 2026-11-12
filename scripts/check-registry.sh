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
#   5. Identity, for every entry: `uuid` is the UUIDv5, in the @url namespace,
#      of `github.com/<owner>/<name>` at the repo's RECORDED BIRTH PATH, not its
#      current path (ADR 0008: an id is minted once and never changes). The
#      birth path is the archive's `birth` for a moved or renamed repo, else the
#      current `github`. `uuid_v8` is the ADR-008 profile C UUIDv8 of the same
#      name in the `gv-clade-index` domain (D320), from standards' shared
#      generator (sync/uuid-v8.sh). Both are unique across the registry.
#   6. Archive (ADR 0008): each archive entry names a current repo at its
#      current path and carries that repo's ids; its `birth` is its first
#      `former` path; generations count 1..n with no gap and the current one is
#      n+1; every retired id re-derives from its own path; no current id equals
#      a retired id or another repo's id, so a vacated path's id is never minted
#      for a new repo; and no archive data reaches repos.json or index.json,
#      the files that are served.
#
# Exit 0 only when every check passes. Never writes inside the repository.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SEED="$ROOT/verisim/seed/repos.a2ml"
DATA="$ROOT/worker/data"

# Print the supplied failure message to stderr and terminate the gate with status 1.
fail() { echo "check-registry: FAIL: $*" >&2; exit 1; }
# Require the command named by $1 on PATH, or terminate the gate with status 1.
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
for f in repos clades index archive; do
  [ -f "$DATA/$f.json" ] || fail "$DATA/$f.json is missing"
  jq empty "$DATA/$f.json" 2>/dev/null || fail "$DATA/$f.json is not valid JSON"
done
echo "check-registry: worker/data JSON valid"

# 3. Drift: fresh export must match the committed files -------------------
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
GV_EXPORT_OUT="$scratch" bash "$ROOT/sync/export-json.sh" >/dev/null 2>&1 \
  || fail "sync/export-json.sh failed on the current seed"
for f in repos clades archive; do
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
# An id is minted once, from the birth path, and never changes (ADR 0008, which
# supersedes ADR 0007 and restores the immortal rule of ADR 0006). A move or
# rename changes `github` only. The birth path is not served: it lives in
# archive.json, which records it for every repo that has moved.
jq -r --slurpfile arch "$DATA/archive.json" '
  ($arch[0] | map({key: .name, value: .birth}) | from_entries) as $birth
  | .[] | [.name, ($birth[.name] // .github), (.uuid // ""), (.uuid_v8 // "")] | @tsv' \
  "$DATA/repos.json" > "$scratch/ids.tsv"
while IFS=$'\t' read -r name birth uuid _; do
  expect=$(uuidgen --sha1 --namespace @url --name "github.com/$birth")
  [[ "$uuid" = "$expect" ]] || fail "uuid for $name is ${uuid:-<missing>}, UUIDv5 of its birth path $birth gives $expect"
done < "$scratch/ids.tsv"
echo "check-registry: uuid re-derives as UUIDv5 of the birth path for all $json_repos repos"
cut -f2 "$scratch/ids.tsv" | sed 's#/#\t#' \
  | bash "$ROOT/sync/uuid-v8.sh" > "$scratch/v8.txt" || fail "sync/uuid-v8.sh failed"
while IFS=$'\t' read -r name birth uuid_v8 expect; do
  [[ "$uuid_v8" = "$expect" ]] || fail "uuid_v8 for $name is ${uuid_v8:-<missing>}, profile C of its birth path $birth gives $expect"
done < <(paste <(cut -f1,2,4 "$scratch/ids.tsv") "$scratch/v8.txt")
echo "check-registry: uuid_v8 is profile C UUIDv8 of the birth path for all $json_repos repos"
for field in uuid uuid_v8; do
  dup=$(jq -r --arg f "$field" '[.[] | {name, id: .[$f]}] | group_by(.id) | map(select(length > 1) | map(.name) | join(" = ")) | join("; ")' "$DATA/repos.json")
  [[ -z "$dup" ]] || fail "$field is shared by more than one repo: $dup (an id belongs to one repo; a vacated path's id is never minted again)"
done
echo "check-registry: uuid and uuid_v8 are unique across the registry"

# 6. Archive (ADR 0008) ------------------------------------------------------
# For reference only, never served: the earlier paths of each moved repo
# (`former`, oldest first, generation 1 = the birth path) and the ids the
# registry served for it and withdrew (`retired`, the ADR 0007 remints).
leak=$(jq -r '[.[] | select(has("former") or has("generation") or has("birth") or has("retired")) | .name] | join(" ")' "$DATA/repos.json")
[[ -z "$leak" ]] || fail "archive data reached repos.json (served): $leak"
leak=$(jq -r '[.by_name[] | select(has("former") or has("generation") or has("birth") or has("retired")) | .name] | join(" ")' "$DATA/index.json")
[[ -z "$leak" ]] || fail "archive data reached index.json (served): $leak"
while IFS=$'\t' read -r name github uuid uuid_v8; do
  cur=$(jq -r --arg n "$name" '.[] | select(.name == $n) | [.github, .uuid, .uuid_v8] | @tsv' "$DATA/repos.json")
  [[ -n "$cur" ]] || fail "archive entry $name is not a current repo"
  IFS=$'\t' read -r cgithub cuuid cuuid_v8 <<<"$cur"
  [[ "$cgithub" = "$github" ]] || fail "archive entry $name says its current path is $github, repos.json says $cgithub"
  [[ "$cuuid" = "$uuid" && "$cuuid_v8" = "$uuid_v8" ]] || fail "archive entry $name carries ids $uuid / $uuid_v8, repos.json has $cuuid / $cuuid_v8"
done < <(jq -r '.[] | [.name, .github, .uuid, .uuid_v8] | @tsv' "$DATA/archive.json")
bad=$(jq -r '.[] | select(.birth != (if (.former | length) > 0 then .former[0].github else .github end)) | .name' "$DATA/archive.json" | tr '\n' ' ')
[[ -z "${bad// }" ]] || fail "archive birth must be the first former path (or the current path when none): $bad"
bad=$(jq -r '.[] | select((.former | map(.generation)) != [range(1; (.former | length) + 1)]
                          or .generation != (.former | length) + 1) | .name' "$DATA/archive.json" | tr '\n' ' ')
[[ -z "${bad// }" ]] || fail "archive generations must count 1..n with the current one n+1: $bad"
retired=$(jq '[.[].retired[]] | length' "$DATA/archive.json")
if [[ "$retired" -gt 0 ]]; then
  while IFS=$'\t' read -r name github uuid; do
    expect=$(uuidgen --sha1 --namespace @url --name "github.com/$github")
    [[ "$uuid" = "$expect" ]] || fail "retired uuid for $name at $github is ${uuid:-<missing>}, UUIDv5 derivation gives $expect"
  done < <(jq -r '.[] | .name as $n | .retired[] | [$n, .github, (.uuid // "")] | @tsv' "$DATA/archive.json")
  jq -r '.[].retired[] | .github | sub("/"; "\t")' "$DATA/archive.json" \
    | bash "$ROOT/sync/uuid-v8.sh" > "$scratch/retired-v8.txt" || fail "sync/uuid-v8.sh failed on retired paths"
  while IFS=$'\t' read -r name github uuid_v8 expect; do
    [[ "$uuid_v8" = "$expect" ]] || fail "retired uuid_v8 for $name at $github is ${uuid_v8:-<missing>}, profile C derivation gives $expect"
  done < <(paste <(jq -r '.[] | .name as $n | .retired[] | [$n, .github, (.uuid_v8 // "")] | @tsv' "$DATA/archive.json") "$scratch/retired-v8.txt")
  reused=$(jq -r --slurpfile arch "$DATA/archive.json" '
    ($arch[0] | [.[] | .name as $n | .retired[] | {owner: $n, github, ids: [.uuid, .uuid_v8]}]) as $ret
    | [.[] | . as $r | $ret[] | select(.ids | index($r.uuid) or index($r.uuid_v8))
       | "\($r.name) has the id retired from \(.owner) at \(.github)"] | join("; ")' "$DATA/repos.json")
  [[ -z "$reused" ]] || fail "a retired id is never minted again: $reused"
fi
echo "check-registry: archive holds $(jq length "$DATA/archive.json") moved repo(s) and $retired retired id pair(s); all re-derive, none reused, none served"

echo "check-registry: PASS"
