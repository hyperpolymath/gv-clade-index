#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
#
# Read the registry seed, verisim/seed/chora-registry_praxis.deed, and emit TSV:
#   name\tprimary\tsecondary\tlineage\tparent\tdescription\towner\tformer\tretired
#
#   bash sync/parse-repos.sh [SEED] [--ids | --total | --categories]
#
# The rows keep the column contract of the A2ML parser this replaces (the seed
# was repos.a2ml until its conversion under the single recorded D313
# exception, owner ruling 2026-11-14), so consumers are unchanged. The modes
# and the checks made while reading are described in sync/parse-repos.js.
#
# The deed parser is standards' own, 1-formats/deed/tools/deed_lint.js, never
# a copy: it is fetched at a pinned standards commit into the user cache,
# outside the checkout, and its sha256 is checked on every run, as
# sync/uuid-v8.sh does for the id generator. GV_DEED_LINT_JS names an existing
# copy. Needs bun, the estate's tier-1 runtime.

set -euo pipefail

STANDARDS_REV=490b952b99eb22052c0ec5a1001b95dab1561097
DEED_LINT_SHA256=6b6481b188b8228f2b0c5063835c312d966ffd19a96a9e26018b06316f4852a5
JS="${GV_DEED_LINT_JS:-${XDG_CACHE_HOME:-$HOME/.cache}/gv-clade-index/deed_lint-$STANDARDS_REV.js}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SEED_FILE="${1:-$SCRIPT_DIR/../verisim/seed/chora-registry_praxis.deed}"
MODE="${2:---rows}"

# Print the supplied failure message to stderr and terminate with status 1.
fail() { echo "parse-repos: $*" >&2; exit 1; }
command -v bun >/dev/null 2>&1 || fail "bun is required (estate tier-1 runtime)"

if [ ! -f "$JS" ]; then
  mkdir -p "$(dirname "$JS")"
  curl --proto '=https' --proto-redir '=https' --fail --silent --show-error --location \
    "https://raw.githubusercontent.com/metadatastician/standards/$STANDARDS_REV/1-formats/deed/tools/deed_lint.js" \
    --output "$JS.part" || fail "could not fetch deed_lint.js at standards@$STANDARDS_REV"
  mv "$JS.part" "$JS"
fi
echo "$DEED_LINT_SHA256  $JS" | sha256sum --check --strict --status \
  || fail "$JS is not standards@$STANDARDS_REV 1-formats/deed/tools/deed_lint.js (sha256 mismatch)"

DEED_LINT_JS="$JS" exec bun "$SCRIPT_DIR/parse-repos.js" "$SEED_FILE" "$MODE"
