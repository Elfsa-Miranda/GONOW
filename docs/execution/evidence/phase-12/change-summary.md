# Phase 12 change summary

This close aggregates the already implemented P12D Domain Command, P12B Cost Router, and P12A
Structured Memory packages while keeping the runtime Single-Agent. P12C remains dormant and no
fourth capability is selected.

## What changed

- P12D added one default-off typed Basic Info Domain Command with tenant/principal authorization,
  FORCE RLS, CAS, idempotency, fencing, atomic outbox, legacy bypass, and a reversible kill switch.
- P12B added a deterministic, default-off itinerary Cost Router and append-only cost ledger with
  local schema/business validation, bounded one-hop fallback, allocation zero, and no positive
  benefit claim because a qualified paired Gemini live baseline is unavailable.
- Added four closed, typed, user-visible Memory types for itinerary personalization; free text,
  transcripts, hidden profiles, and model-inferred traits are forbidden.
- Added explicit consent, tenant/principal, purpose, provenance, retention, version, and deletion
  identities.
- Added Candidate-only proposal and a formal write chain requiring user confirmation, server
  authorization, CAS, idempotency, and atomic outbox.
- Added seven internal PostgreSQL tables with FORCE RLS tenant/principal isolation and least grants.
- Added deterministic conflict preservation, poisoning defenses, user-scoped export, tombstone-first
  deletion/consent withdrawal, and backup resurrection prevention.
- Added a default-off Single-Agent Memory read port and kill switch. No coordinator, specialist
  Agent, model API call, new process, or public client contract was added.

## Verification

P12D preserved 15 CI, 736 unit, 183 contract, 124 Flutter, and 52 RealPG/fault passes; its one later
test-only manifest drift was revalidated 2/2 on isolated PostgreSQL. P12B preserved 15 CI, 830 unit,
233 contract, 124 Flutter, and 53 RealPG/fault passes plus a 98/98 focused smoke. Affected P12A tests
passed 65/65. The single P12A-990 full regression passed 15 CI suites, 895 unit,
255 contract, 124 Flutter, and 53 isolated PostgreSQL/fault tests, with zero failures, skips, or
xfails. Real PostgreSQL proved seven FORCE RLS tables, an authorized principal seeing one row, a
wrong principal seeing zero, and formal Worker update denial.

The first full-regression wrapper timed out after its output channel closed. A later concurrent
historical certification run caused one PostgreSQL deadlock during contract teardown; the failure
was retained, the shared-role fixture was isolated, and the ordered affected probe passed 7/7 before
the final clean regression. No threshold, test, or negative result was suppressed.

## Boundary

These are separate frozen candidate runs and are not added into a cross-phase performance claim.
All evidence is local controlled mechanism evidence. Production schema, RLS/grants, triggers,
backups, traffic, data, user consent, and outcome improvement remain unknown. Production allocation,
production writes, direct main pushes, force updates, and Multi-Agent implementation are zero.
