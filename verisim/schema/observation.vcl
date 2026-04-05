-- SPDX-License-Identifier: PMPL-1.0-or-later
-- VQL schema: Bot/agent observation octad
-- Unifies all bot findings, agent observations, and automated reports

DEFINE SCHEMA observation VERSION 1.0.0;

DEFINE GRAPH observation {
  repo: UUID,                   -- which repo
  clade: STRING(2),             -- which clade
  related_todos: [UUID],        -- TODOs created from this observation
  related_observations: [UUID]  -- other observations on same topic
};

DEFINE TENSOR observation {
  severity: INT,                -- 0 = critical, 1 = high, 2 = medium, 3 = low, 4 = info
  confidence: FLOAT             -- 0.0 to 1.0 — how confident the observer is
};

DEFINE SEMANTIC observation {
  type: ENUM("observation"),
  category: ENUM("vulnerability", "drift", "compliance", "quality", "performance", "stale", "pattern"),
  status: ENUM("new", "acknowledged", "acted_on", "dismissed", "false_positive")
};

DEFINE DOCUMENT observation {
  title: STRING,
  body: TEXT,
  evidence: TEXT?,              -- supporting data/proof
  recommendation: TEXT?         -- what should be done
} INDEXED;

DEFINE TEMPORAL observation {
  created: TIMESTAMP,
  acknowledged: TIMESTAMP?,
  resolved: TIMESTAMP?
};

DEFINE PROVENANCE observation {
  actor: STRING,                -- "echidnabot", "rhodibot", "hypatia", "claude-code", etc.
  actor_type: ENUM("bot", "agent", "ci", "human"),
  scan_id: STRING?,             -- identifier for the scan run
  tool_version: STRING?         -- version of the tool that found it
};
