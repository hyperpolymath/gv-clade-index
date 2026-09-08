#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell
#
# Seed VeriSimDB with the static JSON data files.
#
# Usage:
#   VERISIMDB_URL=https://verisim.example bash sync/seed-verisim.sh
#   bash sync/seed-verisim.sh https://verisim.example
#
# There is deliberately NO default URL: the estate declares no port for
# VeriSimDB (see verisim/README.adoc, Phase 2 pending), and a localhost:8080
# default silently PUT 331 documents at nothing on 2026-09-02. Pass the URL
# explicitly or the script refuses to run.
#
# Collections seeded:
#   clade:repos   — one document per repo (from worker/data/repos.json)
#   clade:clades  — one document per clade (from worker/data/clades.json)
#   clade:index   — pre-built combined index (from worker/data/index.json)
#
# Freshness: before any network call, scripts/check-registry.sh must pass, so a
# stale worker/data (seed edited, export not re-run) can never be pushed.
# Bodies are streamed with --data-binary (stdin or @file), never placed in argv;
# index.json is ~135 KB, which exceeded ARG_MAX with the old `-d "$body"`.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DATA_DIR="${REPO_ROOT}/worker/data"

VERISIMDB_URL="${1:-${VERISIMDB_URL:-}}"
if [[ -z "${VERISIMDB_URL}" ]]; then
  echo "[seed-verisim] ERROR: no VeriSimDB URL. Pass it as \$1 or VERISIMDB_URL; there is no default." >&2
  exit 2
fi
VERISIMDB_URL="${VERISIMDB_URL%/}"
API_BASE="${VERISIMDB_URL}/api/v1"

echo "[seed-verisim] Base URL: ${VERISIMDB_URL}"
echo "[seed-verisim] Data dir: ${DATA_DIR}"

# ── Freshness gate ────────────────────────────────────────────────────────
if ! bash "${REPO_ROOT}/scripts/check-registry.sh"; then
  echo "[seed-verisim] ERROR: registry gate failed; refusing to seed stale or inconsistent data" >&2
  exit 1
fi

# ── Helper ────────────────────────────────────────────────────────────────

# put_doc COLLECTION ID  (body on stdin)
put_doc() {
  local collection="$1"
  local id="$2"
  local url="${API_BASE}/${collection}/${id}"
  local http_code
  http_code=$(curl -s -o /dev/null -w "%{http_code}" \
    -X PUT \
    -H "Content-Type: application/json" \
    --data-binary @- \
    "${url}") || http_code="000"

  if [[ "$http_code" =~ ^(200|201|204)$ ]]; then
    return 0
  else
    echo "[seed-verisim] WARN: PUT ${url} returned ${http_code}" >&2
    return 1
  fi
}

# ── Seed clades ───────────────────────────────────────────────────────────

echo "[seed-verisim] Seeding clade:clades ..."
CLADES_JSON="${DATA_DIR}/clades.json"
seeded_clades=0
error_clades=0
while IFS= read -r clade_doc; do
  code=$(jq -r '.code' <<<"${clade_doc}")
  if put_doc "clade:clades" "${code}" <<<"${clade_doc}"; then
    seeded_clades=$((seeded_clades + 1))
  else
    error_clades=$((error_clades + 1))
  fi
done < <(jq -c '.[]' "${CLADES_JSON}")
echo "[seed-verisim] Clades: seeded=${seeded_clades} errors=${error_clades}"

# ── Seed repos ────────────────────────────────────────────────────────────

echo "[seed-verisim] Seeding clade:repos ..."
REPOS_JSON="${DATA_DIR}/repos.json"
seeded_repos=0
error_repos=0
while IFS= read -r repo_doc; do
  name=$(jq -r '.name' <<<"${repo_doc}")
  if put_doc "clade:repos" "${name}" <<<"${repo_doc}"; then
    seeded_repos=$((seeded_repos + 1))
  else
    error_repos=$((error_repos + 1))
  fi
done < <(jq -c '.[]' "${REPOS_JSON}")
echo "[seed-verisim] Repos: seeded=${seeded_repos} errors=${error_repos}"

# ── Seed index ────────────────────────────────────────────────────────────

echo "[seed-verisim] Seeding clade:index/latest ..."
INDEX_JSON="${DATA_DIR}/index.json"
error_index=0
if put_doc "clade:index" "latest" < "${INDEX_JSON}"; then
  echo "[seed-verisim] Index: seeded=1"
else
  error_index=1
  echo "[seed-verisim] Index: errors=1"
fi

# ── Summary ───────────────────────────────────────────────────────────────

total_seeded=$((seeded_clades + seeded_repos + (1 - error_index)))
total_errors=$((error_clades + error_repos + error_index))

echo ""
echo "[seed-verisim] Done. total_seeded=${total_seeded} total_errors=${total_errors}"

if [[ "${total_errors}" -gt 0 ]]; then
  echo "[seed-verisim] Some documents failed to seed. Check VeriSimDB logs." >&2
  exit 1
fi
