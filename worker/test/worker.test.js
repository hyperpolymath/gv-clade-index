// SPDX-License-Identifier: MPL-2.0
// Worker integration tests: drive the exported fetch() handler against a mocked
// Cloudflare KV seeded with the real committed snapshot (data/index.json).
// VeriSimDB is simulated as unreachable (global fetch throws) so the KV
// fallback path is exercised.

import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';

import worker from '../src/index.js';

const here = path.dirname(fileURLToPath(import.meta.url));
const INDEX = JSON.parse(readFileSync(path.join(here, '../data/index.json'), 'utf8'));

function makeKv(initial = {}) {
  const store = new Map(Object.entries(initial));
  return {
    store,
    get: async (key, opts) => {
      const v = store.get(key);
      if (v == null) return null;
      return opts && opts.type === 'json' ? JSON.parse(v) : v;
    },
    put: async (key, val) => {
      store.set(key, typeof val === 'string' ? val : JSON.stringify(val));
    },
  };
}

const envWithKv = () => ({ CLADE_KV: makeKv({ index: JSON.stringify(INDEX) }) });

async function call(pathAndQuery, { env = envWithKv(), method = 'GET' } = {}) {
  const req = new Request(`https://api.test${pathAndQuery}`, { method });
  const res = await worker.fetch(req, env);
  let body = null;
  try {
    body = await res.clone().json();
  } catch {
    // non-JSON / empty response — leave body null
  }
  return { res, body };
}

beforeEach(() => {
  // Simulate VeriSimDB unreachable → forces KV fallback.
  vi.stubGlobal(
    'fetch',
    vi.fn(async () => {
      throw new Error('verisimdb unreachable');
    }),
  );
});

afterEach(() => {
  vi.unstubAllGlobals();
});

describe('health & readiness', () => {
  it('GET /v1/health → 200 with security + request-id headers', async () => {
    const { res, body } = await call('/v1/health');
    expect(res.status).toBe(200);
    expect(body.status).toBe('ok');
    expect(res.headers.get('X-Content-Type-Options')).toBe('nosniff');
    expect(res.headers.get('Content-Security-Policy')).toContain("default-src 'none'");
    expect(res.headers.get('X-Request-Id')).toBeTruthy();
    expect(res.headers.get('Cache-Control')).toBe('no-store');
  });

  it('GET /v1/ready → 200 degraded when only KV is available', async () => {
    const { res, body } = await call('/v1/ready');
    expect(res.status).toBe(200);
    expect(body.status).toBe('degraded');
    expect(body.backing).toBe('kv');
  });

  it('GET /v1/ready → 503 unavailable when no backing store', async () => {
    const { res, body } = await call('/v1/ready', { env: {} });
    expect(res.status).toBe(503);
    expect(body.status).toBe('unavailable');
  });
});

describe('clades', () => {
  it('GET /v1/clades → all 12 clades', async () => {
    const { res, body } = await call('/v1/clades');
    expect(res.status).toBe(200);
    expect(body.clades).toHaveLength(INDEX.total_clades);
  });

  it('GET /v1/clade/fv → clade with member repos', async () => {
    const expected = INDEX.clades.find((c) => c.code === 'fv');
    const { res, body } = await call('/v1/clade/fv');
    expect(res.status).toBe(200);
    expect(body.code).toBe('fv');
    expect(body.repos).toHaveLength(expected.member_count);
  });

  it('GET /v1/clade/zz → 404 for unknown (but well-formed) code', async () => {
    const { res, body } = await call('/v1/clade/zz');
    expect(res.status).toBe(404);
    expect(body.error).toContain('not found');
  });
});

describe('repos', () => {
  it('GET /v1/repo/:name → repo detail with derived urls', async () => {
    const name = Object.keys(INDEX.by_name)[0];
    const { res, body } = await call(`/v1/repo/${encodeURIComponent(name)}`);
    expect(res.status).toBe(200);
    expect(body.name).toBe(name);
    expect(body.github_url).toContain('github.com/');
    expect(body.portal_url).toContain('/#/project/');
  });

  it('GET /v1/repo/:name → 404 for unknown repo', async () => {
    const { res } = await call('/v1/repo/this-repo-does-not-exist-xyz');
    expect(res.status).toBe(404);
  });

  it('GET /v1/repo/:name → 400 for malformed percent-encoding', async () => {
    const { res, body } = await call('/v1/repo/%E0%A4%A');
    expect(res.status).toBe(400);
    expect(body.error).toContain('Malformed');
  });

  it('GET /v1/repos → paginated with totals', async () => {
    const { res, body } = await call('/v1/repos');
    expect(res.status).toBe(200);
    expect(body.total).toBe(INDEX.total_repos);
    expect(body.page).toBe(1);
    expect(body.limit).toBe(50);
    expect(body.repos.length).toBeLessThanOrEqual(50);
  });

  it('GET /v1/repos?clade=fv → filtered to one clade', async () => {
    const { res, body } = await call('/v1/repos?clade=fv&limit=200');
    expect(res.status).toBe(200);
    expect(body.repos.every((r) => r.clade === 'fv')).toBe(true);
  });

  it('GET /v1/repos?clade=zz → 400 invalid clade', async () => {
    const { res } = await call('/v1/repos?clade=zz');
    expect(res.status).toBe(400);
  });

  it('GET /v1/repos clamps NaN/oversized pagination', async () => {
    const { res, body } = await call('/v1/repos?page=abc&limit=9999');
    expect(res.status).toBe(200);
    expect(body.page).toBe(1);
    expect(body.limit).toBe(200);
  });
});

