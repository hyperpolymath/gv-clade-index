-- SPDX-License-Identifier: PMPL-1.0-or-later
-- Orphans: Repos without a CLADE.a2ml declaration

SELECT
  repo.document.title AS name,
  repo.temporal.last_activity AS last_activity,
  repo.tensor.completion AS completion
FROM OCTAD repo
WHERE repo.semantic.type = 'repo'
  AND (repo.semantic.clade_primary IS NULL OR repo.semantic.clade_primary = '')
ORDER BY repo.document.title ASC;
