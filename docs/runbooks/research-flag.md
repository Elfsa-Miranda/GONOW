# Research experiment flag runbook

Scope: Phase 8 local provisional research branch. Production activation is not authorized.

## Normal state

The expected state is feature off, active cohort false, and zero research calls. Requests continue
through the Phase 7 route and return the same bytes. Offline, replay, and shadow are the only typed
experiment modes; none authorizes a domain write.

## Enable for an authorized local exercise

1. Confirm the exact Phase 8 contract, budget, merge, router, and experiment tests pass.
2. Select only offline, replay, or shadow mode; keep active cohort false.
3. Use a typed read-only request and a synthetic or otherwise approved non-production fixture.
4. Record physical attempts per branch, the shared Run allocation, source references, decision
   digest, and kill-switch state without recording payload text, Prompt, secret, or reasoning.
5. Compare the disabled output with the Phase 7 byte digest before and after the exercise.

## First checks on degradation

1. Engage the kill switch or leave the feature off.
2. Confirm the next request makes zero research calls and matches the Phase 7 output bytes.
3. Validate request kind, schema version, read-only permission, and absence of forbidden fields.
4. Inspect the per-Run ledger: at most two branches and at most four physical attempts per branch.
5. Recompute the canonical merge digest and verify that all conflicting source references remain.
6. Inspect only stable codes, counts, hashes, durations, and redacted receipts.

## Decision and recovery gate

The current decision is `none`; do not create or activate a Multi-Agent P12C package from the
synthetic result. Reconsider only after a new pre-registration and qualifying evidence exceed the
strict quality threshold while satisfying latency, cost, safety, privacy, and sample gates. Formal
owner approvals are additionally required for production activation.

## Rollback

Keep the flag off or use the kill switch and prove Phase 7 byte equality. Package rollback removes
only Phase 8 research modules, fixtures, and derived evidence. It does not alter Phase 7 behavior,
database schema, or production data.
