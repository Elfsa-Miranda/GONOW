# Runtime persistence architecture

Phase 3 makes PostgreSQL the local source of truth for Agent control-plane identity and ordering. This document describes the candidate at migration `p03_007_runtime_rls`; it does not claim that a production database has been migrated or reviewed.

## Process and ownership boundary

The existing `agent-api` and `agent-worker` remain separate processes. Repositories require caller-owned transactions and accept server-derived tenant/principal context. The database, not an in-memory map or process lock, owns Run identity, idempotency reservations, state version, event sequence, job fencing, checkpoint lineage, Behavior release pointers, and outbox delivery receipts.

Phase 3 does not run a model, Graph, Tool, Candidate projector, job runner, or Domain Command. Job/Lease/checkpoint rows are metadata contracts for later phases, not proof of durable Worker recovery.

## Schemas and tables

`agent_runtime` contains ten RLS-protected tables:

| Table | Source-of-truth responsibility | Key fence |
|---|---|---|
| `threads` | tenant-owned conversation container | tenant-qualified unique identity |
| `runs` | Run state, Behavior manifest snapshot, state version, next Event sequence | legal transition trigger and version CAS |
| `events` | ordered, auditable Runtime events | unique `(run_id, seq)` allocated under Run row lock |
| `idempotency_records` | request reservation | unique tenant/principal/scope/key plus request hash |
| `jobs` | future durable work metadata | status, bounded attempts, current fencing token |
| `leases` | future Worker ownership metadata | one active lease and monotonic fence |
| `checkpoint_metadata` | immutable checkpoint lineage/references | per-Run sequence and matching fence |
| `outbox_messages` | Event-linked transactional delivery intent | bounded claim/retry state |
| `delivery_receipts` | unique consumer delivery effect | unique outbox/consumer receipt |
| `dead_letters` | terminal delivery metadata | no business payload body |

`agent_behavior` contains immutable revisions, certifications, releases, deployment pointers and deployment history. Releases reference content-addressed components; the manifest digest is RFC 8785 canonical JSON plus SHA-256. Only an authorized release operator can mutate Behavior records, and deployment movement is generation CAS.

## Runtime invariants

- One idempotency key with the same body resolves to one Run; the original winner is unique and all other callers replay it. A different body is a stable conflict.
- Terminal Run states have no outbound transition. State updates bind tenant, prior state and prior version in one database update.
- Event append locks the Run row, rejects terminal Runs, allocates contiguous positive sequence numbers and requires an audit receipt.
- Outbox enqueue is in the Event transaction. Delivery receipts are unique; retry is bounded; dead letters contain reason/audit metadata but not the Event payload.
- Behavior pointers move only from the expected generation. Published releases and historical generations remain addressable.
- Restore evidence compares a stable logical hash before upgrade, after upgrade and after restore. A mismatch fails closed.

## Tenant and role boundary

All ten Runtime tables have `ENABLE ROW LEVEL SECURITY`, `FORCE ROW LEVEL SECURITY` and an exact `tenant_isolation` policy. Direct tables compare `tenant_id` with `app.tenant_id`; receipt/dead-letter policies derive tenant ownership from their outbox row. Missing tenant context yields no rows.

Five pre-provisioned roles are required: API, Worker, command service, release operator and observer. All are `NOLOGIN`, `NOINHERIT`, `NOSUPERUSER`, `NOCREATEDB`, `NOCREATEROLE` and `NOBYPASSRLS`. PUBLIC table/default grants are revoked. API, Worker and observer receive only their documented Runtime privileges; the release operator has Behavior access and no Runtime table grant.

## Enable, disable, degrade and first look

- Enable locally by provisioning the fixed test principals and applying Alembic through `p03_007_runtime_rls` in an isolated database.
- There is no application traffic switch in Phase 3. Keeping Agent API/Worker undeployed leaves the new path inactive.
- On migration or restore failure, stop new Workers, preserve the database/snapshot, and forward-fix. Never disable FORCE RLS, broaden grants, reset migration history or replace PostgreSQL truth with memory.
- First inspect the Alembic revision, tenant context, policy/forced-RLS counts, role attributes, state/version, Event sequence, fencing token and outbox receipt. Then run the affected Phase 3 gate or restore rehearsal.

Formal production schema ownership, backup storage, RPO/RTO, deployment permissions, reviewer receipts and rollback authorization remain pending external owner decisions.
