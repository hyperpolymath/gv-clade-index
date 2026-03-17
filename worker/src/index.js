// SPDX-License-Identifier: PMPL-1.0-or-later
// Cloudflare Worker: clade-registry-api
// Serves the hyperpolymath clade registry as a read-only API
//
// Endpoints:
//   GET /v1/clades              — List all 12 clades with stats
//   GET /v1/clade/:code         — Single clade with member repos
//   GET /v1/repo/:name          — Single repo detail
//   GET /v1/repos               — All repos (paginated)
//   GET /v1/search?q=...        — Full-text search across repos
//   GET /v1/llm?q=...           — Structured output for LLM consumption
//   GET /v1/dashboard           — Ecosystem overview
//   GET /v1/health              — Health check

const CORS_HEADERS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'GET, OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type, Authorization',
  'Access-Control-Max-Age': '86400',
};

function json(data, status = 200) {
  return new Response(JSON.stringify(data, null, 2), {
    status,
    headers: {
      'Content-Type': 'application/json; charset=utf-8',
      'Cache-Control': 'public, max-age=300',
      ...CORS_HEADERS,
    },
  });
}

function error(message, status = 404) {
  return json({ error: message }, status);
}

// Load index data from KV (cached in-memory per request)
async function loadIndex(env) {
  const cached = await env.CLADE_KV.get('index', { type: 'json' });
  if (!cached) {
    return null;
  }
  return cached;
}

