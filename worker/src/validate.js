// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell
//
// Input validation helpers for untrusted path / query parameters.

// The 12 canonical clade codes. Mirrors contractiles/must/clade-hygiene.a2ml
// and verisim/seed/clades.a2ml — keep in sync if the taxonomy changes.
export const VALID_CLADES = Object.freeze([
  'fv',
  'nl',
  'rm',
  'gv',
  'db',
  'ap',
  'ix',
  'dx',
  'pt',
  'ax',
  'gm',
  'sc',
]);

const CLADE_SET = new Set(VALID_CLADES);

/**
 * @param {unknown} code
 * @returns {boolean} true when code is one of the 12 canonical clade codes
 */
export function isValidClade(code) {
  return typeof code === 'string' && CLADE_SET.has(code);
}

/**
 * Parse a positive integer query param with a default and an inclusive maximum.
 * Returns `fallback` (capped at `max`) for missing / NaN / < 1 values.
 *
 * @param {string|null|undefined} raw
 * @param {number} fallback
 * @param {number} [max]
 * @returns {number}
 */
export function positiveInt(raw, fallback, max = Number.MAX_SAFE_INTEGER) {
  const n = Number.parseInt(raw ?? '', 10);
  if (!Number.isFinite(n) || n < 1) return Math.min(fallback, max);
  return Math.min(n, max);
}

/**
 * Decode a URI component, returning null on malformed input instead of throwing.
 *
 * @param {string} raw
 * @returns {string|null}
 */
export function safeDecode(raw) {
  try {
    return decodeURIComponent(raw);
  } catch {
    return null;
  }
}

// Maximum accepted length for free-text search queries.
export const MAX_QUERY_LEN = 256;

/**
 * Normalise and bound a free-text query param.
 *
 * @param {string|null|undefined} raw
 * @returns {{ok:true,value:string}|{ok:false,reason:string}}
 */
export function boundedQuery(raw) {
  if (raw == null) return { ok: false, reason: 'Query parameter q is required' };
  const value = raw.trim();
  if (value.length === 0) return { ok: false, reason: 'Query parameter q is required' };
  if (value.length > MAX_QUERY_LEN) {
    return { ok: false, reason: `Query too long (max ${MAX_QUERY_LEN} characters)` };
  }
  return { ok: true, value };
}
