# Phase 3 knowledge transfer

## Responsibilities and boundaries

PostgreSQL owns Runtime identity, order, state/version, fencing, immutable Behavior releases and outbox receipts. API/Worker repositories require caller-owned transactions and server-derived tenant context. Phase 3 does not execute a model, Graph, Tool, durable Worker loop, Candidate or Domain Command and does not write production data.

## Dependency choices

The service uses exact-pinned SQLAlchemy, Alembic and pg8000 with PostgreSQL 17. No Redis, external queue or model SDK was introduced. Behavior manifest identity uses RFC 8785 canonical JSON plus SHA-256. Role/RLS setup is migration-controlled after fixed principals are provisioned. The restore rehearsal uses the installed PostgreSQL 17.10 `pg_dump`/`pg_restore` pair and deletes its temporary snapshot after verification.

## Hardest items

1. Preserving one legal winner under real concurrency: 50 same-body requests converge on one Run; two terminal transitions produce one winner; 50 Event writers produce contiguous sequence 1–50.
2. Making RLS fail closed without assuming a conventional database administrator. Test principals are provisioned by the actual isolated-cluster owner, while application roles remain no-login/no-bypass.
3. Rehearsing a forward-only authorization migration: the local sequence snapshots pre-RLS data, upgrades, rejects downgrade, restores into fresh schemas, reapplies migrations and compares the same eight-row logical hash before/after.

## Operations

Start with `docs/architecture/runtime-persistence.md`, then use `docs/runbooks/runtime-migrations.md` and `docs/runbooks/runtime-db-restore.md`. First inspect database identity, Alembic revision, tenant context, policy/grant catalog, state/version, sequence/fence and snapshot/logical hashes. Stop new Workers before a forward fix. Do not disable FORCE RLS, broaden grants, reset history, replace PostgreSQL truth with memory or retry without a new diagnostic signal.

## Estimate and handoff verification

Plan estimates are capacity ranges, not elapsed-time or production SLA claims. The last Phase 3 implementation replay passes 212 Agent unit/integration tests and 44 contract tests, with formatting, lint, type, secret, license, dependency-audit and clock checks green. The implementer can rerun migration, concurrency, RLS and restore journeys locally; independent SRE/Security review, production inventory, RPO/RTO, push, merge, deployment and `accepted` remain pending.
