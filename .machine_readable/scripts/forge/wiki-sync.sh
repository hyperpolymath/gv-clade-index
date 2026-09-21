#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
#
# wiki-sync.sh — publish docs/wikis/*.adoc to the GitHub-hosted wiki (one-way)
#
# docs/wikis/ is the source of truth (docs/wikis/README.adoc); the forge wiki
# is a published mirror. This script is the publisher half of that statement.
# Closes the "wiki sync" follow-up (#32).
#
# Usage:
#   bash .machine_readable/scripts/forge/wiki-sync.sh [--dry-run] [SRC_DIR]
#
# Environment:
#   WIKI_SYNC_PAT   token with contents:write on hyperpolymath/gv-clade-index
#                   (the built-in GITHUB_TOKEN cannot push to the wiki git).
#   WIKI_REPO_URL   override the wiki git URL (default derived from origin).
#   WIKI_BRANCH     wiki git branch (default: master — Gollum's default).
#
# Behaviour:
#   * One-way push: repo → wiki. The wiki is never a source; local edits there
#     are overwritten on the next sync.
#   * Works in a mktemp workspace — never writes inside the repository.
#   * README.adoc is published as Home.adoc (Gollum's landing page name).
#   * *-AI-MANIFEST.a2ml (machine-only) files are not published.
#   * AsciiDoc crosslinks `link:Page.adoc[` are rewritten to extension-less
#     `link:Page[` so they resolve between wiki pages (Gollum serves pages
#     without extensions; the source-tree relative form does not resolve there).
#   * Pushes only when the transformed tree differs from the wiki HEAD.
#   * No token → refuses (dry-run still works with --dry-run). The CI caller
#     gates on secret presence before invoking, per the estate two-step idiom.

set -euo pipefail

SRC_DIR="${2:-docs/wikis}"
DRY_RUN="${1:-}"
DRY_RUN="${DRY_RUN/#--dry-run/dry-run}"
[ "$DRY_RUN" = "dry-run" ] || DRY_RUN="off"

say() { echo "wiki-sync: $*"; }
die() { echo "wiki-sync: ERROR: $*" >&2; exit 1; }

REPO_ROOT="$(git rev-parse --show-toplevel)"
SRC="$REPO_ROOT/$SRC_DIR"
[ -d "$SRC" ] || die "source directory not found: $SRC"

# ── Resolve the wiki URL ──────────────────────────────────────────────────────
# Always derived to the https form (the PAT flow only works over https); ssh
# users can override with WIKI_REPO_URL and run local pushes with their own
# credentials.
if [ -n "${WIKI_REPO_URL:-}" ]; then
    WIKI_URL="$WIKI_REPO_URL"
else
    ORIGIN_URL="$(git -C "$REPO_ROOT" remote get-url origin)" ||
        die "no origin remote and WIKI_REPO_URL not set"
    case "$ORIGIN_URL" in
        git@github.com:*)            BASE="${ORIGIN_URL#git@github.com:}" ;;
        ssh://git@github.com/*)      BASE="${ORIGIN_URL#ssh://git@github.com/}" ;;
        https://github.com/*)        BASE="${ORIGIN_URL#https://github.com/}" ;;
        *) die "unsupported origin URL: $ORIGIN_URL (set WIKI_REPO_URL)" ;;
    esac
    BASE="${BASE%.git}"
    WIKI_URL="https://github.com/${BASE}.wiki.git"
fi

# ── Credentials ───────────────────────────────────────────────────────────────
if [ -z "${WIKI_SYNC_PAT:-}" ] && [ "$DRY_RUN" != "dry-run" ]; then
    die "WIKI_SYNC_PAT not set — refusing to run a real sync (use --dry-run to preview)"
fi
# The token travels via a git credential helper that reads the environment —
# never in the URL, argv, or on disk (and no credential-in-URL pattern for
# scanners to flag).
CRED_ARGS=()
if [ -n "${WIKI_SYNC_PAT:-}" ]; then
    CRED_ARGS=(-c "credential.helper=!f() { echo username=x-access-token; echo password=\$WIKI_SYNC_PAT; }; f")
fi

# ── Stage the transformed tree ────────────────────────────────────────────────
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
STAGE="$WORK/stage"
mkdir -p "$STAGE"

HEAD_SHA="$(git -C "$REPO_ROOT" rev-parse --short HEAD)"

published=0
for f in "$SRC"/*.adoc; do
    [ -e "$f" ] || { say "no .adoc pages in $SRC_DIR — nothing to publish"; exit 0; }
    base="$(basename "$f")"
    case "$base" in
        *-AI-MANIFEST.a2ml) continue ;;   # machine-only, never published
    esac
    # Gollum's landing page must be named Home.
    [ "$base" = "README.adoc" ] && out="Home.adoc" || out="$base"
    # Rewrite tree-relative asciidoc crosslinks to wiki-page form (no .adoc).
    sed -E 's/link:([A-Za-z0-9_-]+)\.adoc\[/link:\1[/g' "$f" > "$STAGE/$out"
    published=$((published + 1))
    say "publish: $base -> $out"
done
[ "$published" -gt 0 ] || die "nothing publishable found in $SRC_DIR"

if [ "$DRY_RUN" = "dry-run" ]; then
    say "dry-run: would publish $published page(s) to $WIKI_URL — no changes made"
    exit 0
fi

# ── Clone, replace, push-if-changed ───────────────────────────────────────────
WIKI_DIR="$WORK/wiki"
if ! git "${CRED_ARGS[@]}" clone -q "$WIKI_URL" "$WIKI_DIR" 2>"$WORK/clone.err"; then
    die "clone of the wiki failed (does it exist? first page must be created once in the UI):
$(cat "$WORK/clone.err")"
fi

git -C "$WIKI_DIR" rm -rq --ignore-unmatch . 2>/dev/null || true
find "$WIKI_DIR" -mindepth 1 -maxdepth 1 ! -name '.git' -exec rm -rf {} +
cp "$STAGE"/*.adoc "$WIKI_DIR"/
git -C "$WIKI_DIR" add -A

if git -C "$WIKI_DIR" diff --cached --quiet; then
    say "wiki already matches source at $HEAD_SHA — nothing to push"
    exit 0
fi

git -C "$WIKI_DIR" \
    -c user.name="${WIKI_COMMIT_NAME:-hyperpolymath-wiki-sync}" \
    -c user.email="${WIKI_COMMIT_EMAIL:-6759885+hyperpolymath@users.noreply.github.com}" \
    commit -qm "wiki: sync from gv-clade-index@$HEAD_SHA

Automated one-way publish of docs/wikis/ (source of truth) to the
forge-hosted wiki. See .machine_readable/scripts/forge/wiki-sync.sh (#32)."

git "${CRED_ARGS[@]}" -C "$WIKI_DIR" push -q origin "${WIKI_BRANCH:-master}"
say "pushed $published page(s) to the wiki (from gv-clade-index@$HEAD_SHA)"
