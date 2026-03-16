-- SPDX-License-Identifier: PMPL-1.0-or-later
-- VQL schema: Work item / TODO octad
-- Replaces scattered memory files, queue dumps, and bot logs

DEFINE SCHEMA todo VERSION 1.0.0;

DEFINE GRAPH todo {
  repo: UUID?,                  -- associated repo (if any)
  clade: STRING(2)?,            -- associated clade (if any)
  blocks: [UUID],               -- TODOs this blocks
  blocked_by: [UUID],           -- TODOs blocking this
  resulted_from: UUID?,         -- feedback/observation that spawned this
  resulted_in: UUID?            -- commit/PR that resolved this
};

DEFINE TENSOR todo {
  priority: INT,                -- 0 = P0 (highest), 7 = P7 (lowest)
  effort_estimate: INT?,        -- estimated hours (optional)
  progress: FLOAT               -- 0.0 to 1.0
} TEMPORAL;

DEFINE SEMANTIC todo {
  type: ENUM("todo"),
  category: ENUM("bug", "feature", "refactor", "docs", "security", "infra", "governance", "research"),
  status: ENUM("open", "in_progress", "blocked", "done", "wontfix", "superseded"),
  source: ENUM("human", "bot", "agent", "ci")
};

DEFINE DOCUMENT todo {
  title: STRING,
  body: TEXT,
  resolution: TEXT?             -- how it was resolved (if done)
} INDEXED;

DEFINE TEMPORAL todo {
  created: TIMESTAMP,
  updated: TIMESTAMP,
  due: TIMESTAMP?,
  started: TIMESTAMP?,
  completed: TIMESTAMP?,
  acknowledged: TIMESTAMP?      -- when someone first saw this
};

DEFINE PROVENANCE todo {
  creator: STRING,              -- who/what created it
  creator_type: ENUM("human", "bot", "agent"),
  assignee: STRING?,
  session_id: STRING?,          -- which session created it
  authority_pointers: [{
    field: STRING,
    type: ENUM("pointer", "local", "derived"),
    source: STRING?,
    hash: STRING?,
    synced_at: TIMESTAMP?
  }]
};
