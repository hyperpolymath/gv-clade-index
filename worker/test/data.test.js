// SPDX-License-Identifier: MPL-2.0
// Contract tests for the committed registry snapshot (worker/data/*.json):
// enforce the 12-clade invariant and internal count/membership consistency,
// so snapshot drift (e.g. a repo added to repos.json but not re-indexed) fails CI.

import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import { describe, it, expect } from 'vitest';

import { VALID_CLADES } from '../src/validate.js';

const here = path.dirname(fileURLToPath(import.meta.url));
const load = (f) => JSON.parse(readFileSync(path.join(here, '../data', f), 'utf8'));

const repos = load('repos.json');
const clades = load('clades.json');
const index = load('index.json');

describe('clades.json', () => {
  it('defines exactly the 12 canonical clades', () => {
    expect(clades).toHaveLength(12);
    const codes = clades.map((c) => c.code).sort();
    expect(codes).toEqual([...VALID_CLADES].sort());
  });
});

describe('repos.json', () => {
  it('every repo has a name, a valid primary clade, and a github slug', () => {
    for (const repo of repos) {
      expect(typeof repo.name).toBe('string');
      expect(repo.name.length).toBeGreaterThan(0);
      expect(VALID_CLADES).toContain(repo.clade);
      expect(typeof repo.github).toBe('string');
    }
  });

  it('repo names are unique', () => {
    const names = repos.map((r) => r.name);
    expect(new Set(names).size).toBe(names.length);
  });
});

describe('index.json consistency', () => {
  it('total_repos equals repos.json and by_name counts', () => {
    expect(index.total_repos).toBe(repos.length);
    expect(Object.keys(index.by_name)).toHaveLength(repos.length);
  });

  it('clade membership covers every repo exactly once', () => {
    const sum = index.clades.reduce((acc, c) => acc + c.member_count, 0);
    expect(sum).toBe(repos.length);
    for (const c of index.clades) {
      expect(c.members).toHaveLength(c.member_count);
      for (const name of c.members) expect(index.by_name[name]).toBeTruthy();
    }
  });
});

// Registry data-integrity invariants — the "proofs" a governance/registry repo can
// actually guarantee (this project has no formal ABI/FFI surface; see
// verification/README.adoc and PROOF-NEEDS.md).
describe('registry invariants', () => {
  it('every repo prefixed name is "<clade>-<name>"', () => {
    for (const r of repos) {
      expect(r.prefixed).toBe(`${r.clade}-${r.name}`);
    }
  });

  it('secondary clade codes are valid and exclude the primary', () => {
    for (const r of repos) {
      for (const code of r.secondary || []) {
        expect(VALID_CLADES).toContain(code);
        expect(code).not.toBe(r.clade);
      }
    }
  });

  it('forge primary keys (github slugs) are unique', () => {
    const slugs = repos.map((r) => r.github);
    expect(new Set(slugs).size).toBe(slugs.length);
  });

  it('uuids are present, well-formed and unique', () => {
    const uuidRe = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
    const uuids = repos.map((r) => r.uuid);
    for (const u of uuids) expect(u).toMatch(uuidRe);
    expect(new Set(uuids).size).toBe(uuids.length);
  });
});
