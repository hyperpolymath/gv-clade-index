<!-- SPDX-License-Identifier: CC-BY-SA-4.0 -->
<!-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk> -->
<!-- Authoritative source: docs/AI-CONVENTIONS.md -->

# Copilot Instructions

## Before Writing Code

- Read `0-AI-MANIFEST.deed` in the repo root first: it points at the repo deed.
- Repo metadata is deed (`gv-clade-index_chora.deed`, `.machine_readable/descriptiles/STATE.deed`). A2ML is retired: never create a `.a2ml` file.

## License

- SPDX: `MPL-2.0` on all new files.
- Never use AGPL-3.0.
- Copyright: `Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>`

## Code Style

- Use descriptive variable names.
- Annotate and document all files.
- Add SPDX header to every source file.
- Use `just` for build/test/lint commands.

## Banned Patterns

- Idris2: no `believe_me`, no `assert_total`
- Haskell: no `unsafeCoerce`, no `unsafePerformIO`
- OCaml: no `Obj.magic`
- Coq: no `Admitted`
- Lean: no `sorry`
- Rust: no `transmute` unless FFI with `// SAFETY:` comment

## Banned Languages

- No TypeScript (use ReScript)
- No Node.js / npm / bun (use Deno)
- No Go (use Rust)
- No Python (use Julia or Rust)

## Containers

- Use Podman, never Docker.
- Name the file `Containerfile`, never `Dockerfile`.
- Base image: `cgr.dev/chainguard/wolfi-base:latest`.

## ABI/FFI

- ABI definitions in Idris2 (`src/interface/abi/`).
- FFI implementations in Zig (`src/interface/ffi/`).
- Generated C headers in `src/interface/generated/`.

## State Files

Repo facts live in `gv-clade-index_chora.deed`; descriptiles (`STATE.deed` and
the like) live in `.machine_readable/descriptiles/` only, never the root. Never
create a `.a2ml` file (A2ML is retired; `docs/history/A2ML-REMOVED.adoc`).
