# Phase 12 change summary

This cycle selects only P12A Structured Memory and keeps the runtime Single-Agent. P12B, P12C, and
P12D remain dormant for new work.

## What changed

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

Affected P12A tests passed 65/65. The single P12A-990 full regression passed 15 CI suites, 895 unit,
255 contract, 124 Flutter, and 53 isolated PostgreSQL/fault tests, with zero failures, skips, or
xfails. Real PostgreSQL proved seven FORCE RLS tables, an authorized principal seeing one row, a
wrong principal seeing zero, and formal Worker update denial.

The first full-regression wrapper timed out after its output channel closed. A later concurrent
historical certification run caused one PostgreSQL deadlock during contract teardown; the failure
was retained, the shared-role fixture was isolated, and the ordered affected probe passed 7/7 before
the final clean regression. No threshold, test, or negative result was suppressed.

## Boundary

All evidence is local controlled mechanism evidence. Production schema, RLS/grants, triggers,
backups, traffic, data, user consent, and outcome improvement remain unknown. Production allocation,
production writes, remote pushes, and Multi-Agent implementation are zero.
