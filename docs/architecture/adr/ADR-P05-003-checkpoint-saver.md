# ADR-P05-003: LangGraph-compatible PostgreSQL checkpoint saver

- Status: local provisional decision; formal Security and Data approval pending
- Date: 2026-08-01
- Owners: AgentPlatform, Security, Data
- Scope: Phase 5 durable checkpoint persistence only

## Context

`TASK-P05-003` requires a PostgreSQL saver compatible with the repository's locked LangGraph version. At task entry, `agent-service/pyproject.toml` and `agent-service/uv.lock` contained no LangGraph package, so no version could honestly be described as locked. The task allowlist also omitted those dependency files. This is recorded in `BLK-P05-003-langgraph-lock-gap.md` and repaired as a separate, reversible enabler before checkpoint implementation.

The repository already owns tenant-scoped Run, Job, Lease and checkpoint metadata in Alembic migrations. Checkpoint writes must preserve current fencing, avoid secret/client/raw-body persistence, remain reproducible from migrations, and use PostgreSQL as the fact source.

LangGraph documents `BaseCheckpointSaver` as the saver interface and packages PostgreSQL support separately. The official PostgreSQL saver requires its own setup-managed tables and Psycopg connection semantics. The current GoNow runtime instead requires Alembic-owned schema, tenant identity and the existing Job fencing trigger.

## Decision

1. Lock `langgraph==1.2.9`, a non-yanked LangGraph v1 release available on the review date. The lockfile and supply-chain evidence bind the resolved transitive graph/checkpoint packages.
2. Implement `GoNowPostgresCheckpointSaver` as a synchronous `BaseCheckpointSaver` adapter over the existing SQLAlchemy/PostgreSQL transaction boundary.
3. Add only Alembic-owned payload and pending-write tables. Existing `checkpoint_metadata` remains the authoritative tenant/run/job/fencing reference chain.
4. Persist strict canonical JSON only. Pickle fallback, arbitrary module reconstruction, secrets, clients, connections, raw Prompt/Tool bodies and reasoning are rejected before any database write.
5. Bind every write to `tenant_id`, `run_id`, `job_id`, current lease holder and fencing token. An expired or stale worker receives `consistency.stale_fence` and creates no checkpoint payload or metadata row.
6. Version the stored envelope independently from LangGraph package versions. Reads support the initial envelope and one explicit prior-version upgrade fixture; unknown versions fail closed.
7. Use the adapter through the LangGraph v1 saver protocol in integration tests. Release B does not invoke third-party `setup()` DDL and does not add Redis.

## Alternatives considered

| Option | Safety/data fit | Compatibility | Cost/rollback | Decision |
|---|---|---|---|---|
| Official `langgraph-checkpoint-postgres` | Mature implementation, but setup-managed unqualified tables do not encode GoNow tenant/job fencing or repository Alembic ownership | Native | Adds Psycopg boundary and a second migration mechanism | Not selected for Release B |
| GoNow PostgreSQL saver implementing `BaseCheckpointSaver` | Preserves tenant, fencing, strict JSON and Alembic ownership | Verified against locked LangGraph v1 protocol | Small adapter; revert migration and dependency enabler | Selected |
| Internal interface with no LangGraph package | Safe locally but cannot prove the task's version-compatibility assertion | Unproven | Lowest dependency cost | Rejected |
| Redis/in-memory saver | Violates PostgreSQL fact-source and durable recovery constraints | Irrelevant | Creates another truth source | Rejected |

## Consequences and controls

- A new direct dependency and its transitives are exactly locked, audited, licensed and included in the task supply-chain evidence.
- The adapter is intentionally synchronous because the current Worker entry point is synchronous. An async boundary would require a later ADR and independent transaction tests.
- The app-specific schema is not wire-compatible with the official PostgreSQL saver; compatibility means conformance to the locked LangGraph saver protocol, not interchangeability of database tables.
- Formal owner approval remains required before merge, push, production use or acceptance. Local implementation and isolated PostgreSQL evidence remain provisional.

## Rollback

Stop checkpoint-taking workers, preserve the last known compatible checkpoint references, revert the adapter and its Alembic revision, then remove the LangGraph direct pin and regenerate `uv.lock`. Existing Phase 3 Run/Job/Event tables and prior checkpoint metadata remain readable after the isolated downgrade proof.

## Evidence sources

- [LangGraph persistence and BaseCheckpointSaver](https://docs.langchain.com/oss/python/langgraph/persistence)
- [LangGraph v1 release contract](https://docs.langchain.com/oss/python/releases/langgraph-v1)
- [LangGraph 1.2.9 package record](https://pypi.org/project/langgraph/1.2.9/)
- [Official PostgreSQL saver package record](https://pypi.org/project/langgraph-checkpoint-postgres/3.1.0/)
