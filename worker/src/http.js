// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell
//
// HTTP response helpers: CORS, security headers, JSON envelopes, request ids.

// Default browser origin allowed to read responses cross-origin (the portal).
// Override with the CORS_ALLOW_ORIGIN env var (comma-separated allowlist of
// explicit origins). CORS only constrains browser JS; non-browser clients
// (curl, servers, LLM agents) are unaffected.
export const DEFAULT_ALLOWED_ORIGIN = 'https://hyperpolymath.github.io';

// Hardening headers applied to every response. This is a JSON API that serves
// no HTML, so the CSP is maximally restrictive.
export const SECURITY_HEADERS = {
  'X-Content-Type-Options': 'nosniff',
  'X-Frame-Options': 'DENY',
  'Referrer-Policy': 'no-referrer',
  'Content-Security-Policy': "default-src 'none'; frame-ancestors 'none'",
  'Strict-Transport-Security': 'max-age=31536000; includeSubDomains',
};

/**
 * Resolve CORS headers for a request against the configured origin allowlist.
 * Echoes the request Origin only when it is explicitly allowed; otherwise uses
 * the first configured origin. Never emits a hardcoded wildcard.
 *
 * @param {object} env - Worker env bindings
 * @param {Request} [request]
 * @returns {Record<string,string>}
 */
export function corsHeaders(env, request) {
  const configured = (env && env.CORS_ALLOW_ORIGIN) || DEFAULT_ALLOWED_ORIGIN;
  const allowList = configured
    .split(',')
    .map((s) => s.trim())
    .filter(Boolean);
  const reqOrigin = request && request.headers ? request.headers.get('Origin') : null;
  const origin = reqOrigin && allowList.includes(reqOrigin) ? reqOrigin : allowList[0];
  return {
    'Access-Control-Allow-Origin': origin,
    'Access-Control-Allow-Methods': 'GET, OPTIONS',
    'Access-Control-Allow-Headers': 'Content-Type, Authorization',
    'Access-Control-Max-Age': '86400',
    Vary: 'Origin',
  };
}

/**
 * Generate a short request id for log correlation and the X-Request-Id header.
 * Uses crypto.randomUUID where available (Workers + Node 22), else a fallback.
 *
 * @returns {string}
 */
export function makeRequestId() {
  try {
    return crypto.randomUUID();
  } catch {
    return `req_${Date.now().toString(36)}${Math.random().toString(36).slice(2, 8)}`;
  }
}

/**
 * Build a JSON Response with caching and security headers. CORS headers are
 * applied centrally by the fetch() wrapper, not here.
 *
 * @param {*} data
 * @param {object} [opts]
 * @param {number} [opts.status=200]
 * @param {string} [opts.requestId]
 * @param {number} [opts.maxAge=300] - Cache-Control max-age (seconds); 0 → no-store
 * @returns {Response}
 */
export function json(data, { status = 200, requestId, maxAge = 300 } = {}) {
  const headers = {
    'Content-Type': 'application/json; charset=utf-8',
    'Cache-Control': maxAge > 0 ? `public, max-age=${maxAge}` : 'no-store',
    ...SECURITY_HEADERS,
  };
  if (requestId) headers['X-Request-Id'] = requestId;
  return new Response(JSON.stringify(data, null, 2), { status, headers });
}

/**
 * Build a JSON error envelope (never cached).
 *
 * @param {string} message
 * @param {object} [opts]
 * @param {number} [opts.status=404]
 * @param {string} [opts.requestId]
 * @returns {Response}
 */
export function error(message, { status = 404, requestId } = {}) {
  return json({ error: message }, { status, requestId, maxAge: 0 });
}

/**
 * Return a copy of `res` with the given CORS headers applied. Used by the
 * fetch() wrapper so every response (success, error, preflight) is consistent.
 *
 * @param {Response} res
 * @param {Record<string,string>} cors
 * @returns {Response}
 */
export function withCors(res, cors) {
  const headers = new Headers(res.headers);
  for (const [k, v] of Object.entries(cors)) headers.set(k, v);
  return new Response(res.body, { status: res.status, statusText: res.statusText, headers });
}
