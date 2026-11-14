#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
#
# Planted-failure test for scripts/check-registry.sh. A gate that has never
# been seen to fail proves nothing, so this copies the tracked tree to a
# scratch directory, breaks it in distinct ways and asserts that the gate fails
# each time with the expected message, then asserts it passes unbroken.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Every scratch copy shares one verified generator, fetched once into the
# scratch directory. sync/uuid-v8.sh checks its sha256 on every run.
export GV_UUID_V8_JS="${GV_UUID_V8_JS:-$work/uuid-v8.js}"
bash "$ROOT/sync/uuid-v8.sh" </dev/null

# Recreate $work/repo from the current registry sources and data for an isolated case.
fresh() {
  rm -rf "$work/repo"; mkdir -p "$work/repo"
  git -C "$ROOT" ls-files -z --cached --others --exclude-standard sync scripts verisim/seed worker/data \
    | tar -C "$ROOT" --null -T - -cf - | tar -C "$work/repo" -xf -
}

# Assert the scratch gate fails with output matching the basic regex in $2.
# Use $1 as the case label; print diagnostics and exit 1 on an unexpected result.
expect_fail() {
  local label="$1" pattern="$2" out
  if out=$(bash "$work/repo/scripts/check-registry.sh" 2>&1); then
    echo "FAIL: [$label] gate passed but should have failed"; echo "$out"; exit 1
  fi
  if ! grep -q -- "$pattern" <<<"$out"; then
    echo "FAIL: [$label] gate failed for the wrong reason; wanted /$pattern/, got:"; echo "$out"; exit 1
  fi
  echo "ok: [$label] gate fails with: $(grep -- "$pattern" <<<"$out" | head -1)"
}

# 1. Unbroken tree passes
fresh
bash "$work/repo/scripts/check-registry.sh" >/dev/null || { echo "FAIL: gate rejects the committed tree"; exit 1; }
echo "ok: [baseline] gate passes on the tracked tree"

SEED="$work/repo/verisim/seed/chora-registry_praxis.deed"

# Append a planted (repo …) record to the seed deed and bump :total-repos.
# $1 name, $2 owner, $3 birth path (owner/name), $4 extra member lines such
# as (former …) or (retired …), $5 minting domain (default gv-clade-index),
# $6 a stored id to use instead of the derived one. The seed's last line is
# the closing ")" of the praxis-deed.
plant() {
  local domain="${5:-gv-clade-index}" id="${6:-}"
  if [[ -z "$id" ]]; then
    id=$(printf '%s\t%s\t%s\n' "${3%%/*}" "${3#*/}" "$domain" | bash "$ROOT/sync/uuid-v8.sh")
  fi
  sed -i '$d' "$SEED"
  printf '  (repo :name "%s" :owner "%s"\n        :uuid #uuid"%s" :minted-in %s\n        :description "planted by check-registry-test"\n        (lineage :type standalone)\n        (placement :scheme clade-12 :category fv :primary #t)%s)\n)\n' \
    "$1" "$2" "$id" "$domain" "$4" >> "$SEED"
  sed -i -E 's/^(  :total-repos +)([0-9]+)$/echo "\1$((\2+1))"/e' "$SEED"
}
# A (former …) member line: $1 generation, $2 path, $3 date.
former() { printf '\n        (former :generation %s :path "%s" :until "%s")' "$1" "$2" "$3"; }
retired() { printf '\n        (retired :path "%s" :until "%s")' "$1" "$2"; }
regen() { bash "$work/repo/sync/export-json.sh" >/dev/null 2>&1; }

# 2. A repo added to the seed without regenerating worker/data → stale
fresh
plant zz-planted-stale-probe hyperpolymath hyperpolymath/zz-planted-stale-probe ''
expect_fail "stale worker/data" "is stale"

# 3. total-repos count lies
fresh
sed -i -E 's/^(  :total-repos +)[0-9]+$/\11/' "$SEED"
expect_fail "total-repos mismatch" "declares :total-repos 1"

