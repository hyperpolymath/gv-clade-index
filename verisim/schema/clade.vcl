-- SPDX-License-Identifier: PMPL-1.0-or-later
-- VQL schema: Clade definition octad

DEFINE SCHEMA clade VERSION 1.0.0;

DEFINE GRAPH clade {
  members: [UUID],              -- repos in this clade (primary membership)
  secondary_members: [UUID],    -- repos with secondary membership
  related_clades: [{            -- inter-clade relationships
    clade: STRING(2),
    relationship: ENUM("depends_on", "feeds_into", "shares_infra", "overlaps")
  }]
};

DEFINE TENSOR clade {
  member_count: INT,
  avg_completion: FLOAT,
  active_count: INT,
  stale_count: INT
} TEMPORAL;

DEFINE SEMANTIC clade {
  type: ENUM("clade"),
  code: STRING(2),
  name: STRING,
  description: TEXT,
  colour: STRING,
  icon: STRING,
  keywords: [STRING]
};

DEFINE DOCUMENT clade {
  title: STRING,
  description: TEXT,
  health_report: TEXT?          -- generated health summary
} INDEXED;

DEFINE TEMPORAL clade {
  created: TIMESTAMP,
  last_member_change: TIMESTAMP,
  last_health_check: TIMESTAMP?
};

DEFINE PROVENANCE clade {
  creator: STRING,
  last_modifier: STRING
};
