# ADR-P03-001: PostgreSQL DBAPI driver for the SQLAlchemy/Alembic runtime

- Status: proposed for local provisional implementation
- Date: 2026-08-01
- Decision owners: Engineering + Security
- Formal approval: pending; this ADR does not authorize push, merge, production use, or acceptance
- Scope: Phase 3 PostgreSQL persistence and migration connection only

## Context

AGENTS.md §3 mandates Python 3.13, SQLAlchemy 2, Alembic, and PostgreSQL as the runtime fact source, but the Phase 2 lock contains no PostgreSQL DBAPI driver. Alembic cannot execute a real PostgreSQL migration without one. The Phase 3 task catalog omitted `pyproject.toml` and `uv.lock`, so this dependency is introduced as a narrow repair/enabler and remains subject to the normal dependency audit.

The selection must work on Windows with Python 3.13 and the isolated PostgreSQL 17 instance, have a compatible known license, remain actively maintained, be supported by SQLAlchemy's PostgreSQL dialect, and be removable without changing stored data.

## Options

### A. pg8000 1.31.5 — selected provisionally

- Safety: pure Python avoids bundled native client libraries; parameterization remains enforced through SQLAlchemy. SQL construction outside SQLAlchemy remains forbidden.
- Data: uses PostgreSQL's protocol and does not change schema, storage, RLS, or transaction semantics by itself.
- Compatibility: PyPI classifies it Production/Stable, Python 3.13 compatible, and SQLAlchemy 2 documents the `postgresql+pg8000` dialect.
- License and supply chain: BSD 3-Clause; exact wheel/sdist hashes are locked from PyPI. Release 2025-09-14 is within the 18-month direct-dependency freshness limit on 2026-08-01.
- Cost: no separate libpq installation or native build. Runtime performance versus native drivers is not yet measured; this is a stated risk for later load qualification.
- Rollback: remove the direct dependency, regenerate the lock, and change only the connection driver. Existing PostgreSQL data and Alembic revisions remain intact.

### B. psycopg 3.3.4 with binary extra — rejected for this provisional choice

- Strong Windows/Python/PostgreSQL support and a native-backed binary distribution.
- The direct package is `LGPL-3.0-only`, outside the repository's current mechanical approved-license set. Adopting it would require an explicit license-policy decision; silently extending the allowlist is prohibited.
- The binary extra also bundles client libraries, increasing provenance and patch-response surface.

### C. asyncpg — deferred

- Suitable for a future measured async hot path and permissively licensed, but would require an async Alembic environment and commits the persistence layer to an async-only driver before Phase 3 has workload evidence.
- Introducing a second driver later is not automatic; it would require its own dependency audit, performance evidence, and ADR update.

### D. invoke `psql` from application code — rejected

- Avoids a Python driver but creates an arbitrary subprocess/SQL-executor boundary, weakens typed transaction handling, and conflicts with the SQLAlchemy/Alembic target line.

## Decision

Use `pg8000==1.31.5` with `SQLAlchemy==2.0.51` and `Alembic==1.18.5` for local provisional Phase 3 implementation. Keep the SQLAlchemy URL and persistence boundary centralized so the driver remains replaceable. This proposed decision becomes eligible for formal merge only after independent Engineering and Security approval of this ADR and the linked supply-chain evidence.

## Consequences and validation

- P03-001 must prove empty PostgreSQL upgrade, inventory review, downgrade/upgrade repeatability, and lock integrity against PostgreSQL 17.
- Later concurrency/load gates must measure whether the synchronous driver meets the approved budget. Failure is a driver-selection signal, not a reason to lower thresholds.
- No production connection string or credential is stored in Git; tests receive an isolated loopback URL from the environment.
- Dependency evidence is under `docs/execution/supply-chain/phase-03/P03-001-enabler/`.

## Rollback

Revert this ADR and the dependency enabler, restore the prior lock, and select another audited driver. Do not delete or rewrite migration history or persisted data. Because the driver is below SQLAlchemy, rollback does not alter public API, Event/State Schema, or database facts.
