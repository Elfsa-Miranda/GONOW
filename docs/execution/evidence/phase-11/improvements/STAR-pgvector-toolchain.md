# STAR: reproducible pgvector toolchain

## Situation

The baseline Phase 11 vector migration probe had a denominator of 1 required real PostgreSQL migration and passed 0/1 because the locked PostgreSQL 17 distribution did not contain `vector.control`. This was an environment dependency failure, not a schema assertion failure.

## Task

Supply the exact missing extension without changing production state, lowering a gate, using a fake vector type, or skipping the real migration. Preserve a reversible isolated installation and record version/hash evidence.

## Action

Installed pgvector 0.8.1 from locked commit `778dacf` into `D:/GO_NOW-toolchain/pgvector-pg17/Library`, selected that PostgreSQL binary root for the isolated cluster, and reran the full Alembic chain plus P11-008 restore/deletion probes. The verification command was the task-owned PostgreSQL provisioner followed by Alembic upgrade and the affected pytest suites; no production endpoint was used.

## Result

- baseline: real vector migration success 0/1.
- candidate: real vector migration success 1/1.
- denominator: one required clean PostgreSQL 17 migration chain.
- guardrail: tenant leaks 0, resurrection failures 0, production writes 0.
- installed `vector.dll` SHA-256: `ca9408a02e17d60af7b7c9c15c61b7a9a5fd6c746265402035816879ec38be80`.
- candidate code checkpoint SHA-256 binding: Git commit `5ee7446` (`repair(REPAIR-P11-PGVECTOR-CI-001)`).

This is a reproducibility improvement, not a claim about production query quality or traffic.
