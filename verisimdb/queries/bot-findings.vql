-- SPDX-License-Identifier: PMPL-1.0-or-later
-- Bot Findings: Unacknowledged observations from bots and agents

SELECT
  obs.document.title AS finding,
  obs.document.body AS detail,
  obs.provenance.actor AS bot,
  obs.tensor.severity AS severity,
  obs.graph.repo AS repo_id,
  repo.document.title AS repo_name,
  obs.temporal.created AS found_at
FROM OCTAD obs
JOIN OCTAD repo ON obs.graph.repo = repo.identity.uuid
WHERE obs.semantic.type = 'observation'
  AND obs.provenance.actor_type IN ('bot', 'agent', 'ci')
  AND obs.semantic.status = 'new'
ORDER BY obs.tensor.severity ASC, obs.temporal.created DESC;
