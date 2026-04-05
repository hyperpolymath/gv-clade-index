-- SPDX-License-Identifier: PMPL-1.0-or-later
-- Feedback Status: All feedback with resolution tracking

SELECT
  fb.document.title AS feedback,
  fb.semantic.status AS status,
  fb.semantic.category AS category,
  fb.provenance.submitter AS submitter,
  fb.temporal.submitted AS submitted,
  fb.temporal.resolved AS resolved,
  fb.graph.resulted_in_todo AS todo_id,
  fb.graph.resulted_in_commit AS commit_sha,
  fb.document.response AS response
FROM OCTAD fb
WHERE fb.semantic.type = 'feedback'
ORDER BY fb.temporal.submitted DESC;
