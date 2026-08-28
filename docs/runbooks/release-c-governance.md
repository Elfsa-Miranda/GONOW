# Release C governance and rollback runbook

## Current safe state

`selected_candidate=12A`, `selected_count=1`, and
`formal_selection_status=local_provisional_selected`. Structured Memory is implemented only in the
local P12A branch, is default off, and has zero production allocation and writes. P12B, P12C, and
P12D are dormant for new work. The runtime remains Single-Agent.

## First checks

1. Bind the exact candidate Git object ID and verify the worktree and status records.
2. Confirm the type is one of the four closed Memory types and the purpose is exactly
   `itinerary.personalization`; reject free text, transcript, hidden profile, or inference payloads.
3. Verify authenticated tenant and principal, current purpose-specific consent, consent version and
   expiry, provenance, retention, record version, and idempotency key.
4. For a write, verify Candidate status, explicit confirmation, server authorization, expected CAS
   version, atomic receipt, and outbox event. The Worker must not directly write formal Memory.
5. For a read or export, verify the same tenant/principal/purpose boundary and FORCE RLS context.
6. For a conflict, preserve both claims and provenance; never select a winner silently.
7. For delete or consent withdrawal, inspect the tombstone and all seven covered surfaces before any
   restore: record, Candidate, index, cache, export, eval trace, and restore ledger.

## Enable, disable, and degrade

There is no local command that authorizes production enablement. Future enablement requires approved
production schema/RLS/grant evidence, privacy and data approval, real deletion/export/restore drills,
monitoring, rollback ownership, independent review, and rollout authority.

To disable, set Memory allocation to zero, turn off proposals and the Single-Agent read port, and
activate the Memory kill switch if necessary. The prior itinerary flow then runs without Memory.
Preserve formal records, audit, receipts, outbox rows, and tombstones for authorized recovery.

If consent, identity, purpose, policy state, or RLS context is missing or ambiguous, fail closed.
Memory unavailability may degrade to the prior no-Memory Single-Agent path; it must not degrade to an
unscoped read, a hidden inference, or a client-side write.

## Deletion and recovery

Deletion and consent withdrawal are irreversible domain decisions even when the feature is rolled
back. Record the tombstone first, fan it out to every derived surface, and verify zero materialization.
During restore, replay the tombstone ledger before restoring any Memory row or index. A backup copy
that conflicts with a tombstone stays suppressed. Re-consent may permit a new record with a new
authorization history; it does not revive the deleted record.

## Failure handling

Use one root-cause loop: preserve the first failing input and environment, reproduce the smallest
case, identify the authorization/RLS/CAS/lifecycle boundary, make the smallest reversible repair,
then run the affected Memory and compatibility tests. Never gain a pass by weakening consent,
changing expected versions, skipping a negative case, dropping FORCE RLS, or deleting failure
evidence.

Production schema, policies, trigger behavior, data quality, backup behavior, traffic, and user
outcomes remain unknown until separately inspected. Missing independent review blocks formal
acceptance and production use, not completed local engineering evidence.

## Merge and audit retention

P12A may land only through a history-preserving local merge into `codex/gonow-agent-landing` after
P12A-990 and P12-089 pass locally. Do not push `main`, deploy, or write production data. Retain exact
candidate and merge OIDs, consent and schema digests, finite denial/conflict codes, deletion and
restore results, regression counts, negative attempts, and artifact hashes. Evidence must contain no
secret, personal payload, prompt/response body, or hidden reasoning.
