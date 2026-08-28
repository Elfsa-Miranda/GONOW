# Phase 12A local provisional acceptance candidate

- Candidate: `d264ff751d67f089663c0c9f9e5e0594d0003ba4`
- Phase base / landing at selection: `3a2ea2f675e419d0c5b5d1ad71a5cf00f16cf104`
- Selection: P12A only; P12B, P12C and P12D are dormant for this cycle.
- Architecture: Single-Agent only. No coordinator, specialist agent, model call, tool execution port or production allocation was added.
- Status: `ready_for_review` local provisional. Formal acceptance remains pending an independent reviewer and governance authority.

The original gap was that GoNow had no explicit, typed, user-visible Memory contract. Unstructured chat history, inferred profiles and model output therefore had no safe path to become durable personalization data. P12A adds four closed-enum user-declared facts for the sole purpose `itinerary.personalization`: travel pace, mobility requirement, dietary requirement and transport preference. Free text, transcripts, hidden profiles and model-inferred facts are forbidden.

A model or UI may create only a Candidate. A formal Memory record requires current purpose-matched consent, an unambiguous tenant/principal identity, server authorization, explicit user confirmation, CAS, idempotency and an atomic outbox receipt. Missing, denied, revoked or expired consent; purpose mismatch; tenant/principal mismatch; conflict; quarantine; or deletion all fail closed. Competing values preserve both provenance chains and become user-visible conflict state instead of silently overwriting.

Deletion and consent withdrawal use the same tombstone-first path across the primary record, Candidate, index, cache, export, eval trace and restore ledger. Restore checks the tombstone before materialization, so a backup cannot silently revive deleted Memory. Runtime reads are default-off behind one Single-Agent port; the kill switch returns the old path without deleting audit or tombstone evidence.

The completed candidate regression passed 15/15 service gates, 895 unit tests, 255 contract tests, 124 Flutter tests and 53 isolated RealPG/fault tests, with zero failures, skips or xfails. The affected Memory lifecycle passed 65/65 tests, including 12 frozen scenarios and Real PostgreSQL checks showing seven Memory tables with FORCE RLS, zero wrong-principal visibility and denied worker formal updates. No model API or production write was used.

Two earlier attempts remain negative evidence. The first lost its output channel and exited unit with code 120, so it is incomplete. The second ran concurrently with a pre-existing landing certification on the same loopback PostgreSQL port, producing a database deadlock/transient RLS failure; the same ordered probe passed 7/7 after the competing process ended. The Memory fixture was also tightened to create and remove only roles it owns.

This proves local contracts, isolated PostgreSQL mechanics, legacy-path compatibility and rollback behavior. The production trigger, schema, grants/RLS deployment, real user consent state, retention operations, backup topology and product value remain `unknown`; no production-improvement claim is made.
