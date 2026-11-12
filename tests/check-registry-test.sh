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

# 2. A repo added to the seed without regenerating worker/data → stale
fresh
printf '\n[repo.zz-planted-stale-probe]\nprimary = "fv"\ndescription = "planted by check-registry-test"\n' >> "$work/repo/verisim/seed/repos.a2ml"
sed -i -E 's/^(total-repos *= *)([0-9]+)/echo "\1$((\2+1))"/e' "$work/repo/verisim/seed/repos.a2ml"
expect_fail "stale worker/data" "is stale"

# 3. total-repos count lies
fresh
sed -i -E '0,/^total-repos *= *[0-9]+/s//total-repos = 1/' "$work/repo/verisim/seed/repos.a2ml"
expect_fail "total-repos mismatch" "declares total-repos = 1"

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

# Append a planted repo: $1 name, $2 owner, $3 extra seed lines (former,
# retired), then bump total-repos. Regenerate with regen.
plant() {
  printf '\n[repo.%s]\nprimary = "fv"\ndescription = "planted by check-registry-test"\nowner = "%s"\n%s' \
    "$1" "$2" "$3" >> "$work/repo/verisim/seed/repos.a2ml"
  sed -i -E 's/^(total-repos *= *)([0-9]+)/echo "\1$((\2+1))"/e' "$work/repo/verisim/seed/repos.a2ml"
}
plant_moved() { plant zz-planted-moved-probe "$1" "former = $2"$'\n'; }
regen() { bash "$work/repo/sync/export-json.sh" >/dev/null 2>&1; }

# 6. Path reuse by the same repo: a repo that moved away and came back is
#    legal, keeps its birth id, and its archive lists both earlier generations.
fresh
plant_moved hyperpolymath '["hyperpolymath/zz-planted-moved-probe@2026-01-01", "metadatastician/zz-planted-moved-probe@2026-02-01"]'
regen || { echo "FAIL: [path reuse] export refused a legal return to an earlier path"; exit 1; }
bash "$work/repo/scripts/check-registry.sh" >/dev/null || { echo "FAIL: [path reuse] gate refused a legal return to an earlier path"; exit 1; }
gens=$(jq -c '.[] | select(.name == "zz-planted-moved-probe") | [.generation, (.former | map(.generation))]' "$work/repo/worker/data/archive.json")
[[ "$gens" = '[3,[1,2]]' ]] || { echo "FAIL: [path reuse] expected generations [3,[1,2]], got $gens"; exit 1; }
echo "ok: [path reuse] a return to an earlier path passes, generations $gens"

# 7. ADR 0008: a moved repo keeps the id of its birth path, not its current path
fresh
plant_moved catachresis-colloquium '["metadatastician/zz-planted-moved-probe@2026-11-10"]'
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

# 9. A malformed former entry stops the export, so the gate fails
fresh
plant_moved catachresis-colloquium '["metadatastician/zz-planted-moved-probe"]'
expect_fail "malformed former" "export-json.sh failed"

# 9b. A shell expansion in a former path is refused before any id derives
fresh
plant_moved catachresis-colloquium '["metadatastician/$(touch planted-probe)@2026-11-10"]'
expect_fail "unsafe birth path" "export-json.sh failed"
[[ ! -e "$work/repo/planted-probe" && ! -e planted-probe ]] || { echo "FAIL: [unsafe birth path] the seed value ran as a command"; exit 1; }

# 10. A new repo on a path another repo left (a rename here) would mint the
#     same id as the repo born there: refused.
fresh
plant zz-planted-renamed-probe hyperpolymath 'former = ["hyperpolymath/zz-planted-vacated-probe@2026-11-10"]'$'\n'
plant zz-planted-vacated-probe hyperpolymath ''
regen
expect_fail "vacated path reused" "uuid is shared by more than one repo"

# 11. A new repo whose id equals a retired id: refused.
fresh
plant zz-planted-moved-probe catachresis-colloquium 'former = ["hyperpolymath/zz-planted-moved-probe@2026-11-10"]'$'\n''retired = ["hyperpolymath/zz-planted-retired-probe@2026-11-12"]'$'\n'
plant zz-planted-retired-probe hyperpolymath ''
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

echo "check-registry-test: PASS (baseline, path reuse, birth id and an unchanged base pass; 15 planted failures fire)"
