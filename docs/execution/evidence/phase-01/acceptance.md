# Phase 1 acceptance report

Candidate implementation tip: rebound by `P01-990/gate-results.json` and the task-status CAS record
when the local gate suite completes.

Execution mode: `local_provisional`

Local projection: `ready_for_review`

Formal acceptance: `pending_external`

Decision boundary: Phase 2 local implementation may branch from the resulting provisional
checkpoint only after every P01-990 local mode passes. Phase 1 is not `accepted`; P01-999, push,
remote merge, production write/deploy, traffic activation, and Release acceptance remain prohibited.

## Outcome

The local Phase 1 candidate freezes current Flutter call/write/fallback facts, a strict four-class
validation contract, 8 synthetic fixtures, a default-off Flutter/Agent seam, and complete
v1.6.1/AGENTS 1.4.0 hard-constraint traceability. The dedicated Flutter suite passes 3/3 with 0
failures, 0 skips, and 0 xfails. All 39 hard-constraint markers are mapped and no result or fallback
enables a formal domain write.

No Agent service, model/Graph/Tool execution, migration, production query/write, deployment, push,
or merge occurred. Independent Product/Security review and production-only database/deployment facts
remain pending.

## Task state

| Task | Local result | Formal state | Precise remaining boundary |
|---|---|---|---|
| P01-001 | current call/write/fallback inventory complete | ready_for_review | independent Product/Security review |
| P01-002 | validation schema and four-class semantics complete | ready_for_review | immutable Product/Security approval |
| P01-003 | 8 fixtures; 3/3 tests pass | ready_for_review | independent replay/approval |
| P01-004 | old/new seam, owners, flag and rollback matrix complete | ready_for_review | future service implementation and review |
| P01-005 | 39/39 hard constraints mapped | ready_for_review | Architecture/Engineering/Security decision receipt |
| P01-089 | docs, handoff, task board and non-mutating Harness receipt complete | ready_for_review | non-implementer handoff review |

## Mandatory local evidence

1. Scope: every task workset is bounded; Phase 1 changes add contracts/tests/docs/evidence only.
2. Semantics: `hard`, `warning`, `unverified`, and `verified` precedence is deterministic and every
   class remains an importable but non-authoritative Candidate draft.
3. Security: client-provider re-enablement, domain-write enablement, secret findings, PII canary
   leaks, runtime/database changes, and production writes are zero.
4. Compatibility: chat, manual import, Auth, and fallback remain; itinerary planning uses a
   separate future seam whose flag is default-off.
5. Regression: 8 synthetic fixtures load; 3 tests pass; failed/skipped/xfailed are all zero.
6. Traceability: 39 source markers map to 39 unique HC rows; incomplete and unmapped counts are zero.
7. Handoff: README, architecture, API, runbook, change summary, five-section KT, threat-model receipt,
   STAR evidence, and premerge manifest match the actual diff.
8. Harness: the Phase 1 aggregate proves 34 unique controls and 149 minimum cases without changing
   any control status or claiming implementation.
9. Rollback: flag-off, unavailable-service fallback, and rollback states preserve compatibility;
   in-flight Agent Run recovery is not applicable before Phase 2 creates the runtime.
10. Governance: local evidence is reviewable; accepted/merge/push/production remain false.

## Blockers and repair closure

The P01-089 Workset verifier initially treated nine authorized evidence paths as unexpected because
it read only `file_allowlist` and omitted Catalog `evidence_outputs`, `status_file`, and the task-card
archive prefixes. The runner now merges all four sources. The affected gate then passed with
`unexpected_paths=0`, and every later P01-089 local mode passed. Its blocker record is
`resolved_local_provisional`; open P0/P1 count and blocker-without-final-state count are both zero.

## Formal-only pending boundaries

- Independent Product and Security decisions bound to the immutable candidate and evidence hashes.
- Formal governance adoption and authorized landing merge.
- Production schema/RLS/grant/retention/deletion facts and later deployment evidence where applicable.

These boundaries keep formal acceptance pending. They do not authorize the implementation actor to
forge approval, run P01-999, or perform any remote/production action.
