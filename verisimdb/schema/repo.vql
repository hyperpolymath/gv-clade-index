-- SPDX-License-Identifier: PMPL-1.0-or-later
-- VQL schema: Repository octad
-- Each repository is an 8-modality entity in VeriSimDB

DEFINE SCHEMA repo VERSION 1.0.0;

-- Graph modality: relationships between repos
DEFINE GRAPH repo {
  depends_on: [UUID],           -- repos this depends on
  depended_by: [UUID],          -- repos depending on this
  clade_edge: UUID,             -- link to clade octad
  monorepo_parent: UUID?,       -- parent monorepo (if child)
  monorepo_children: [UUID],    -- children (if monorepo)
  forge_links: {                -- primary + foreign key links
    github: STRING,
    gitlab: STRING?,
    bitbucket: STRING?,
    codeberg: STRING?,
    sourcehut: STRING?,
    radicle: STRING?
  },
  tags: [STRING]                -- free-form tags
};

-- Vector modality: semantic embedding for similarity search
DEFINE VECTOR repo {
  purpose_embedding: FLOAT[384],  -- sentence-transformer embedding of description
  tech_embedding: FLOAT[384]      -- embedding of technology stack
};

-- Tensor modality: numeric metrics over time
DEFINE TENSOR repo {
  completion: FLOAT,            -- 0.0 to 100.0
  loc: INT,                     -- lines of code
  test_count: INT,              -- number of tests
  open_issues: INT,             -- open issue count
  dependency_count: INT         -- direct dependencies
} TEMPORAL;                     -- time-series tracking enabled

-- Semantic modality: typed metadata
DEFINE SEMANTIC repo {
  type: ENUM("repo"),
  clade_primary: STRING(2),     -- 2-char clade code
  clade_secondary: [STRING(2)],
  license: STRING,              -- SPDX identifier
  languages: [STRING],          -- programming languages used
  version: STRING?,             -- current version if applicable
  status: ENUM("active", "stale", "archived", "experimental", "complete"),
  lineage_type: ENUM("standalone", "monorepo", "monorepo-child", "inflated", "deflated")
};

-- Document modality: full-text searchable content
DEFINE DOCUMENT repo {
  title: STRING,                -- display name
  description: TEXT,            -- one-line description
  readme_summary: TEXT?,        -- first section of README
  setup_instructions: TEXT?,    -- extracted setup/install docs
  changelog_latest: TEXT?,      -- latest changelog entry
  state_body: TEXT?             -- STATE.a2ml content cache
} INDEXED;                      -- full-text search enabled

-- Temporal modality: time tracking
DEFINE TEMPORAL repo {
  created: TIMESTAMP,           -- repo creation date
  last_commit: TIMESTAMP?,      -- most recent git commit
  last_state_change: TIMESTAMP?,-- last meaningful state update
  last_activity: TIMESTAMP,     -- max(commit, state_change, bot_finding)
  sessions: [{                  -- work sessions
    id: STRING,
    started: TIMESTAMP,
    ended: TIMESTAMP?,
    agent: STRING               -- "claude-code", "jonathan", etc.
  }]
};

-- Provenance modality: origin and authority tracking
DEFINE PROVENANCE repo {
  creator: STRING,              -- who created the repo
  last_modifier: STRING,        -- who last changed state
  authority_pointers: [{        -- pointer authority system
    field: STRING,              -- which field
    type: ENUM("pointer", "local", "derived"),
    source: STRING?,            -- external source path (if pointer)
    hash: STRING?,              -- SHA-256 of cached value
    synced_at: TIMESTAMP?
  }],
  attestations: [{              -- signed attestations
    claim: STRING,
    signer: STRING,
    signature: STRING,
    timestamp: TIMESTAMP
  }]
};

-- Spatial modality: reserved for future use
DEFINE SPATIAL repo {
  org_x: FLOAT?,               -- position in org hierarchy visualisation
  org_y: FLOAT?
};
