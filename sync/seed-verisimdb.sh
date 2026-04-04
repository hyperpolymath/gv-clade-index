#!/usr/bin/env bash
# SPDX-License-Identifier: PMPL-1.0-or-later
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell
#
# Seed VeriSimDB with the static JSON data files.
#
# Usage:
#   ./sync/seed-verisimdb.sh [VERISIMDB_URL]
#
# VERISIMDB_URL defaults to http://localhost:8080
#
# This script seeds the following VeriSimDB collections:
#   clade:repos   — one document per repo (from worker/data/repos.json)
#   clade:clades  — one document per clade (from worker/data/clades.json)
#   clade:index   — pre-built combined index (from worker/data/index.json)
#
# Run this script after initial setup and after any changes to the static
# JSON data files so that VeriSimDB stays in sync with Cloudflare KV.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DATA_DIR="${REPO_ROOT}/worker/data"

VERISIMDB_URL="${1:-${VERISIMDB_URL:-http://localhost:8080}}"
API_BASE="${VERISIMDB_URL}/api/v1"

echo "[seed-verisimdb] Base URL: ${VERISIMDB_URL}"
echo "[seed-verisimdb] Data dir: ${DATA_DIR}"

# ── Helper ────────────────────────────────────────────────────────────────

put_doc() {
  local collection="$1"
  local id="$2"
  local body="$3"

  local url="${API_BASE}/${collection}/${id}"
  local http_code
  http_code=$(curl -s -o /dev/null -w "%{http_code}" \
    -X PUT \
    -H "Content-Type: application/json" \
    -d "${body}" \
    "${url}")

  if [[ "$http_code" =~ ^(200|201|204)$ ]]; then
    return 0
  else
    echo "[seed-verisimdb] WARN: PUT ${url} returned ${http_code}" >&2
    return 1
  fi
}

# ── Seed clades ───────────────────────────────────────────────────────────

echo "[seed-verisimdb] Seeding clade:clades ..."
CLADES_JSON="${DATA_DIR}/clades.json"
if [[ ! -f "${CLADES_JSON}" ]]; then
  echo "[seed-verisimdb] ERROR: ${CLADES_JSON} not found" >&2
  exit 1
fi

seeded_clades=0
error_clades=0

# Use jq to iterate over the clades array
while IFS= read -r clade_doc; do
  code=$(echo "${clade_doc}" | jq -r '.code')
  if put_doc "clade:clades" "${code}" "${clade_doc}"; then
    seeded_clades=$((seeded_clades + 1))
  else
    error_clades=$((error_clades + 1))
  fi
done < <(jq -c '.[]' "${CLADES_JSON}")

echo "[seed-verisimdb] Clades: seeded=${seeded_clades} errors=${error_clades}"

# ── Seed repos ────────────────────────────────────────────────────────────

echo "[seed-verisimdb] Seeding clade:repos ..."
REPOS_JSON="${DATA_DIR}/repos.json"
if [[ ! -f "${REPOS_JSON}" ]]; then
  echo "[seed-verisimdb] ERROR: ${REPOS_JSON} not found" >&2
  exit 1
fi

seeded_repos=0
error_repos=0

while IFS= read -r repo_doc; do
  name=$(echo "${repo_doc}" | jq -r '.name')
  if put_doc "clade:repos" "${name}" "${repo_doc}"; then
    seeded_repos=$((seeded_repos + 1))
  else
    error_repos=$((error_repos + 1))
  fi
done < <(jq -c '.[]' "${REPOS_JSON}")

echo "[seed-verisimdb] Repos: seeded=${seeded_repos} errors=${error_repos}"

# ── Seed index ────────────────────────────────────────────────────────────

echo "[seed-verisimdb] Seeding clade:index/latest ..."
INDEX_JSON="${DATA_DIR}/index.json"
if [[ -f "${INDEX_JSON}" ]]; then
  if put_doc "clade:index" "latest" "$(cat "${INDEX_JSON}")"; then
    echo "[seed-verisimdb] Index: seeded=1"
  else
    echo "[seed-verisimdb] Index: errors=1"
  fi
else
  echo "[seed-verisimdb] WARN: ${INDEX_JSON} not found — skipping index seed" >&2
fi

# ── Summary ───────────────────────────────────────────────────────────────

total_seeded=$((seeded_clades + seeded_repos))
total_errors=$((error_clades + error_repos))

echo ""
echo "[seed-verisimdb] Done. total_seeded=${total_seeded} total_errors=${total_errors}"

if [[ "${total_errors}" -gt 0 ]]; then
  echo "[seed-verisimdb] Some documents failed to seed. Check VeriSimDB logs." >&2
  exit 1
fi
