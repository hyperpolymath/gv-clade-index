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
