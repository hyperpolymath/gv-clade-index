-- SPDX-License-Identifier: PMPL-1.0-or-later
-- Cross-Clade Dependencies: repos depending on repos in a different clade

SELECT
  src.document.title AS source_repo,
  src.semantic.clade_primary AS source_clade,
  tgt.document.title AS target_repo,
  tgt.semantic.clade_primary AS target_clade
FROM OCTAD src
JOIN OCTAD tgt ON src.graph.depends_on CONTAINS tgt.identity.uuid
WHERE src.semantic.type = 'repo'
  AND tgt.semantic.type = 'repo'
  AND src.semantic.clade_primary != tgt.semantic.clade_primary
ORDER BY src.semantic.clade_primary, tgt.semantic.clade_primary;
