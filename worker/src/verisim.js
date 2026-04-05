// SPDX-License-Identifier: PMPL-1.0-or-later
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell
//
// VeriSimDB client for gv-clade-index Cloudflare Worker.
//
// Collection namespaces used:
//   clade:repos   — all 202+ hyperpolymath repos with clade metadata
//   clade:clades  — 12 clade definitions
//   clade:index   — pre-built search index (by_name + by_clade maps)
//
// Dual-write pattern: all mutations go to both Cloudflare KV and VeriSimDB.
// Reads prefer VeriSimDB when VERISIMDB_URL is present in the worker env;
// fall back to KV when VeriSimDB is unreachable.
//
// Configuration (Cloudflare Worker env vars / wrangler.toml [vars]):
//   VERISIMDB_URL — Base URL for VeriSimDB (default: http://localhost:8080)
//
// Query functions exposed:
//   queryByLanguage(env, language) -> [repo, ...]
//   queryByTag(env, tag)           -> [repo, ...]
//   seedFromStaticJson(env, repos, clades) -> { seeded: number }

const API_PREFIX = '/api/v1';
const COL_REPOS   = 'clade:repos';
const COL_CLADES  = 'clade:clades';
const COL_INDEX   = 'clade:index';

// ── Low-level HTTP helpers ────────────────────────────────────────────────

/**
 * Return the VeriSimDB base URL from the worker env.
 * Falls back to localhost (useful for local dev / Miniflare).
 *
 * @param {object} env - Cloudflare Worker env bindings
 * @returns {string} base URL without trailing slash
 */
function baseUrl(env) {
  return (env.VERISIMDB_URL || 'http://localhost:8080').replace(/\/$/, '');
}

/**
 * PUT a single document into VeriSimDB.
 *
 * @param {object} env       - Worker env
 * @param {string} collection - Collection name (e.g. "clade:repos")
 * @param {string} id        - Document ID
 * @param {object} data      - Document body
 * @returns {Promise<boolean>} true on success
 */
async function vdbPut(env, collection, id, data) {
  const url = `${baseUrl(env)}${API_PREFIX}/${encodeURIComponent(collection)}/${encodeURIComponent(id)}`;
  try {
    const res = await fetch(url, {
      method: 'PUT',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(data),
    });
    if (!res.ok) {
      console.warn(`[verisimdb] PUT ${url} -> ${res.status}`);
      return false;
    }
    return true;
  } catch (err) {
    console.warn(`[verisimdb] PUT ${url} network error: ${err.message}`);
    return false;
  }
}

/**
 * GET a single document from VeriSimDB.
 *
 * @param {object} env        - Worker env
 * @param {string} collection - Collection name
 * @param {string} id         - Document ID
 * @returns {Promise<object|null>} document or null when not found / unreachable
 */
async function vdbGet(env, collection, id) {
  const url = `${baseUrl(env)}${API_PREFIX}/${encodeURIComponent(collection)}/${encodeURIComponent(id)}`;
  try {
    const res = await fetch(url);
    if (res.status === 404) return null;
    if (!res.ok) {
      console.warn(`[verisimdb] GET ${url} -> ${res.status}`);
      return null;
    }
    return await res.json();
  } catch (err) {
    console.warn(`[verisimdb] GET ${url} network error: ${err.message}`);
    return null;
  }
}

/**
 * List documents in a collection, optionally filtered by prefix.
 *
 * @param {object} env        - Worker env
 * @param {string} collection - Collection name
 * @param {string} [prefix]   - Optional ID prefix filter
 * @returns {Promise<object[]>} array of documents (empty on error)
 */
async function vdbList(env, collection, prefix = '') {
  const params = prefix ? `?prefix=${encodeURIComponent(prefix)}` : '';
  const url = `${baseUrl(env)}${API_PREFIX}/${encodeURIComponent(collection)}${params}`;
  try {
    const res = await fetch(url);
    if (!res.ok) {
      console.warn(`[verisimdb] LIST ${url} -> ${res.status}`);
      return [];
    }
    const body = await res.json();
    // VeriSimDB may return an array directly or { items: [...] }
    return Array.isArray(body) ? body : (body.items || []);
  } catch (err) {
    console.warn(`[verisimdb] LIST ${url} network error: ${err.message}`);
    return [];
  }
}

// ── Seed / sync functions ─────────────────────────────────────────────────

/**
 * Seed VeriSimDB from static JSON data files.
 *
 * Call this from a scheduled Cron trigger or from the sync scripts.
 * Each repo is stored as an individual document in clade:repos.
 * Each clade definition is stored in clade:clades.
 * A pre-built index snapshot is stored in clade:index.
 *
 * Mirrors writes to Cloudflare KV as well (dual-write).
 *
 * @param {object} env    - Worker env (must have CLADE_KV and VERISIMDB_URL)
 * @param {object[]} repos  - Array of repo objects (from repos.json)
 * @param {object[]} clades - Array of clade objects (from clades.json)
 * @returns {Promise<{seeded: number, errors: number}>}
 */
