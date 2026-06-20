// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell
//
// Cloudflare Worker: clade-registry-api
// Read-only API serving the hyperpolymath clade registry.
//
// Endpoints:
//   GET /v1/clades              — List all 12 clades with stats
//   GET /v1/clade/:code         — Single clade with member repos
//   GET /v1/repo/:name          — Single repo detail
//   GET /v1/repos               — All repos (paginated)
//   GET /v1/search?q=...        — Full-text search across repos
//   GET /v1/llm?q=...           — Structured output for LLM consumption
//   GET /v1/dashboard           — Ecosystem overview
//   GET /v1/health              — Liveness check (no backing store)
//   GET /v1/ready               — Readiness check (probes VeriSimDB; "degraded" on KV fallback)
//   GET /v1/query/language?q=.. — Query repos by language (VeriSimDB-backed)
//   GET /v1/query/tag?q=...     — Query repos by tag (VeriSimDB-backed)
//
// Storage: dual-store — Cloudflare KV (cache) + VeriSimDB (persistent).
// loadIndex() prefers VeriSimDB and falls back to KV.

import { loadIndex, queryByLanguage, queryByTag, refreshFromSource, ping } from './verisim.js';
import { json, error, makeRequestId, CORS_HEADERS, SECURITY_HEADERS } from './http.js';
import { isValidClade, VALID_CLADES, positiveInt, safeDecode, boundedQuery } from './validate.js';
import { allow } from './ratelimit.js';
import { createLogger } from './log.js';

const VERSION = '0.1.0';

const ENDPOINT_DOCS = {
  '/v1/dashboard': 'Ecosystem overview with clade stats',
  '/v1/clades': 'List all 12 clades',
  '/v1/clade/:code': 'Single clade with member repos (e.g. /v1/clade/fv)',
  '/v1/repo/:name': 'Single repo detail (e.g. /v1/repo/januskey)',
  '/v1/repos': 'All repos (params: clade, page, limit)',
  '/v1/search?q=...': 'Full-text search across repos',
  '/v1/llm?q=...': 'Structured output for LLM consumption',
  '/v1/query/language?q=...': 'Query repos by language keyword (VeriSimDB)',
  '/v1/query/tag?q=...': 'Query repos by tag (VeriSimDB)',
  '/v1/health': 'Liveness check',
  '/v1/ready': 'Readiness check (backing-store health)',
};

// Simple text search across name + description + clade.
function searchRepos(index, query) {
  const terms = query
    .toLowerCase()
    .split(/\s+/)
    .filter((t) => t.length > 0);

  const results = [];
  for (const [name, repo] of Object.entries(index.by_name)) {
    const searchable = `${name} ${repo.description || ''} ${repo.clade || ''}`.toLowerCase();
    const score = terms.reduce((acc, term) => (searchable.includes(term) ? acc + 1 : acc), 0);
    if (score > 0) results.push({ ...repo, score });
  }
  results.sort((a, b) => b.score - a.score);
  return results;
}

