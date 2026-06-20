// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell
//
// HTTP response helpers: CORS, security headers, JSON envelopes, request ids.

export const CORS_HEADERS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'GET, OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type, Authorization',
  'Access-Control-Max-Age': '86400',
};

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
 * Build a JSON Response with caching, CORS and security headers.
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
    ...CORS_HEADERS,
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
