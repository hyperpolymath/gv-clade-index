-- SPDX-License-Identifier: PMPL-1.0-or-later
-- VQL schema: Forge identity mapping
-- Maps primary key (GitHub) to foreign keys (mirrors)

DEFINE SCHEMA forge_identity VERSION 1.0.0;

DEFINE GRAPH forge_identity {
  repo: UUID,                   -- the repo this identity belongs to
  primary_forge: STRING,        -- "github"
  mirror_forges: [STRING]       -- ["gitlab", "bitbucket", ...]
};

DEFINE SEMANTIC forge_identity {
  type: ENUM("forge_identity"),
  primary_url: STRING,          -- e.g. "github.com/hyperpolymath/januskey"
  mirror_urls: [{
    forge: STRING,
    url: STRING,
    status: ENUM("active", "stale", "broken", "pending")
  }]
};

DEFINE TEMPORAL forge_identity {
  created: TIMESTAMP,
  last_verified: TIMESTAMP?,    -- when mirrors were last confirmed working
  last_sync: TIMESTAMP?         -- when mirror.yml last pushed
};

DEFINE PROVENANCE forge_identity {
  verified_by: STRING?,         -- who/what last verified mirrors
  verification_method: ENUM("api_check", "manual", "mirror_yml_push")
};
