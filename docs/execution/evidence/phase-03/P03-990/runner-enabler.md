# TASK-P03-990 runner and rollback-fixture enabler

## Reproduction

Static dispatch inspection showed that all P03-990 mandatory modes were registered in `TaskGateCatalog.psd1`, while the shared handlers for AcceptancePreflight, ApprovalValidation, BuildAcceptance, Regression, RollbackDrill, Documentation, Security, Evidence, RollbackVerify, and Verify stopped at P02-990 and otherwise returned the generic pending result. The Phase 3 card also required idle, three in-flight Run, and old-reader/new-schema rollback scenarios, but no single replayable fixture exercised all three.

## Root cause and impact

The catalog was generated before the phase-specific local-provisional aggregators and rollback fixture existed. Running the task unchanged would record an implementation gap as a task failure and could not distinguish local mechanical evidence from formal reviewer/production-only evidence. The gap affected only P03-990 acceptance assembly; completed P03 implementation gates and production systems were unaffected.

## Reversible repair

- Add P03-only aggregation functions that consume immutable task status, DDL/RLS/CAS/restore reports, Harness Catalog state, and carried CT-003/004 evidence.
- Keep independent Engineering/Security/SRE approval, production inventory, measured RPO/RTO, formal merge, push, migration, and production write explicitly pending.
- Add an isolated PostgreSQL fixture with three tests: idle state, exactly three persisted in-flight Runs, and a reconnecting stable-column reader over the new schema.
- Bind all eight forced-rejection counters and seven applicable CT results without creating approval receipts.

No production implementation or migration changed. Rollback is a revert of this enabler commit; the test drops only its task-owned local schemas and roles in `finally` cleanup. Recovery requires parser success, three focused tests with zero failure/skip, shared runner contract success, and the later full P03-990 regression.
