-- SPDX-License-Identifier: PMPL-1.0-or-later
-- VQL schema: External feedback octad
-- Tracks feedback from contributors, users, and external parties

DEFINE SCHEMA feedback VERSION 1.0.0;

DEFINE GRAPH feedback {
  repo: UUID?,                  -- associated repo (if any)
  clade: STRING(2)?,
  resulted_in_todo: UUID?,      -- TODO created from this
  resulted_in_commit: STRING?,  -- commit SHA that addressed this
  resulted_in_pr: STRING?       -- PR that addressed this
};

DEFINE SEMANTIC feedback {
  type: ENUM("feedback"),
  category: ENUM("bug_report", "feature_request", "question", "praise", "complaint", "security"),
  status: ENUM("received", "acknowledged", "investigating", "acted_on", "declined", "duplicate"),
  decline_reason: TEXT?         -- why it was declined (if applicable)
};

DEFINE DOCUMENT feedback {
  title: STRING,
  body: TEXT,
  response: TEXT?               -- our response to the submitter
} INDEXED;

DEFINE TEMPORAL feedback {
  submitted: TIMESTAMP,
  acknowledged: TIMESTAMP?,
  resolved: TIMESTAMP?
};

DEFINE PROVENANCE feedback {
  submitter: STRING,            -- GitHub handle or identifier
  submitter_type: ENUM("contributor", "user", "external", "anonymous"),
  channel: ENUM("github_issue", "email", "portal", "api"),
  responder: STRING?            -- who responded
};
