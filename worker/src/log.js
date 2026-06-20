// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell
//
// Structured JSON logging for the clade-registry Worker.
//
// Emits one JSON object per line so Cloudflare Logpush / `wrangler tail`
// can parse and filter by field (level, reqId, path, ...). Workers captures
// console.* into its log stream, so we route through console.

/**
 * Create a logger bound to a set of default fields (e.g. a request id).
 *
 * @param {object} [bindings] - fields merged into every emitted line
 * @returns {{debug:Function,info:Function,warn:Function,error:Function,child:Function}}
 */
export function createLogger(bindings = {}) {
  function emit(level, msg, fields) {
    const line = { level, msg, ts: new Date().toISOString(), ...bindings, ...fields };
    const out = level === 'error' || level === 'warn' ? console.error : console.log;
    out(JSON.stringify(line));
  }
  return {
    debug: (msg, fields) => emit('debug', msg, fields),
    info: (msg, fields) => emit('info', msg, fields),
    warn: (msg, fields) => emit('warn', msg, fields),
    error: (msg, fields) => emit('error', msg, fields),
    child: (extra) => createLogger({ ...bindings, ...extra }),
  };
}

/** Module-level logger with no bindings — used as a default. */
export const log = createLogger();
