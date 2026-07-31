# Phase 3 acceptance report

Candidate implementation tip: `fa52bd994ef83bf1a016d95beb53870c279566e7`

Phase base OID: `aff2517da3143d539b0d639f9fa3bde6ec192181`

Execution mode: `local_provisional`

Local projection: `in_progress`

Formal acceptance: `pending_external`

Phase 4 local work may branch only from the later provisional checkpoint after every P03-990 local mode passes. Phase 3 is not accepted; P03-999, remote push/merge, deployment, production migration, and production write remain prohibited.

## Outcome

Phase 3 adds PostgreSQL-backed Run, Thread, Event, idempotency, durable-job, lease, checkpoint, Behavior release, outbox, receipt, dead-letter, and tenant RLS contracts. Runtime state, CAS winners, ordered event sequence, restore integrity, and immutable behavior release evidence are locally reproducible.

Fresh local regression: unit/integration tests `215`; explicit contract tests `44`; failed/not-run/skipped/xfailed all zero.

## Contract and security gates

CT-001, CT-002, CT-003, CT-004, CT-007, CT-012, and CT-013 pass in the local projection; skipped and xfailed counts are zero. The Harness Catalog retains 34 unique controls and 149 minimum cases, with 14 implemented controls and no missing S/I/D path. Secret, PII, audit-receipt, tenant-leak, RLS bypass, production-write, push, and merge counts are zero.

## Rollback and repair closure

The isolated rollback drill covered idle state, three in-flight Runs, and an old-reader projection over the new runtime schema; local duration seconds: ``.
The migration restore rehearsal preserved eight logical rows and identical logical hashes, rejected downgrade under the forward-fix policy, and revalidated CT-007. RPO and RTO remain `unknown_not_claimed` until production-like owner evidence exists.

Resolved blockers: `BLK-P03-001-license-metadata-normalization` (dependency metadata root cause), `BLK-P03-089-security-self-scan` (scanner self-match root cause), and `BLK-P03-990-blocker-final-state-aggregation` (terminal-state normalization root cause). All retain reproduction, full repair, regression, and rollback evidence.

## Formal-only pending boundaries

- Independent Engineering, Security, and SRE approvals bound to the immutable candidate.
- Formal governance adoption and authorized landing merge.
- Production database role/grant/backup/retention inventory.
- Production same-configuration rollback drill with measured RPO and RTO.

These external boundaries do not block safe local implementation, but they prevent accepted status, P03-999, remote push/merge, deployment, production migration, and production operations.
