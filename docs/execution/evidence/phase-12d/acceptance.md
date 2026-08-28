# Phase 12D local provisional acceptance candidate

Local status: `ready_for_review`. Formal acceptance, production allocation,
remote push, and any merge to `main` remain prohibited. The only next local
integration action is the approved P12D-999 merge into
`codex/gonow-agent-landing` after global TASK-P12-089.

- Phase base OID: `eab09d679a0cfd01e639dbc16bdc19a27dae5cb2`
- Candidate head OID: `88c538b1461be6a825d77dbd636b828767e8e898`
- Selected candidate: `P12D`
- Selected write entry:
  `flutter:ItineraryProvider.updateItineraryBasicInfo:user_itineraries`

## Scope

One typed Basic Info Domain Command, additive command attempt/receipt/outbox
persistence, tenant-scoped authorization and FORCE RLS, atomic CAS mutation,
idempotent replay and fencing, deterministic fault injection, a default-off
Flutter route, retained legacy bypass, and a reversible kill switch. The
architecture remains Single-Agent; no Multi-Agent framework was added.

## Mechanical result

- CI: 15/15 gates; 736 unit and 183 contract tests passed.
- Flutter: 124 tests passed.
- P12D RealPG/fault profile: 52 tests passed.
- Failed, skipped, and xfailed: 0.
- Duplicate formal writes, unauthorized/cross-tenant writes,
  mutation/outbox divergence, unrecoverable committed outcomes, and data loss:
  0.
- `main` and `origin/main` remain
  `142abfc339f003ede8d85d9534336923b5610252`.

## STAR and evidence boundary

The preregistered controlled stale-conflict profile used 10,000 legacy intents
and 10,000 candidate intents with identical input hash and seed. The observed
rate was 10,000/10k for the tracked legacy ordering and 0/10k for the Domain
Command candidate. This is a local controlled mechanism result only.

Production traffic distribution, production incident rate, and equivalence to
the production schema remain `unknown`; production measurement remains
`measurement_pending`. No production improvement is claimed, and synthetic
fault injection is not represented as production evidence.

## Formal gaps

- independent owner/reviewer acceptance: pending external;
- valid governance adoption receipt for formal merge/push/production:
  pending external;
- production schema/RLS inventory and production measurement window: pending;
- production allocation: 0%;
- production writes: 0;
- remote pushes: 0;
- merges to `main` or `origin/main`: 0.
