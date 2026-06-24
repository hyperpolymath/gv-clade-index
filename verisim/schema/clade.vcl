-- SPDX-License-Identifier: MPL-2.0
-- VQL schema: Clade definition octad

DEFINE SCHEMA clade VERSION 1.1.0;
-- 1.1.0: aggregate counts realigned to the repo lifecycle phases (repo.vcl 1.1.0).

DEFINE GRAPH clade {
  members: [UUID],              -- repos in this clade (primary membership)
  secondary_members: [UUID],    -- repos with secondary membership
  related_clades: [{            -- inter-clade relationships
    clade: STRING(2),
    relationship: ENUM("depends_on", "feeds_into", "shares_infra", "overlaps")
  }]
};

DEFINE TENSOR clade {
  member_count: INT,            -- all members regardless of phase
  avg_completion: FLOAT,
  present_count: INT,           -- members with present=true (here-as-themselves)
  active_count: INT,            -- members in phase=active
  dormant_count: INT,           -- members in phase=dormant
  ended_count: INT              -- members in merged|superseded|archived|extinct
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
