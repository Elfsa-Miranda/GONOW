# BLK-P09-006: production itinerary mapping and RLS are not reproducible

What was observed: the pinned repository does not contain reproducible DDL, RLS, grants, or an approved column mapping for the production `user_itineraries` and itinerary-activity tables. The only safe local proof therefore uses an isolated PostgreSQL fixture schema and an explicitly injected table adapter.

Blocked action: binding `TASK-P09-006` to production business tables, performing a production write, or calling the production adoption path validated is blocked. Typed Candidate creation, the transaction implementation, isolated PostgreSQL tests, Flutter transport code, rollback checks, and local evidence remain ready.

## Status

- Severity: P1 for formal production adoption; no current production, secret, or cross-tenant incident is asserted.
- Local status: `mitigated_fail_closed`.
- Formal status: `pending_owner_inventory_and_approval`.
- Owners: Data + Security + Product.
- Implementer: Backend + Mobile.
- First recorded: 2026-08-02 (Asia/Shanghai).

## Reproduction and evidence boundary

1. Inspect the pinned repository migration history and current Phase 9 inputs.
2. Confirm that no repository-owned migration defines the production itinerary and activity tables or their RLS/grant contracts.
3. Confirm that `p09_006_domain_commands.py` creates only approval/receipt metadata and does not guess or alter those unknown business tables.
4. Confirm that `test_domain_command_outbox.py` creates `p09_006_domain_fixture.user_itineraries` and `p09_006_domain_fixture.itinerary_activities`, then injects those `Table` objects into the repository.

This proves local transaction behavior against a real task-owned PostgreSQL instance. It does not prove the production table names, columns, keys, policies, grants, retention rules, or deployed state.

## Root cause and impact surface

The repository baseline lacks a read-only production schema inventory and approved adapter contract. Guessing the schema would risk incorrect CAS predicates, cross-tenant access, data loss, or an incompatible production migration. The impact is limited to formal production binding and deployment. The typed command/hash/capability boundary, one-transaction approval consumption, isolated target CAS, Event/outbox write, replay behavior, Flutter request body, and local rollback behavior remain independently testable.

## Complete reversible repair

1. Data owner exports a read-only, redacted inventory of the exact production itinerary/activity tables, columns, constraints, triggers, indexes, RLS policies, grants, and relevant function definitions, with immutable locator and hash.
2. Security and Product confirm tenant/principal ownership, delete/retention semantics, and the intended Candidate-to-domain mapping.
3. Engineering records the approved mapping and any public-schema/RLS change in the required ADR before implementation.
4. Implement a production adapter without changing the strict command body, approval binding, CAS, or transaction/outbox invariants.
5. Run tenant-isolation, stale-version, forged-capability, replay, transaction-failure, backup/restore, and rollback tests against an authorized non-production clone.
6. Only after independent approval may the production adapter be enabled; formal adoption remains default-off until then.

## Rollback and recovery conditions

Rollback keeps the adoption feature flag off and retains Candidate preview/import behavior; the isolated adapter and metadata migration can be removed without touching unknown business tables. Recovery requires the immutable inventory, approved ADR, exact production adapter, RLS/grant diff, authorized non-production regression evidence, and independent Data/Security/Product decisions. This blocker must not be interpreted as permission to write production data or as evidence that production RLS is absent.
