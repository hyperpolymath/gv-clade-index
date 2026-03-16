-- SPDX-License-Identifier: PMPL-1.0-or-later
-- Dashboard: Full ecosystem overview grouped by clade

SELECT
  clade.semantic.code AS code,
  clade.semantic.name AS name,
  clade.tensor.member_count AS repos,
  clade.tensor.avg_completion AS avg_completion,
  clade.tensor.active_count AS active,
  clade.tensor.stale_count AS stale,
  clade.temporal.last_member_change AS last_change
FROM OCTAD clade
WHERE clade.semantic.type = 'clade'
ORDER BY clade.semantic.code ASC;
