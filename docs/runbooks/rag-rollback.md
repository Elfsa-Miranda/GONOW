# RAG rollback runbook

Scope: the Phase 11 single-Agent RAG path. This runbook does not authorize production writes.

## Enable

Confirm the Release C RAG selection, owner receipts, approved cohort IDs, certified package digest, active alias generation, deletion replay, and ACL canary. Increase only the approved `gonow.agent.itinerary_planning.rag` allocation.

## Disable

The first action is flag allocation zero. Preserve the candidate package, trace IDs, immutable receipts, and knowledge tables for diagnosis. Do not promote a new alias during incident containment.

## Degrade

Route new Runs to the prior no-RAG single-Agent behavior. Existing durable Runs keep their pinned behavior/package identity; do not silently switch their evidence manifest mid-Run. Empty authorized retrieval may continue uncited, but authorization or manifest errors fail closed.

## Rollback drill

1. Freeze candidate alias generation and record its digest.
2. Set RAG allocation to zero with generation CAS.
3. Prove new Runs select the prior path and an in-flight Run cannot acquire a different manifest.
4. Query deletion tombstones before any restore test; tombstoned sources must remain unreadable.
5. Verify citation, tenant, ACL, stale-version, cost, and error metrics return to the prior envelope.

## First checks

- Flag key, generation, allocation, and cohort receipt.
- Knowledge alias and package certification digest.
- `knowledge.retrieval_fusion_conflict`, `knowledge.unknown_claim`, or Worker dependency errors.
- Tenant/principal context and RLS deny evidence.
- Tombstone and six surface receipts.

`contract_change: none` during rollback. Never contract schema or delete evidence as the first response.
