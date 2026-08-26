# STAR: deterministic Context overflow recovery

Claim type: `mechanism_validation`

## Situation

The staged itinerary runtime had a fixed one-call Context budget. It could omit evidence safely, but it had no deterministic recovery ladder for large authorized evidence, no progressive-disclosure handle contract, and no bounded way to generate a 31-day itinerary without either overflowing one prompt or emitting a partial Candidate.

## Task

Add reproducible Context compaction, bounded segmentation, global validation, explicit clarification, safe observability, and a default-off production gate while preserving tenant authorization and the rule that only a globally valid result becomes a Candidate.

## Action

- Added explicit provenance-driven supersession, content-digest deduplication, and exact-sentence-span extraction with auditable source offsets, token counts, transform logs, and a stable decision digest. The runtime never infers “latest” from hashes or provider order.
- Represented omitted evidence with content-addressed handles; rehydration re-runs authorization and verifies source digest and Claim identity before returning evidence.
- Added deterministic contiguous day segmentation capped at five calls, with aggregate budget preflight, a global Task Contract digest, absolute day boundaries, deterministic global item IDs, exact coverage checks, Claim-authority checks, and one final business validation.
- Kept every segment output non-authoritative in memory; a segment failure stops before VALIDATE/COMPLETE and no Candidate reaches the durable executor.
- Routed unrecoverable segment count or token budget to the existing typed `MissingInfoInterrupt`; the durable worker transitions RUNNING to WAITING_INPUT, completes the source Job, releases its lease, and persists no Candidate.
- Added bounded `compacted` and `needs_clarification` telemetry without prompt, evidence, tenant, Run, or user labels. The full recovery stack is default-off and requires both the exact Context policy and stage runtime gates.

## Result

The 31-day mocked-provider journey passed with five contiguous calls, days 1–31 exactly once, globally unique item IDs, a six-stage parent trace, and one globally validated Candidate. The injected-evidence case remained quoted as untrusted data in every segment, while a Claim from omitted evidence was rejected. Segment failure, insufficient aggregate budget, excess segment count, invalid supersession, denied rehydration, and stale rehydration all failed closed. The focused matrix passed 52 tests (6 recovery units, 6 overflow integrations, 32 regressions, and 8 E0 evaluations); the non-database unit and contract partitions passed 322 and 226 tests respectively.

This is a local deterministic mechanism and mocked-provider integration claim. The durable WAITING_INPUT test is collected but could not execute because the required PostgreSQL/pgvector toolchain is unavailable. No online latency, production reliability, or complete full-suite claim is made.
