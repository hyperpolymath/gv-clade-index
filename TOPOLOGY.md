<!-- SPDX-License-Identifier: PMPL-1.0-or-later -->
<!-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk> -->
# TOPOLOGY.md — gv-clade-index

## Purpose

gv-clade-index is the central registry for the hyperpolymath ecosystem, providing a VeriSimDB-backed taxonomy of 200+ repositories organised into 12 clades (fv, nl, rm, gv, db, ap, ix, dx, pt, ax, gm, sc). It exposes a Cloudflare Worker API for dashboards, drift detection, and work-tracking VCL queries. The index is the canonical map of the ecosystem — editing it never modifies the repositories it describes.

## Module Map

```
gv-clade-index/
├── verisim/                     # VeriSimDB instance (clade data store)
│   ├── config.a2ml                # Database instance configuration
│   ├── schema/                    # VCL schemas (repo, clade, pointer, etc.)
│   ├── queries/                   # Named VCL queries for dashboards
│   └── seed/                      # Initial seed data (200+ repos)
├── worker/                        # Cloudflare Worker (edge API)
│   ├── wrangler.toml              # CF Worker deployment config
│   └── src/
│       ├── index.js               # Worker entry point + request routing
│       └── verisim.js           # VeriSimDB client for the worker
├── sync/                          # Sync scripts (GitHub → VeriSimDB)
│   ├── deploy-clade-a2ml.sh       # Deploy A2ML manifests to clades
│   ├── export-json.sh             # Export registry as JSON
│   ├── parse-repos.sh             # Parse repo metadata
│   └── seed-verisim.sh          # Seed the VeriSimDB instance
├── src/                           # Idris2 ABI + source contracts
│   ├── core/                      # Core clade index logic
│   ├── contracts/                 # API contract definitions
│   ├── bridges/                   # Integration bridges
│   └── aspects/                   # Cross-cutting concerns
├── tests/                         # Integration tests
├── docs/                          # Architecture documentation
└── verification/                  # Formal verification proofs
```

## Data Flow

```
[GitHub repos / CI events]
        │  sync scripts (sync/*.sh)
        ▼
[VeriSimDB instance] ──► [verisim/schema/ VCL] ──► [verisim/queries/ named queries]
        │
        ▼
[worker/src/verisim.js] ──► [worker/src/index.js] ──► [Cloudflare Worker edge]
                                                                │
                                              ┌─────────────────┴─────────────────┐
                                              ▼                                    ▼
                                    [Dashboard consumers]               [Drift detection CI]
                                    (clade listing, repo search)        (stale/missing repos)
```
