#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
#
# Planted-failure test for scripts/check-registry.sh. A gate that has never
# been seen to fail proves nothing, so this copies the tracked tree to a
# scratch directory, breaks it in three distinct ways and asserts that the gate
# fails each time with the expected message, then asserts it passes unbroken.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fresh() {
  rm -rf "$work/repo"; mkdir -p "$work/repo"
  git -C "$ROOT" ls-files -z --cached --others --exclude-standard sync scripts verisim/seed worker/data \
    | tar -C "$ROOT" --null -T - -cf - | tar -C "$work/repo" -xf -
}

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

echo "check-registry-test: PASS (baseline passes, 3 planted failures fire)"