// Search repos by query string (simple text matching across name + description)
function searchRepos(index, query) {
  const q = query.toLowerCase();
  const terms = q.split(/\s+/).filter(t => t.length > 0);

  const results = [];
  for (const [name, repo] of Object.entries(index.by_name)) {
    const searchable = `${name} ${repo.description} ${repo.clade}`.toLowerCase();
    const score = terms.reduce((acc, term) => {
      if (searchable.includes(term)) return acc + 1;
      return acc;
    }, 0);
    if (score > 0) {
      results.push({ ...repo, score });
    }
  }

  results.sort((a, b) => b.score - a.score);
  return results;
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const path = url.pathname;

    // Handle CORS preflight
    if (request.method === 'OPTIONS') {
      return new Response(null, { headers: CORS_HEADERS });
    }

    // Only allow GET
    if (request.method !== 'GET') {
      return error('Method not allowed', 405);
    }

    // Health check (no KV needed)
    if (path === '/v1/health' || path === '/health') {
      return json({
        status: 'ok',
        service: 'clade-registry-api',
        version: '0.1.0',
        timestamp: new Date().toISOString(),
      });
    }

    // Load index
    const index = await loadIndex(env);
    if (!index) {
      return error('Registry data not loaded — run sync', 503);
    }

    // Route: GET /v1/dashboard
    if (path === '/v1/dashboard') {
      const cladesSummary = index.clades.map(c => ({
        code: c.code,
        name: c.name,
        colour: c.colour,
        member_count: c.member_count,
      }));
      return json({
        total_repos: index.total_repos,
        total_clades: index.total_clades,
        generated: index.generated,
        clades: cladesSummary,
      });
    }

    // Route: GET /v1/clades
    if (path === '/v1/clades') {
      return json({
        clades: index.clades.map(c => ({
          code: c.code,
          name: c.name,
          description: c.description,
          colour: c.colour,
          icon: c.icon,
          member_count: c.member_count,
          keywords: c.keywords,
        })),
      });
    }

    // Route: GET /v1/clade/:code
    const cladeMatch = path.match(/^\/v1\/clade\/([a-z]{2})$/);
    if (cladeMatch) {
      const code = cladeMatch[1];
      const clade = index.clades.find(c => c.code === code);
      if (!clade) {
        return error(`Clade '${code}' not found. Valid codes: ${index.clades.map(c => c.code).join(', ')}`);
      }
      const members = clade.members.map(name => index.by_name[name]).filter(Boolean);
      return json({
        ...clade,
        repos: members,
      });
    }

    // Route: GET /v1/repo/:name
    const repoMatch = path.match(/^\/v1\/repo\/(.+)$/);
    if (repoMatch) {
      const name = decodeURIComponent(repoMatch[1]);
      const repo = index.by_name[name];
      if (!repo) {
        return error(`Repo '${name}' not found`);
      }
      // Find the clade info
      const clade = index.clades.find(c => c.code === repo.clade);
      return json({
        ...repo,
        clade_name: clade ? clade.name : repo.clade,
        clade_colour: clade ? clade.colour : null,
        github_url: `https://github.com/${repo.github}`,
        portal_url: `https://hyperpolymath.github.io/#/project/${name}`,
      });
    }

    // Route: GET /v1/repos?clade=xx&page=1&limit=50
    if (path === '/v1/repos') {
      const cladeFilter = url.searchParams.get('clade');
      const page = parseInt(url.searchParams.get('page') || '1', 10);
      const limit = Math.min(parseInt(url.searchParams.get('limit') || '50', 10), 200);
      const offset = (page - 1) * limit;

      let repos = Object.values(index.by_name);
      if (cladeFilter) {
        repos = repos.filter(r => r.clade === cladeFilter);
      }
      repos.sort((a, b) => a.name.localeCompare(b.name));

      const total = repos.length;
      const paginated = repos.slice(offset, offset + limit);

      return json({
        repos: paginated,
        total,
        page,
        limit,
        pages: Math.ceil(total / limit),
      });
    }

    // Route: GET /v1/search?q=...
    if (path === '/v1/search') {
      const query = url.searchParams.get('q');
      if (!query || query.trim().length === 0) {
        return error('Query parameter q is required', 400);
      }
      const results = searchRepos(index, query);
      const limit = Math.min(parseInt(url.searchParams.get('limit') || '20', 10), 100);

      return json({
        query,
        results: results.slice(0, limit),
        total: results.length,
      });
    }

    // Route: GET /v1/llm?q=...
    // Structured output optimised for LLM consumption
    if (path === '/v1/llm') {
      const query = url.searchParams.get('q');
      if (!query || query.trim().length === 0) {
        return error('Query parameter q is required', 400);
      }

      // Check for API key in Authorization header (optional for now)
      // const apiKey = request.headers.get('Authorization');

      const results = searchRepos(index, query);
      const top = results.slice(0, 10);

      // Build relationship hints from clade membership
      const relationships = [];
      const clades = new Set(top.map(r => r.clade));
      if (clades.size > 1) {
        for (const c of clades) {
          const inClade = top.filter(r => r.clade === c);
          if (inClade.length > 1) {
            relationships.push({
              type: 'same-clade',
              clade: c,
              repos: inClade.map(r => r.name),
            });
          }
        }
      }

      return json({
        query,
        ecosystem: 'hyperpolymath',
        registry: 'gv-clade-index',
        results: top.map(r => ({
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
      });
    }

    // Root — API documentation
    if (path === '/' || path === '/v1') {
      return json({
        name: 'Hyperpolymath Clade Registry API',
        version: '0.1.0',
        description: 'Read-only API for the hyperpolymath ecosystem registry. Map and territory — this is the map.',
        endpoints: {
          '/v1/dashboard': 'Ecosystem overview with clade stats',
          '/v1/clades': 'List all 12 clades',
          '/v1/clade/:code': 'Single clade with member repos (e.g. /v1/clade/fv)',
          '/v1/repo/:name': 'Single repo detail (e.g. /v1/repo/januskey)',
          '/v1/repos': 'All repos (params: clade, page, limit)',
          '/v1/search?q=...': 'Full-text search across repos',
          '/v1/llm?q=...': 'Structured output for LLM consumption',
          '/v1/health': 'Health check',
        },
        total_repos: index ? index.total_repos : 'loading',
        total_clades: index ? index.total_clades : 'loading',
        source: 'https://github.com/hyperpolymath/gv-clade-index',
      });
    }

    return error('Not found. Try /v1 for API documentation.');
  },
};