// Per-route handling. Throwing here is caught by fetch() and turned into a 500.
async function route(request, env, log, requestId) {
  const url = new URL(request.url);
  const path = url.pathname;
  const clientIp = request.headers.get('CF-Connecting-IP') || 'anon';

  // CORS preflight
  if (request.method === 'OPTIONS') {
    return new Response(null, { headers: { ...CORS_HEADERS, ...SECURITY_HEADERS } });
  }

  // Read-only API
  if (request.method !== 'GET') {
    return error('Method not allowed', { status: 405, requestId });
  }

  // Liveness — never touches a backing store.
  if (path === '/v1/health' || path === '/health') {
    return json(
      {
        status: 'ok',
        service: 'clade-registry-api',
        version: VERSION,
        timestamp: new Date().toISOString(),
      },
      { requestId, maxAge: 0 },
    );
  }

  // Readiness — probe backing stores; "degraded" when serving from KV fallback.
  if (path === '/v1/ready' || path === '/ready') {
    const probe = await ping(env, log);
    const ready = probe.verisimdb || probe.kv;
    return json(
      {
        status: ready ? (probe.verisimdb ? 'ready' : 'degraded') : 'unavailable',
        backing: probe.verisimdb ? 'verisimdb' : probe.kv ? 'kv' : 'none',
        verisimdb: probe.verisimdb,
        kv: probe.kv,
        timestamp: new Date().toISOString(),
      },
      { status: ready ? 200 : 503, requestId, maxAge: 0 },
    );
  }

  // Load index (VeriSimDB → KV fallback)
  const index = await loadIndex(env, log);
  if (!index) {
    return error('Registry data not loaded — run sync', { status: 503, requestId });
  }

  // GET /v1/dashboard
  if (path === '/v1/dashboard') {
    return json(
      {
        total_repos: index.total_repos,
        total_clades: index.total_clades,
        generated: index.generated,
        clades: index.clades.map((c) => ({
          code: c.code,
          name: c.name,
          colour: c.colour,
          member_count: c.member_count,
        })),
      },
      { requestId },
    );
  }

  // GET /v1/clades
  if (path === '/v1/clades') {
    return json(
      {
        clades: index.clades.map((c) => ({
          code: c.code,
          name: c.name,
          description: c.description,
          colour: c.colour,
          icon: c.icon,
          member_count: c.member_count,
          keywords: c.keywords,
        })),
      },
      { requestId },
    );
  }

  // GET /v1/clade/:code
  const cladeMatch = path.match(/^\/v1\/clade\/([a-z]{2})$/);
  if (cladeMatch) {
    const code = cladeMatch[1];
    if (!isValidClade(code)) {
      return error(`Clade '${code}' not found. Valid codes: ${VALID_CLADES.join(', ')}`, {
        requestId,
      });
    }
    const clade = index.clades.find((c) => c.code === code);
    if (!clade) return error(`Clade '${code}' not found`, { requestId });
    const members = clade.members.map((name) => index.by_name[name]).filter(Boolean);
    return json({ ...clade, repos: members }, { requestId });
  }

  // GET /v1/repo/:name
  const repoMatch = path.match(/^\/v1\/repo\/(.+)$/);
  if (repoMatch) {
    const name = safeDecode(repoMatch[1]);
    if (name === null) return error('Malformed repo name', { status: 400, requestId });
    const repo = index.by_name[name];
    if (!repo) return error(`Repo '${name}' not found`, { requestId });
    const clade = index.clades.find((c) => c.code === repo.clade);
    return json(
      {
        ...repo,
        clade_name: clade ? clade.name : repo.clade,
        clade_colour: clade ? clade.colour : null,
        github_url: `https://github.com/${repo.github}`,
        portal_url: `https://hyperpolymath.github.io/#/project/${name}`,
      },
      { requestId },
    );
  }

  // GET /v1/repos?clade=xx&page=1&limit=50
  if (path === '/v1/repos') {
    const cladeFilter = url.searchParams.get('clade');
    if (cladeFilter && !isValidClade(cladeFilter)) {
      return error(`Invalid clade '${cladeFilter}'. Valid codes: ${VALID_CLADES.join(', ')}`, {
        status: 400,
        requestId,
      });
    }
    const page = positiveInt(url.searchParams.get('page'), 1);
    const limit = positiveInt(url.searchParams.get('limit'), 50, 200);
    const offset = (page - 1) * limit;

    let repos = Object.values(index.by_name);
    if (cladeFilter) repos = repos.filter((r) => r.clade === cladeFilter);
    repos.sort((a, b) => a.name.localeCompare(b.name));

    const total = repos.length;
    return json(
      {
        repos: repos.slice(offset, offset + limit),
        total,
        page,
        limit,
        pages: Math.ceil(total / limit),
      },
      { requestId },
    );
  }

  // GET /v1/search?q=...
  if (path === '/v1/search') {
    const q = boundedQuery(url.searchParams.get('q'));
    if (!q.ok) return error(q.reason, { status: 400, requestId });
    if (!(await allow(env, `search:${clientIp}`))) {
      return error('Rate limit exceeded', { status: 429, requestId });
    }
    const results = searchRepos(index, q.value);
    const limit = positiveInt(url.searchParams.get('limit'), 20, 100);
    return json(
      { query: q.value, results: results.slice(0, limit), total: results.length },
      { requestId },
    );
  }

  // GET /v1/llm?q=...  — structured output optimised for LLM consumption
  if (path === '/v1/llm') {
    const q = boundedQuery(url.searchParams.get('q'));
    if (!q.ok) return error(q.reason, { status: 400, requestId });
    if (!(await allow(env, `llm:${clientIp}`))) {
      return error('Rate limit exceeded', { status: 429, requestId });
    }
    const results = searchRepos(index, q.value);
    const top = results.slice(0, 10);

    const relationships = [];
    const clades = new Set(top.map((r) => r.clade));
    if (clades.size > 1) {
      for (const c of clades) {
        const inClade = top.filter((r) => r.clade === c);
        if (inClade.length > 1) {
          relationships.push({ type: 'same-clade', clade: c, repos: inClade.map((r) => r.name) });
        }
      }
    }

    return json(
      {
        query: q.value,
        ecosystem: 'hyperpolymath',
        registry: 'gv-clade-index',
        results: top.map((r) => ({
          repo: r.prefixed,
          canonical_name: r.name,
          summary: r.description,
          clade: r.clade,
          lineage: r.lineage,
          github_url: `https://github.com/${r.github}`,
          portal_url: `https://hyperpolymath.github.io/#/project/${r.name}`,
        })),
        relationships,
        total_matches: results.length,
      },
      { requestId },
    );
  }

  // Root — API documentation
  if (path === '/' || path === '/v1') {
    return json(
      {
        name: 'Hyperpolymath Clade Registry API',
        version: VERSION,
        description:
          'Read-only API for the hyperpolymath ecosystem registry. Map and territory — this is the map.',
        endpoints: ENDPOINT_DOCS,
        total_repos: index.total_repos,
        total_clades: index.total_clades,
        source: 'https://github.com/hyperpolymath/gv-clade-index',
      },
      { requestId },
    );
  }

  // GET /v1/query/language?q=rust
  if (path === '/v1/query/language') {
    const q = boundedQuery(url.searchParams.get('q'));
    if (!q.ok) return error(q.reason, { status: 400, requestId });
    if (!(await allow(env, `query:${clientIp}`))) {
      return error('Rate limit exceeded', { status: 429, requestId });
    }
    const results = await queryByLanguage(env, q.value, log);
    return json(
      { query: q.value, type: 'language', results, total: results.length, source: 'verisimdb' },
      { requestId },
    );
  }

  // GET /v1/query/tag?q=security
  if (path === '/v1/query/tag') {
    const q = boundedQuery(url.searchParams.get('q'));
    if (!q.ok) return error(q.reason, { status: 400, requestId });
    if (!(await allow(env, `query:${clientIp}`))) {
      return error('Rate limit exceeded', { status: 429, requestId });
    }
    const results = await queryByTag(env, q.value, log);
    return json(
      { query: q.value, type: 'tag', results, total: results.length, source: 'verisimdb' },
      { requestId },
    );
  }

  return error('Not found. Try /v1 for API documentation.', { requestId });
}

export default {
  async fetch(request, env) {
    const requestId = makeRequestId();
    const log = createLogger({ reqId: requestId });
    const start = Date.now();
    const url = new URL(request.url);
    try {
      const res = await route(request, env, log, requestId);
      log.info('request', {
        method: request.method,
        path: url.pathname,
        status: res.status,
        ms: Date.now() - start,
      });
      return res;
    } catch (err) {
      log.error('unhandled', {
        method: request.method,
        path: url.pathname,
        error: err && err.message,
        stack: err && err.stack,
      });
      return error('Internal error', { status: 500, requestId });
    }
  },

  // Cron trigger — refresh the snapshot into both stores. Configured via
  // wrangler.toml [triggers] crons and env.DATA_SOURCE_URL.
  async scheduled(event, env) {
    const log = createLogger({ reqId: `cron_${event.scheduledTime || Date.now()}` });
    log.info('scheduled.start', { cron: event.cron });
    try {
      const result = await refreshFromSource(env, log);
      log.info('scheduled.done', result);
    } catch (err) {
      log.error('scheduled.error', { error: err && err.message });
    }
  },
};
