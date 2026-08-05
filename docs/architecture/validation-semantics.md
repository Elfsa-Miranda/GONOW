# Validation semantics operational overview

Status: local provisional Phase 1 candidate. The normative contract is
[`validation-semantics-v1.md`](validation-semantics-v1.md) and its canonical machine schema is
`contracts/validation-semantics-v1.schema.json`. Formal Product and Security approval is pending.

## Observable behavior

Every validation result has exactly one overall class: `hard`, `warning`, `unverified`, or
`verified`. Precedence is deterministic (`hard > warning > unverified > verified`), while all
lower-precedence findings remain visible. A Candidate remains importable as a clearly labelled
draft in every class, including `hard`; import never means a formal itinerary or diary write.

## Enable and disable

Phase 1 adds a contract and synthetic fixtures only. It does not add a runtime feature switch or
change existing Flutter traffic. The future itinerary-planning seam is
`FlutterAgentPlanningService` behind `agent_itinerary_planning_v1`, default `false`, as frozen in
`contracts/flutter-agent-boundary-v1.yaml`.

To disable the future path, set that flag to `false` for new Runs. Do not remove the old chat,
manual import, Auth, or fallback paths. Existing Runs are not reassigned by a flag change and must
follow the later durable recovery contract.

## Degraded behavior

Parser or schema failure fails closed for formal writes and preserves the original input as a raw
local Candidate. Missing evidence yields `unverified`; it is never guessed into `verified`.
Normalization failure keeps the original content. No degraded branch may restore a client model
credential, claim a cloud write, or set `domain_write_allowed=true`.

## First checks

1. Confirm the result validates against `contracts/validation-semantics-v1.schema.json`.
2. Confirm the visible overall class matches the finding precedence and no finding was erased.
3. Confirm Candidate import retains the original input and both formal-write fields remain false.
4. Run `flutter test test/validation_semantics_test.dart` from the repository root.
5. If the future service seam is involved, confirm `agent_itinerary_planning_v1=false` restores the
   compatibility-only state without enabling direct provider access.

## Known limits

This phase does not implement `agent-api`, `agent-worker`, durable Runs, Domain Commands, CAS,
outbox, or production database policy. Production schema/RLS/grant facts and independent approvals
remain unknown or pending and cannot be inferred from this local contract.