describe('search & llm', () => {
  it('GET /v1/search without q → 400', async () => {
    const { res } = await call('/v1/search');
    expect(res.status).toBe(400);
  });

  it('GET /v1/search with overlong q → 400', async () => {
    const { res, body } = await call(`/v1/search?q=${'a'.repeat(300)}`);
    expect(res.status).toBe(400);
    expect(body.error).toContain('too long');
  });

  it('GET /v1/search?q=<known name> → ranked results', async () => {
    const name = Object.keys(INDEX.by_name)[0];
    const { res, body } = await call(`/v1/search?q=${encodeURIComponent(name)}`);
    expect(res.status).toBe(200);
    expect(body.total).toBeGreaterThanOrEqual(1);
    expect(typeof body.results[0].score).toBe('number');
  });

  it('GET /v1/llm?q=... → structured output capped at 10', async () => {
    const { res, body } = await call('/v1/llm?q=proof');
    expect(res.status).toBe(200);
    expect(body.ecosystem).toBe('hyperpolymath');
    expect(body.results.length).toBeLessThanOrEqual(10);
  });
});

describe('verisimdb-backed queries (KV fallback)', () => {
  it('GET /v1/query/language?q=rust → 200 array', async () => {
    const { res, body } = await call('/v1/query/language?q=rust');
    expect(res.status).toBe(200);
    expect(Array.isArray(body.results)).toBe(true);
  });

  it('GET /v1/query/tag?q=security → 200 array', async () => {
    const { res, body } = await call('/v1/query/tag?q=security');
    expect(res.status).toBe(200);
    expect(Array.isArray(body.results)).toBe(true);
  });
});

describe('method & routing', () => {
  it('POST → 405', async () => {
    const { res } = await call('/v1/clades', { method: 'POST' });
    expect(res.status).toBe(405);
  });

  it('OPTIONS → CORS preflight headers', async () => {
    const { res } = await call('/v1/clades', { method: 'OPTIONS' });
    expect(res.headers.get('Access-Control-Allow-Methods')).toContain('GET');
  });

  it('unknown path → 404', async () => {
    const { res } = await call('/nope');
    expect(res.status).toBe(404);
  });

  it('503 when registry data is absent', async () => {
    const { res } = await call('/v1/dashboard', { env: { CLADE_KV: makeKv({}) } });
    expect(res.status).toBe(503);
  });
});

describe('error handling', () => {
  it('unexpected throw → controlled 500 (not a crash)', async () => {
    const env = {
      CLADE_KV: {
        get: async () => {
          throw new Error('kv boom');
        },
      },
    };
    const { res, body } = await call('/v1/dashboard', { env });
    expect(res.status).toBe(500);
    expect(body.error).toBe('Internal error');
    expect(res.headers.get('X-Request-Id')).toBeTruthy();
  });
});

describe('fuzz: no uncontrolled 5xx', () => {
  const methods = ['GET', 'POST', 'HEAD', 'OPTIONS'];
  const segs = [
    'v1',
    'repo',
    'clade',
    'repos',
    'search',
    'llm',
    'query',
    'language',
    'tag',
    'x',
    '',
  ];
  const rnd = (a) => a[Math.floor(Math.random() * a.length)];

  it('200 random requests never return 500', async () => {
    const env = envWithKv();
    for (let i = 0; i < 200; i++) {
      const depth = 1 + Math.floor(Math.random() * 4);
      const p = '/' + Array.from({ length: depth }, () => encodeURIComponent(rnd(segs))).join('/');
      const q =
        Math.random() < 0.5
          ? `?q=${encodeURIComponent('x'.repeat(Math.floor(Math.random() * 400)))}`
          : '';
      const req = new Request(`https://api.test${p}${q}`, { method: rnd(methods) });
      const res = await worker.fetch(req, env);
      expect(res.status).toBeLessThan(500);
    }
  });
});
