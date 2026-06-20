// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell
//
// Optional edge rate limiting via Cloudflare's native Rate Limiting binding.
// No-ops when the binding is absent (local dev / tests), and fails open so the
// limiter can never take down the read API.
//
// Configure in wrangler.toml, e.g.:
//   [[unsafe.bindings]]
//   name = "RATE_LIMITER"
//   type = "ratelimit"
//   namespace_id = "1001"
//   simple = { limit = 100, period = 60 }

/**
 * @param {object} env - Worker env bindings
 * @param {string} key - rate-limit bucket key (e.g. client IP + route)
 * @returns {Promise<boolean>} true when the request is allowed
 */
export async function allow(env, key) {
  const limiter = env && env.RATE_LIMITER;
  if (!limiter || typeof limiter.limit !== 'function') return true;
  try {
    const { success } = await limiter.limit({ key });
    return success !== false;
  } catch {
    return true; // fail open
  }
}