# 4. A uuid edited by hand in repos.json (and mirrored into index.json so drift stays quiet)
fresh
first=$(jq -r '.[0].name' "$work/repo/worker/data/repos.json")
bad="00000000-0000-5000-8000-000000000000"
jq --arg n "$first" --arg u "$bad" 'map(if .name==$n then .uuid=$u else . end)' \
  "$work/repo/worker/data/repos.json" > "$work/r.json" && mv "$work/r.json" "$work/repo/worker/data/repos.json"
jq --arg n "$first" --arg u "$bad" '.by_name[$n].uuid=$u' \
  "$work/repo/worker/data/index.json" > "$work/i.json" && mv "$work/i.json" "$work/repo/worker/data/index.json"
expect_fail "tampered uuid" "is stale\|uuid for $first"

# 5. A uuid_v8 edited by hand (mirrored the same way)
fresh
bad8="00000000-0000-8000-8000-000000000000"
jq --arg n "$first" --arg u "$bad8" 'map(if .name==$n then .uuid_v8=$u else . end)' \
  "$work/repo/worker/data/repos.json" > "$work/r.json" && mv "$work/r.json" "$work/repo/worker/data/repos.json"
jq --arg n "$first" --arg u "$bad8" '.by_name[$n].uuid_v8=$u' \
  "$work/repo/worker/data/index.json" > "$work/i.json" && mv "$work/i.json" "$work/repo/worker/data/index.json"
expect_fail "tampered uuid_v8" "is stale\|uuid_v8 for $first"


# 6. Path reuse by the same repo: a repo that moved away and came back is
#    legal, keeps its birth id, and its archive lists both earlier generations.
fresh
plant zz-planted-moved-probe hyperpolymath hyperpolymath/zz-planted-moved-probe \
  "$(former 1 hyperpolymath/zz-planted-moved-probe 2026-01-01)$(former 2 metadatastician/zz-planted-moved-probe 2026-02-01)"
regen || { echo "FAIL: [path reuse] export refused a legal return to an earlier path"; exit 1; }
bash "$work/repo/scripts/check-registry.sh" >/dev/null || { echo "FAIL: [path reuse] gate refused a legal return to an earlier path"; exit 1; }
gens=$(jq -c '.[] | select(.name == "zz-planted-moved-probe") | [.generation, (.former | map(.generation))]' "$work/repo/worker/data/archive.json")
[[ "$gens" = '[3,[1,2]]' ]] || { echo "FAIL: [path reuse] expected generations [3,[1,2]], got $gens"; exit 1; }
echo "ok: [path reuse] a return to an earlier path passes, generations $gens"

# 7. ADR 0008: a moved repo keeps the id of its birth path, not its current path
fresh
plant zz-planted-moved-probe catachresis-colloquium metadatastician/zz-planted-moved-probe \
  "$(former 1 metadatastician/zz-planted-moved-probe 2026-11-10)"
regen || { echo "FAIL: [birth id] export failed on a legal move"; exit 1; }
got=$(jq -r '.[] | select(.name == "zz-planted-moved-probe") | .uuid' "$work/repo/worker/data/repos.json")
want=$(uuidgen --sha1 --namespace @url --name "github.com/metadatastician/zz-planted-moved-probe")
[[ "$got" = "$want" ]] || { echo "FAIL: [birth id] moved repo has $got, its birth path gives $want"; exit 1; }
bash "$work/repo/scripts/check-registry.sh" >/dev/null || { echo "FAIL: [birth id] gate refused a legal move"; exit 1; }
echo "ok: [birth id] a moved repo keeps the id of its birth path"

# 8. A moved repo whose id was reminted from its current path (the ADR 0007
#    rule, edited by hand and mirrored into index.json and archive.json)
fresh
remint=$(uuidgen --sha1 --namespace @url --name "github.com/metadatastician/standards")
jq --arg u "$remint" 'map(if .name=="standards" then .uuid=$u else . end)' \
  "$work/repo/worker/data/repos.json" > "$work/r.json" && mv "$work/r.json" "$work/repo/worker/data/repos.json"
