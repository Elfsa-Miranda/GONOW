# GoNow final repository architecture and evidence boundary

## Status and scope

This document describes the final repository candidate, not a production deployment. The selected
Phase 12 set is exactly P12D Domain Command, P12B Cost Router and P12A Structured Memory. P12C remains
dormant. The runtime remains one Agent codebase with `agent-api` and `agent-worker`; no coordinator,
specialist Agent, Multi-Agent allocator, Redis recovery authority or dynamic MCP marketplace was
added.

Repository acceptance uses the personal automated governance profile bound to exact Git objects and
hashed evidence. It authorizes the protected landing-to-main publication workflow only. It does not
authorize production deployment, traffic allocation, credentials, database writes or a claim that
production behavior improved.

## Capability map

| Area | Repository candidate | Production boundary |
|---|---|---|
| Client and gateway | Client model secret removed; server boundary, typed errors and legacy fallback are implemented. | Gateway deployment, credential revocation and real traffic remain unknown/pending. |
| Runtime | Typed Single-Agent state, durable jobs, leases, checkpoint, fencing, events, outbox and SSE recovery are implemented. | Production schema, roles, triggers, clock and recovery topology remain unknown. |
| Candidate and write path | Models and tools can produce typed Candidates; formal domain mutation uses server authorization, CAS, idempotency and outbox. | No production write or traffic allocation was performed. |
| RAG | Typed, provenance-aware local retrieval and deletion/rollback mechanics are preserved from the accepted repository path. | Production corpus, grants, indexing and relevance benefit remain unknown. |
| P12D | One controlled Domain Command path is accepted and default off. | Production allocation is zero. |
| P12B | Deterministic Cost Router contract and local evidence are accepted. | Historical provider calls/cost are preserved as observations; positive benefit is not claimed. |
| P12A | Explicit Structured Memory is accepted and default off. | Real consent, production data, backups, traffic and outcome improvement remain unknown. |
| P12C | Dormant. | No Multi-Agent runtime or allocation exists. |

## Structured Memory data and permission model

Memory is not chat history and is not a hidden user profile. It supports exactly four closed enum
facts for the sole purpose `itinerary.personalization`: `travel_pace`, `mobility_requirement`,
`dietary_requirement`, and `transport_preference`. Each formal fact is user-visible and binds tenant,
principal, purpose, consent version and expiry, provenance, record version, retention (at most 365
days), and stable deletion identity.

A model may propose a typed Candidate only. A formal write requires explicit user confirmation,
verified identity, current purpose-matching consent, server authorization, compare-and-swap,
idempotency and an atomic outbox receipt. Missing, expired, revoked or purpose-mismatched consent;
unknown identity; tenant/principal mismatch; quarantine; expiry; conflict; or deletion fails closed.
Tenant membership alone is not authority. The Worker cannot directly mutate formal Memory.

Competing values enter a visible conflict state and never silently overwrite each other. Retrieved
Memory is untrusted data: it cannot grant permission, change instructions, invoke tools or create
another Memory. The default-off Single-Agent read port materializes only active, unexpired,
authorized typed facts.

## Retention, export, deletion and restore

Export repeats the same identity, tenant, purpose and consent checks and exposes only the principal's
active records. It excludes prompts, reasoning, secrets, internal audit details and other tenants.

Deletion and consent withdrawal create durable tombstones and fan out to the formal record,
Candidate, index, cache, export, evaluation trace and restore ledger. Restore loads consent and the
tombstone ledger before opening read aliases. A disabled flag or software rollback never removes a
tombstone or reactivates a deleted generation; therefore a backup cannot legitimately resurrect
deleted or consent-revoked data.

## Degradation and rollback

All new Phase 12 paths are default off. The first response to an uncertain consent, identity,
authorization, cost or data-lifecycle state is to disable proposal/read routing and return to the
previous Single-Agent/Release B compatible path. State, audit, outbox and tombstones remain intact.
Rollback is a reversible routing/configuration action; it is not a database downgrade and never
permits direct client model fallback.

## Evidence and test boundary

The repository evidence proves typed contracts, authorization decisions, isolated PostgreSQL RLS,
CAS/idempotency/outbox behavior, conflict handling, export, deletion and restore mechanics, failure
injection, rollback and old-path compatibility without model API calls. Preserved Phase 12 evidence:

- P12B: 15 CI gates, 830 unit, 233 contract, 124 Flutter and 53 RealPG/fault tests; post-landing
  focused smoke 98/98.
- P12D: 15 CI gates, 736 unit, 183 contract, 124 Flutter and 52 RealPG/fault tests; integration smoke
  74/74. A historical test-manifest drift was revalidated as 2/2 with zero unresolved drift.
- P12A: 15 CI gates, 895 unit, 255 contract, 124 Flutter and 53 RealPG/fault tests; post-landing
  focused smoke 65/65.

All cited accepted runs preserve zero failures, skips and xfails. These are local fixtures and
isolated PostgreSQL results, not production conclusions. Actual production schema, RLS, grants,
triggers, consent inventory, backup restore path, traffic, latency, provider bills, user outcomes and
operational readiness remain `unknown/pending` until separately observed and authorized.

## Canonical handoff

- Phase 12 selection and Memory contract: `docs/architecture/release-c-selection.md`
- Structured Memory operations: `docs/runbooks/structured-memory.md`
- Final operations: `docs/runbooks/final-release.md`
- Cumulative Phase 12 evidence: `docs/execution/evidence/phase-12/P12-089/`
- Release C repository evidence: `docs/execution/evidence/releases/REL-C-001/`
- Final project archive: `docs/execution/evidence/project-final/GONOW-089/`
