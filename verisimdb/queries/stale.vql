-- SPDX-License-Identifier: PMPL-1.0-or-later
-- Stale: Repos with no meaningful activity in 90+ days

SELECT
  repo.document.title AS name,
  repo.semantic.clade_primary AS clade,
  repo.temporal.last_activity AS last_activity,
  repo.tensor.completion AS completion,
  DRIFT(repo.document.state_body, repo.temporal.last_activity) AS staleness
FROM OCTAD repo
WHERE repo.semantic.type = 'repo'
  AND repo.temporal.last_activity < NOW() - INTERVAL '90 days'
  AND repo.semantic.status != 'archived'
ORDER BY repo.temporal.last_activity ASC;
