-- SPDX-License-Identifier: PMPL-1.0-or-later
-- VQL schema: Lineage event octad
-- Tracks inflate/deflate/rename/merge/split operations

DEFINE SCHEMA lineage VERSION 1.0.0;

DEFINE GRAPH lineage {
  source_repo: UUID,            -- repo being acted on
  target_repo: UUID?,           -- target (if merge/split)
  related_events: [UUID]        -- other lineage events in same operation
};

DEFINE SEMANTIC lineage {
  type: ENUM("lineage"),
  event_type: ENUM("inflate", "deflate", "rename", "merge", "split", "archive", "create", "delete"),
  old_name: STRING?,
  new_name: STRING?,
  old_parent: STRING?,
  new_parent: STRING?
};

DEFINE DOCUMENT lineage {
  title: STRING,
  body: TEXT,                   -- human-readable description of the change
  rationale: TEXT?              -- why the change was made
} INDEXED;

DEFINE TEMPORAL lineage {
  occurred: TIMESTAMP,
  recorded: TIMESTAMP
};

DEFINE PROVENANCE lineage {
  actor: STRING,                -- who performed the operation
  actor_type: ENUM("human", "bot", "agent"),
  session_id: STRING?
};
