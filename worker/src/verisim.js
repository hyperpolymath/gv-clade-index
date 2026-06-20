// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell
//
// VeriSimDB client for gv-clade-index Cloudflare Worker.
//
// Collection namespaces used:
//   clade:repos   — all 202+ hyperpolymath repos with clade metadata
//   clade:clades  — 12 clade definitions
//   clade:index   — pre-built search index (by_name + clades maps)
//
// Dual-store pattern: reads prefer VeriSimDB when VERISIMDB_URL is present in
// the worker env; fall back to Cloudflare KV when VeriSimDB is unreachable.
//
// Configuration (wrangler.toml [vars] / secrets):
//   VERISIMDB_URL    — Base URL for VeriSimDB (default: http://localhost:8080)
//   DATA_SOURCE_URL  — Base URL for the canonical JSON snapshot used by the
//                      scheduled refresh (e.g. the raw worker/data/ directory)
//
// Exposed:
//   loadIndex(env, log)                 -> index | null
//   queryByLanguage(env, language, log) -> [repo, ...]
//   queryByTag(env, tag, log)           -> [repo, ...]
//   seedFromStaticJson(env, repos, clades, log) -> { seeded, errors }
//   refreshFromSource(env, log)         -> { seeded, errors } | { skipped }
//   ping(env, log)                      -> { verisimdb: bool, kv: bool }

import { log as moduleLog } from './log.js';

const API_PREFIX = '/api/v1';
const COL_REPOS = 'clade:repos';
const COL_CLADES = 'clade:clades';
const COL_INDEX = 'clade:index';

// ── Low-level HTTP helpers ────────────────────────────────────────────────

/**
 * Return the VeriSimDB base URL from the worker env (no trailing slash).
 * Falls back to localhost for local dev / Miniflare.
 *
 * @param {object} env
 * @returns {string}
 */
function baseUrl(env) {
  return (env.VERISIMDB_URL || 'http://localhost:8080').replace(/\/$/, '');
}

/**
 * PUT a single document into VeriSimDB.
 *
 * @param {object} env
 * @param {string} collection
 * @param {string} id
 * @param {object} data
 * @param {object} [log]
 * @returns {Promise<boolean>} true on success
 */
async function vdbPut(env, collection, id, data, log = moduleLog) {
  const url = `${baseUrl(env)}${API_PREFIX}/${encodeURIComponent(collection)}/${encodeURIComponent(id)}`;
  try {
    const res = await fetch(url, {
      method: 'PUT',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(data),
    });
    if (!res.ok) {
      log.warn('verisimdb.put.status', { url, status: res.status });
      return false;
    }
    return true;
  } catch (err) {
    log.warn('verisimdb.put.error', { url, error: err.message });
    return false;
  }
}

/**
 * GET a single document from VeriSimDB.
 *
 * @param {object} env
 * @param {string} collection
 * @param {string} id
 * @param {object} [log]
 * @returns {Promise<object|null>} document, or null when not found / unreachable
 */
async function vdbGet(env, collection, id, log = moduleLog) {
  const url = `${baseUrl(env)}${API_PREFIX}/${encodeURIComponent(collection)}/${encodeURIComponent(id)}`;
  try {
    const res = await fetch(url);
    if (res.status === 404) return null;
    if (!res.ok) {
      log.warn('verisimdb.get.status', { url, status: res.status });
      return null;
    }
    return await res.json();
  } catch (err) {
    log.warn('verisimdb.get.error', { url, error: err.message });
    return null;
  }
}

/**
 * List documents in a collection, optionally filtered by id prefix.
 *
 * @param {object} env
 * @param {string} collection
 * @param {string} [prefix]
 * @param {object} [log]
 * @returns {Promise<object[]>} documents (empty on error)
 */
async function vdbList(env, collection, prefix = '', log = moduleLog) {
  const params = prefix ? `?prefix=${encodeURIComponent(prefix)}` : '';
  const url = `${baseUrl(env)}${API_PREFIX}/${encodeURIComponent(collection)}${params}`;
  try {
    const res = await fetch(url);
    if (!res.ok) {
      log.warn('verisimdb.list.status', { url, status: res.status });
      return [];
    }
    const body = await res.json();
    // VeriSimDB may return an array directly or { items: [...] }.
    return Array.isArray(body) ? body : body.items || [];
  } catch (err) {
    log.warn('verisimdb.list.error', { url, error: err.message });
    return [];
  }
}

// ── Seed / sync functions ─────────────────────────────────────────────────

/**
 * Build the pre-computed index document from repos + clades arrays.
 *
 * @param {object[]} repos
 * @param {object[]} clades
 * @returns {object}
 */
function buildIndex(repos, clades) {
  const byName = {};
  const byClade = {};
  for (const repo of repos) {
    byName[repo.name] = repo;
    if (!byClade[repo.clade]) byClade[repo.clade] = [];
    byClade[repo.clade].push(repo.name);
  }
  return {
    total_repos: repos.length,
    total_clades: clades.length,
    generated: new Date().toISOString(),
    clades: clades.map((c) => ({
      ...c,
      members: byClade[c.code] || [],
      member_count: (byClade[c.code] || []).length,
    })),
    by_name: byName,
  };
}

/**
 * Seed VeriSimDB from static JSON data, mirroring the index to Cloudflare KV.
 *
 * @param {object} env
 * @param {object[]} repos
 * @param {object[]} clades
 * @param {object} [log]
 * @returns {Promise<{seeded:number, errors:number}>}
 */
