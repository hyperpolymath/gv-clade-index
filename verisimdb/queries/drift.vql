-- SPDX-License-Identifier: PMPL-1.0-or-later
-- Drift: Repos where cached STATE.a2ml diverges from source

SELECT
  repo.document.title AS name,
  repo.semantic.clade_primary AS clade,
  ptr.field AS drifted_field,
  ptr.hash AS cached_hash,
  ptr.synced_at AS last_sync
FROM OCTAD repo
CROSS APPLY repo.provenance.authority_pointers AS ptr
WHERE repo.semantic.type = 'repo'
  AND ptr.type = 'pointer'
  AND ptr.hash != HASH(FETCH(ptr.source, ptr.field))
ORDER BY ptr.synced_at ASC;
