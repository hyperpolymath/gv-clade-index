# TEST-NEEDS.md — gv-clade-index

## Current test state

The deliverable is the Cloudflare Worker registry API (`worker/`). Tests run on
Vitest (Node) and are gated in CI by `.github/workflows/worker-ci.yml`.

| Suite | Location | Count | Covers |
|-------|----------|-------|--------|
| Worker integration | `worker/test/worker.test.js` | 30 | Routing, input validation, security headers, CORS, pagination, search/LLM, 405/404/429/500/503 paths, KV-fallback queries, fuzz (no uncontrolled 5xx) |
| Data contract | `worker/test/data.test.js` | 3 | 12-clade invariant + snapshot count/membership consistency |

Run:

```bash
cd worker && npm install && npm test
```

## Covered

- [x] Unit + integration tests for all 9 API endpoints
- [x] Input validation and error-path tests (400/404/405/429/500/503)
- [x] Fuzz sweep (random paths/params → no uncontrolled 5xx)
- [x] Data contract test (clade invariant, count consistency)
- [x] CI automation (lint + format + test + bundle dry-run on every PR)

## Still missing

- [ ] Integration tests against a live VeriSimDB (blocked on Phase 2)
- [ ] End-to-end smoke tests against a deployed staging Worker
- [ ] Tests for the future auth tiers (LLM key, bot JWT, contributor OAuth)

## Notes

This project has **no native/FFI surface**. The former Zig FFI template stubs
under `src/interface/ffi/` were removed — they were non-compiling `{{project}}`
template placeholders, not real tests.
