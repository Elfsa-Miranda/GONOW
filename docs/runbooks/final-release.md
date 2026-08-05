# Final repository candidate operations

## Purpose and authority

This runbook covers repository publication and local validation. It does not authorize production
deployment, traffic allocation, credentials, production database access or data writes. The only
remote publication path is the exact `codex/gonow-agent-landing` head through one protected pull
request to `main`, using a normal merge commit after required checks pass. Direct main push, force,
squash/rebase merge and bypassing checks are prohibited.

## Before publication

1. Confirm the worktree is clean and the frozen GONOW-990 candidate OID/tree matches its attestation.
2. Confirm P12D, P12B and P12A are the only selected Phase 12 capabilities, P12C is dormant and the
   architecture is Single-Agent.
3. Confirm the one full-project regression has zero failures, skips, xfails and redline failures,
   and that no model API or production write occurred.
4. Merge the exact candidate into landing with `--no-ff`, prove parent and tree equality, then run
   the single pre-PR focused smoke.
5. Compare the remote landing ref with the recorded expected OID before a non-force push. Reuse an
   existing matching PR or create exactly one ready PR from landing to main.
6. Wait for required checks. Merge only with the normal merge method, then run the single post-main
   focused smoke and save the external final receipt.

## Runtime degradation

Keep P12A, P12B and P12D default off unless a separately approved production rollout exists. If
identity, consent, authorization, cost, schema, RLS, restore or lifecycle evidence is missing or
ambiguous, disable the new route and preserve the earlier Single-Agent behavior. Do not fall back to
client-side model credentials or accept untyped model output as formal data.

For Structured Memory, a kill switch disables proposals and read materialization. It must not delete
audit history, outbox entries or tombstones, and must not turn a conflicted, expired, revoked or
deleted record back into an active fact.

## Memory incident and deletion/restore procedure

1. Stop new Memory proposal/read allocation with the feature flag or kill switch.
2. Preserve tenant, principal, purpose, consent version, record version, idempotency key and outbox
   identifiers; never copy Memory values into general logs.
3. Treat missing/expired/revoked consent, identity ambiguity and tenant/principal mismatch as deny.
4. For a conflict, retain both values and provenance as user-visible claims; require an authorized
   resolution with the expected version.
5. For delete or consent withdrawal, verify a durable tombstone and fan-out receipts for the formal
   record, Candidate, index, cache, export, evaluation trace and restore ledger.
6. During restore, load consent and tombstones before materializing records or opening read aliases.
   Reject any restored generation whose deletion identity is tombstoned.
7. Re-enable only after affected authorization, RLS, conflict, deletion/export/restore and legacy
   compatibility tests pass. Production re-enable also requires production owner evidence; local
   fixture success is insufficient.

## Software rollback

Rollback routes requests to the prior compatible Single-Agent path and leaves durable state intact.
Use a new non-force revert pull request for an already merged repository change. Do not rewrite Git
history, downgrade production schema, delete outbox/audit rows, remove tombstones or restore revoked
consent. If the production database shape or backup topology is not proven, keep its status unknown
and do not execute database actions.

## Evidence to retain

Retain exact candidate/merge OIDs, tree OIDs, report hashes, raw counts, failure classifications,
required-check conclusions, focused smoke receipts, rollback description and production-write/traffic
counters. Preserve historical failures and unknowns; never convert a fake, fixture, isolated
PostgreSQL run or local result into a production claim.
