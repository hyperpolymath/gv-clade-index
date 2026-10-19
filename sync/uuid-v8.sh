#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
#
# uuid-v8.sh — clade identifiers as ADR-008 profile C UUIDv8 (D320): domain
# `gv-clade-index`, name `github.com/<owner>/<repo>`.
#
#   printf 'owner\trepo\n' | bash sync/uuid-v8.sh     # one id per input line
#
# The ids come from standards' shared generator, scripts/uuid-v8.js, never
# from a copy of the algorithm here: one implementation per estate language
# is what ADR-008 P1 ships, and a second one could drift. The generator is
# fetched at a pinned standards commit into _build/ and its sha256 is checked
# on every run, so a bumped or edited copy fails instead of minting
# different ids. GV_UUID_V8_JS names an existing copy (the planted-failure
# test passes the caller's). Needs bun, the estate's tier-1 runtime.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STANDARDS_REV=75bd5994470661a099df562d6d5ad2fe744dbd66
UUID_V8_SHA256=60e4c59199c05362f19115d5bd002583615041680796f30f3dcbed33349e96ca
JS="${GV_UUID_V8_JS:-$ROOT/_build/uuid-v8.js}"

fail() { echo "uuid-v8: $*" >&2; exit 1; }
command -v bun >/dev/null 2>&1 || fail "bun is required (estate tier-1 runtime)"

if [ ! -f "$JS" ]; then
  mkdir -p "$(dirname "$JS")"
  curl --proto '=https' --proto-redir '=https' --fail --silent --show-error --location \
    "https://raw.githubusercontent.com/hyperpolymath/standards/$STANDARDS_REV/scripts/uuid-v8.js" \
    --output "$JS.part" || fail "could not fetch scripts/uuid-v8.js at standards@$STANDARDS_REV"
  mv "$JS.part" "$JS"
fi
echo "$UUID_V8_SHA256  $JS" | sha256sum --check --strict --status \
  || fail "$JS is not standards@$STANDARDS_REV scripts/uuid-v8.js (sha256 mismatch)"

UUID_V8_JS="$JS" exec bun -e '
const { profileC } = await import(process.env.UUID_V8_JS);
for (const line of (await Bun.stdin.text()).split("\n")) {
  if (line === "") continue;
  const [owner, repo, extra] = line.split("\t");
  if (!owner || !repo || extra !== undefined) {
    console.error(`uuid-v8: expected "owner<TAB>repo", got ${JSON.stringify(line)}`);
    process.exit(1);
  }
  console.log(profileC("gv-clade-index", `github.com/${owner}/${repo}`));
}
'