jq --arg u "$remint" '.by_name.standards.uuid=$u' \
  "$work/repo/worker/data/index.json" > "$work/i.json" && mv "$work/i.json" "$work/repo/worker/data/index.json"
jq --arg u "$remint" 'map(if .name=="standards" then .uuid=$u else . end)' \
  "$work/repo/worker/data/archive.json" > "$work/a.json" && mv "$work/a.json" "$work/repo/worker/data/archive.json"
expect_fail "reminted from current path" "is stale\|uuid for standards"

# 9. A malformed former entry: the seed is refused
fresh
plant zz-planted-moved-probe catachresis-colloquium metadatastician/zz-planted-moved-probe \
  "$(former 1 metadatastician/zz-planted-moved-probe 2026-11)"
expect_fail "malformed former" "refused the seed"

# 9b. A shell expansion in a former path is refused before any id derives
fresh
plant zz-planted-moved-probe catachresis-colloquium metadatastician/zz-planted-moved-probe \
  "$(former 1 'metadatastician/$(touch planted-probe)' 2026-11-10)"
expect_fail "unsafe birth path" "refused the seed"
[[ ! -e "$work/repo/planted-probe" && ! -e planted-probe ]] || { echo "FAIL: [unsafe birth path] the seed value ran as a command"; exit 1; }

# 10. A new repo on a path another repo left (a rename here) would mint the
#     same id as the repo born there: refused.
fresh
plant zz-planted-renamed-probe hyperpolymath hyperpolymath/zz-planted-vacated-probe \
  "$(former 1 hyperpolymath/zz-planted-vacated-probe 2026-11-10)"
plant zz-planted-vacated-probe hyperpolymath hyperpolymath/zz-planted-vacated-probe ''
regen
expect_fail "vacated path reused" "uuid is shared by more than one repo"

# 11. A new repo whose id equals a retired id: refused.
fresh
plant zz-planted-moved-probe catachresis-colloquium hyperpolymath/zz-planted-moved-probe \
  "$(former 1 hyperpolymath/zz-planted-moved-probe 2026-11-10)$(retired hyperpolymath/zz-planted-retired-probe 2026-11-12)"
plant zz-planted-retired-probe hyperpolymath hyperpolymath/zz-planted-retired-probe ''
regen
expect_fail "retired id reused" "a retired id is never minted again"

# 12. A retired uuid edited by hand in archive.json
fresh
bad="00000000-0000-5000-8000-000000000000"
jq --arg u "$bad" 'map(if .name=="standards" then .retired[0].uuid=$u else . end)' \
  "$work/repo/worker/data/archive.json" > "$work/a.json" && mv "$work/a.json" "$work/repo/worker/data/archive.json"
expect_fail "tampered retired uuid" "archive.json is stale\|retired uuid for standards"

# 13. A birth path edited by hand in archive.json
fresh
jq 'map(if .name=="standards" then .birth="metadatastician/standards" else . end)' \
  "$work/repo/worker/data/archive.json" > "$work/a.json" && mv "$work/a.json" "$work/repo/worker/data/archive.json"
expect_fail "tampered birth path" "archive.json is stale\|uuid for standards\|birth must be"

# 14. A generation gap edited by hand in archive.json
fresh
jq 'map(if .name=="standards" then .former[0].generation=2 else . end)' \
  "$work/repo/worker/data/archive.json" > "$work/a.json" && mv "$work/a.json" "$work/repo/worker/data/archive.json"
expect_fail "archive generation gap" "archive.json is stale\|generations must count"

# 15. Archive data leaked into the served repos.json (mirrored into index.json)
fresh
jq --arg n "$first" 'map(if .name==$n then .birth="x/y" else . end)' \
  "$work/repo/worker/data/repos.json" > "$work/r.json" && mv "$work/r.json" "$work/repo/worker/data/repos.json"
jq --arg n "$first" '.by_name[$n].birth="x/y"' \
  "$work/repo/worker/data/index.json" > "$work/i.json" && mv "$work/i.json" "$work/repo/worker/data/index.json"
expect_fail "archive leaked into repos.json" "is stale\|archive data reached repos.json"