async function seedFromStaticJson(env, repos, clades, log = moduleLog) {
  let seeded = 0;
  let errors = 0;

  for (const clade of clades) {
    (await vdbPut(env, COL_CLADES, clade.code, clade, log)) ? seeded++ : errors++;
  }
  for (const repo of repos) {
    (await vdbPut(env, COL_REPOS, repo.name, repo, log)) ? seeded++ : errors++;
  }

  const index = buildIndex(repos, clades);
  (await vdbPut(env, COL_INDEX, 'latest', index, log)) ? seeded++ : errors++;

  // Dual-write: also push the index to Cloudflare KV.
  if (env.CLADE_KV) {
    try {
      await env.CLADE_KV.put('index', JSON.stringify(index));
    } catch (err) {
      log.warn('kv.put.error', { error: err.message });
      errors++;
    }
  }

  log.info('seed.done', { seeded, errors });
  return { seeded, errors };
}

/**
 * Scheduled refresh: fetch the canonical JSON snapshot and re-seed both stores.
 * No-ops (returns { skipped:true }) when DATA_SOURCE_URL is not configured.
 *
 * @param {object} env
 * @param {object} [log]
 * @returns {Promise<{seeded:number,errors:number}|{skipped:true,reason?:string}>}
 */
async function refreshFromSource(env, log = moduleLog) {
  const base = (env.DATA_SOURCE_URL || '').replace(/\/$/, '');
  if (!base) {
    log.warn('refresh.skip', { reason: 'DATA_SOURCE_URL not set' });
    return { skipped: true, reason: 'DATA_SOURCE_URL not set' };
  }
  try {
    const [reposRes, cladesRes] = await Promise.all([
      fetch(`${base}/repos.json`),
      fetch(`${base}/clades.json`),
    ]);
    if (!reposRes.ok || !cladesRes.ok) {
      log.error('refresh.fetch_failed', { repos: reposRes.status, clades: cladesRes.status });
      return { skipped: true, reason: 'fetch failed' };
    }
    const repos = await reposRes.json();
    const clades = await cladesRes.json();
    return await seedFromStaticJson(env, repos, clades, log);
  } catch (err) {
    log.error('refresh.error', { error: err.message });
    return { skipped: true, reason: err.message };
  }
}

// ── Query functions ───────────────────────────────────────────────────────

/**
 * Query repos by language keyword (name + description). VeriSimDB first,
 * KV index fallback.
 *
 * @param {object} env
 * @param {string} language
 * @param {object} [log]
 * @returns {Promise<object[]>}
 */
async function queryByLanguage(env, language, log = moduleLog) {
  const q = language.toLowerCase();
  const match = (repo) => `${repo.name} ${repo.description || ''}`.toLowerCase().includes(q);
  const byName = (a, b) => (a.name || '').localeCompare(b.name || '');

  const docs = await vdbList(env, COL_REPOS, '', log);
  if (docs.length > 0) return docs.filter(match).sort(byName);

  if (env.CLADE_KV) {
    const index = await env.CLADE_KV.get('index', { type: 'json' });
    if (index)
      return Object.values(index.by_name || {})
        .filter(match)
        .sort(byName);
  }
  return [];
}

/**
 * Query repos by tag / keyword (name, description, clade, secondary, clade keywords).
 * VeriSimDB first, KV index fallback.
 *
 * @param {object} env
 * @param {string} tag
 * @param {object} [log]
 * @returns {Promise<object[]>}
 */
async function queryByTag(env, tag, log = moduleLog) {
  const q = tag.toLowerCase();
  const byName = (a, b) => (a.name || '').localeCompare(b.name || '');

  const docs = await vdbList(env, COL_REPOS, '', log);
  if (docs.length > 0) {
    return docs
      .filter((repo) => {
        const secondaryStr = (repo.secondary || []).join(' ');
        return `${repo.name} ${repo.description || ''} ${repo.clade || ''} ${secondaryStr}`
          .toLowerCase()
          .includes(q);
      })
      .sort(byName);
  }

  if (env.CLADE_KV) {
    const index = await env.CLADE_KV.get('index', { type: 'json' });
    if (index) {
      const cladeKeywords = {};
      for (const c of index.clades || []) cladeKeywords[c.code] = c.keywords || [];
      return Object.values(index.by_name || {})
        .filter((repo) => {
          const keywords = cladeKeywords[repo.clade] || [];
          const secondaryStr = (repo.secondary || []).join(' ');
          return [repo.name, repo.description || '', repo.clade || '', secondaryStr, ...keywords]
            .join(' ')
            .toLowerCase()
            .includes(q);
        })
        .sort(byName);
    }
  }
  return [];
}

/**
 * Load the clade index, preferring VeriSimDB over KV.
 *
 * @param {object} env
 * @param {object} [log]
 * @returns {Promise<object|null>}
 */
async function loadIndex(env, log = moduleLog) {
  const vdbIndex = await vdbGet(env, COL_INDEX, 'latest', log);
  if (vdbIndex) return vdbIndex;
  if (env.CLADE_KV) return await env.CLADE_KV.get('index', { type: 'json' });
  return null;
}

/**
 * Probe backing stores for readiness reporting.
 *
 * @param {object} env
 * @param {object} [log]
 * @returns {Promise<{verisimdb:boolean, kv:boolean}>}
 */
async function ping(env, log = moduleLog) {
  const vdb = await vdbGet(env, COL_INDEX, 'latest', log);
  let kv = false;
  if (env.CLADE_KV) {
    try {
      kv = (await env.CLADE_KV.get('index')) != null;
    } catch (err) {
      log.warn('kv.ping.error', { error: err.message });
    }
  }
  return { verisimdb: vdb != null, kv };
}

export {
  vdbPut,
  vdbGet,
  vdbList,
  buildIndex,
  seedFromStaticJson,
  refreshFromSource,
  queryByLanguage,
  queryByTag,
  loadIndex,
  ping,
};
