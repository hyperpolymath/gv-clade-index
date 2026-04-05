-- SPDX-License-Identifier: PMPL-1.0-or-later
-- Blocked: Open TODOs that are blocked by other incomplete TODOs

SELECT
  blocked.document.title AS blocked_todo,
  blocked.tensor.priority AS priority,
  blocker.document.title AS blocked_by,
  blocker.semantic.status AS blocker_status,
  blocked.semantic.category AS category,
  blocked.provenance.creator AS creator
FROM OCTAD blocked
JOIN OCTAD blocker ON blocked.graph.blocked_by CONTAINS blocker.identity.uuid
WHERE blocked.semantic.type = 'todo'
  AND blocked.semantic.status IN ('open', 'blocked')
  AND blocker.semantic.status NOT IN ('done', 'wontfix')
ORDER BY blocked.tensor.priority ASC;