# 16. ADR 0008: the base's repos are all still registered, with the same ids
fresh
cp "$work/repo/worker/data/repos.json" "$work/base-repos.json"
GV_BASE_REPOS_JSON="$work/base-repos.json" bash "$work/repo/scripts/check-registry.sh" >/dev/null \
  || { echo "FAIL: [never removed] gate refused an unchanged registry"; exit 1; }
echo "ok: [never removed] an unchanged registry passes against its base"

# 17. A repo in the base that the head no longer lists: refused
jq '. + [{"name": "zz-planted-removed-probe", "uuid": "00000000-0000-5000-8000-000000000001"}]' \
  "$work/repo/worker/data/repos.json" > "$work/base-repos.json"
out=$(GV_BASE_REPOS_JSON="$work/base-repos.json" bash "$work/repo/scripts/check-registry.sh" 2>&1) \
  && { echo "FAIL: [repo removed] gate passed"; exit 1; }
grep -q "removed from the seed: zz-planted-removed-probe" <<<"$out" \
  || { echo "FAIL: [repo removed] wrong reason: $out"; exit 1; }
echo "ok: [repo removed] gate fails with: $(grep 'removed from the seed' <<<"$out")"

# 18. A registered repo whose id differs from the base: refused
jq --arg n "$first" 'map(if .name==$n then .uuid="00000000-0000-5000-8000-000000000002" else . end)' \
  "$work/repo/worker/data/repos.json" > "$work/base-repos.json"
out=$(GV_BASE_REPOS_JSON="$work/base-repos.json" bash "$work/repo/scripts/check-registry.sh" 2>&1) \
  && { echo "FAIL: [id changed] gate passed"; exit 1; }
grep -q "a registered id changed: $first" <<<"$out" \
  || { echo "FAIL: [id changed] wrong reason: $out"; exit 1; }
echo "ok: [id changed] gate fails with: $(grep 'registered id changed' <<<"$out" | cut -c1-120)"

# 19. The seed stores an id that is not the derivation of the birth path
fresh
plant zz-planted-wrong-id-probe hyperpolymath hyperpolymath/zz-planted-wrong-id-probe '' \
  gv-clade-index 00000000-0000-8000-8000-000000000000
regen
expect_fail "stored id wrong" "the seed stores uuid"

# 20. A placement in a category the scheme does not hold: the seed is refused
fresh
plant zz-planted-category-probe hyperpolymath hyperpolymath/zz-planted-category-probe \
  $'\n        (placement :scheme clade-12 :category zz :rank 1)'
expect_fail "unknown category" "refused the seed"

# 21. V9: a repo born after V9 is minted in chora-registry and passes
fresh
plant zz-planted-v9-probe hyperpolymath hyperpolymath/zz-planted-v9-probe '' chora-registry
regen || { echo "FAIL: [V9 mint] export refused a chora-registry id"; exit 1; }
got=$(jq -r '.[] | select(.name == "zz-planted-v9-probe") | .uuid_v8' "$work/repo/worker/data/repos.json")
want=$(printf 'hyperpolymath\tzz-planted-v9-probe\tchora-registry\n' | bash "$ROOT/sync/uuid-v8.sh")
[[ "$got" = "$want" ]] || { echo "FAIL: [V9 mint] served $got, chora-registry derivation gives $want"; exit 1; }
bash "$work/repo/scripts/check-registry.sh" >/dev/null || { echo "FAIL: [V9 mint] gate refused a chora-registry id"; exit 1; }
echo "ok: [V9 mint] a repo minted in chora-registry derives and serves that id"

# 22. A repo whose stored domain does not match the domain its id was minted in
fresh
plant zz-planted-domain-probe hyperpolymath hyperpolymath/zz-planted-domain-probe '' chora-registry \
  "$(printf 'hyperpolymath\tzz-planted-domain-probe\n' | bash "$ROOT/sync/uuid-v8.sh")"
regen
expect_fail "wrong minting domain" "the seed stores uuid"

echo "check-registry-test: PASS (baseline, path reuse, birth id and an unchanged base pass; 19 planted failures fire; a chora-registry mint passes)"