async function seedFromStaticJson(env, repos, clades) {
  let seeded = 0;
  let errors = 0;

  // Seed clade definitions
  for (const clade of clades) {
    const ok = await vdbPut(env, COL_CLADES, clade.code, clade);
    if (ok) seeded++;
    else errors++;
  }

  // Seed repo documents
  for (const repo of repos) {
    const ok = await vdbPut(env, COL_REPOS, repo.name, repo);
    if (ok) seeded++;
    else errors++;
  }

  // Build and store pre-computed index (mirrors what KV stores as "index")
  const byName = {};
  for (const repo of repos) {
    byName[repo.name] = repo;
  }

  const byClade = {};
  for (const repo of repos) {
    if (!byClade[repo.clade]) byClade[repo.clade] = [];
    byClade[repo.clade].push(repo.name);
  }

  const index = {
    total_repos: repos.length,
    total_clades: clades.length,
    generated: new Date().toISOString(),
    clades: clades.map(c => ({
      ...c,
      members: byClade[c.code] || [],
      member_count: (byClade[c.code] || []).length,
    })),
    by_name: byName,
  };

  const indexOk = await vdbPut(env, COL_INDEX, 'latest', index);
  if (indexOk) seeded++;
  else errors++;

  // Dual-write: also push index to Cloudflare KV (preserves existing behaviour)
  if (env.CLADE_KV) {
    try {
      await env.CLADE_KV.put('index', JSON.stringify(index));
    } catch (err) {
      console.warn(`[verisimdb] KV put failed: ${err.message}`);
      errors++;
    }
  }

  console.log(`[verisimdb] seedFromStaticJson: seeded=${seeded} errors=${errors}`);
  return { seeded, errors };
}

// ── Query functions ───────────────────────────────────────────────────────

/**
 * Query repos by primary language keyword.
 *
 * Searches the repo descriptions and tags in VeriSimDB. Falls back to the
 * KV index when VeriSimDB is unavailable.
 *
 * @param {object} env        - Worker env
 * @param {string} language   - Language name (case-insensitive, e.g. "rust")
 * @returns {Promise<object[]>} matching repos sorted by name
 */
async function queryByLanguage(env, language) {
  const q = language.toLowerCase();
  const docs = await vdbList(env, COL_REPOS);

  if (docs.length > 0) {
    return docs
      .filter(repo => {
        const searchable = `${repo.name} ${repo.description || ''}`.toLowerCase();
        return searchable.includes(q);
      })
      .sort((a, b) => (a.name || '').localeCompare(b.name || ''));
  }

  // VeriSimDB unavailable — fall back to KV index
  if (env.CLADE_KV) {
    const index = await env.CLADE_KV.get('index', { type: 'json' });
    if (index) {
      return Object.values(index.by_name || {})
        .filter(repo => {
          const searchable = `${repo.name} ${repo.description || ''}`.toLowerCase();
          return searchable.includes(q);
        })
        .sort((a, b) => (a.name || '').localeCompare(b.name || ''));
    }
  }

  return [];
}

/**
 * Query repos by tag / keyword.
 *
 * Searches names, descriptions, clade keywords, and secondary clade codes.
 *
 * @param {object} env    - Worker env
 * @param {string} tag    - Tag or keyword (case-insensitive)
 * @returns {Promise<object[]>} matching repos sorted by name
 */
async function queryByTag(env, tag) {
  const q = tag.toLowerCase();
  const docs = await vdbList(env, COL_REPOS);

  if (docs.length > 0) {
    return docs
      .filter(repo => {
        const secondaryStr = (repo.secondary || []).join(' ');
        const searchable = `${repo.name} ${repo.description || ''} ${repo.clade || ''} ${secondaryStr}`.toLowerCase();
        return searchable.includes(q);
      })
      .sort((a, b) => (a.name || '').localeCompare(b.name || ''));
  }

  // VeriSimDB unavailable — fall back to KV index
  if (env.CLADE_KV) {
    const index = await env.CLADE_KV.get('index', { type: 'json' });
    if (index) {
      // Also check clade keyword lists from clades array
      const cladeKeywords = {};
      for (const c of (index.clades || [])) {
        cladeKeywords[c.code] = (c.keywords || []);
      }

      return Object.values(index.by_name || {})
        .filter(repo => {
          const keywords = cladeKeywords[repo.clade] || [];
          const secondaryStr = (repo.secondary || []).join(' ');
          const searchable = [
            repo.name,
            repo.description || '',
            repo.clade || '',
            secondaryStr,
            ...keywords,
          ].join(' ').toLowerCase();
          return searchable.includes(q);
        })
        .sort((a, b) => (a.name || '').localeCompare(b.name || ''));
    }
  }

  return [];
}

/**
 * Load the clade index, preferring VeriSimDB over KV.
 *
 * Drop-in replacement for `loadIndex(env)` in index.js.
 *
 * @param {object} env - Worker env
 * @returns {Promise<object|null>} index document or null
 */
async function loadIndex(env) {
  // Try VeriSimDB first
  const vdbIndex = await vdbGet(env, COL_INDEX, 'latest');
  if (vdbIndex) return vdbIndex;

  // Fall back to KV
  if (env.CLADE_KV) {
    return await env.CLADE_KV.get('index', { type: 'json' });
  }

  return null;
}

export {
  vdbPut,
  vdbGet,
  vdbList,
  seedFromStaticJson,
  queryByLanguage,
  queryByTag,
  loadIndex,
};
