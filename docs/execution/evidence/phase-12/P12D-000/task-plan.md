# P12D-000 dormant Domain Command task plan

Task: TASK-P12D-000
Selection candidate: 12D
Portfolio mode: dormant_design_ready
Formal dependency status: pending
Formal selection asserted: false
Implementation commit count: 0
Contract change: false
Production write count: 0
Applicable CT: none
Acceptance task: TASK-P12D-990
Merge task: TASK-P12D-999

## Frozen scope

This package completes design and decomposition only. It creates no Domain Command handler, migration,
table, RLS/grant change, outbox publisher, public contract, flag, cohort, specialist ref/worktree, or
production write. One write entry must be named by real approved evidence during TASK-P12D-010; the
current package records `selected_write_entry=none` and does not infer production facts.

## Required design contracts

- One write entry: bind current writer, clients, load/SLA, conflict/duplicate/partial-write evidence,
  authorization, transaction boundary, side effects, recovery, and a positive/negative trigger.
- Principal and approval: server-derived tenant/principal, scoped authorization, explicit versioned
  approval for high risk, expiry/revocation, and fail-closed denial.
- CAS and idempotency: expected version, stable scoped key, semantic retry, mismatch rejection, stale
  conflict with zero partial effect, and fencing.
- Transactional outbox: business mutation/result/outbox in one transaction; durable at-least-once
  delivery, consumer idempotency, bounded retry, dead-letter evidence, and reconciliation.
- Stable receipt: command/version, target/principal digests, approval reference, idempotency digest,
  versions, state, outbox ID, policy/schema digests; no sensitive body.
- Expand-contract rollback: expand first, dual compatibility, bounded cohort, prior-writer bypass,
  data/evidence retention, restore/replay proof, delayed contract cleanup.

## Proposed atomic DAG

Atomic task: TASK-P12D-010
Depends on: accepted Phase 12 XOR selecting 12D
Purpose: bind real evidence and name exactly one legacy write entry with trigger and impact map.
Allowed future change: evidence and selected plan/ADR only; no runtime or schema.
Gate: selected write entries=1; unknown critical side effects=0; trigger decision recorded.
Rollback: retain evidence, select no entry, keep allocation zero.

Atomic task: TASK-P12D-020
Depends on: TASK-P12D-010 positive and approved
Purpose: freeze command, Principal and approval, CAS and idempotency, receipt, errors, compatibility.
Allowed future change: ADR and internal typed contracts named by approved plan amendment.
Gate: client-asserted authority=0; ambiguous retry outcomes=0; public compatibility gaps=0.
Rollback: keep legacy writer authoritative and retire candidate contract digest.

Atomic task: TASK-P12D-030
Depends on: TASK-P12D-020
Purpose: implement expand-only schema, RLS/grants, indexes/functions, backup and restore evidence.
Allowed future change: exact migration/test paths approved by Data and Security.
Gate: cross-tenant allow=0; destructive migration steps=0; restore mismatches=0.
Rollback: leave compatible expansion dormant; route no traffic; preserve data.

Atomic task: TASK-P12D-040
Depends on: TASK-P12D-030
Purpose: implement one handler, atomic mutation plus Transactional outbox, fencing, Stable receipt.
Allowed future change: exact internal service/worker/test paths behind default-off flag.
Gate: duplicate effects=0; mutation/outbox divergence=0; unauthorized writes=0; content leaks=0.
Rollback: disable handler route and keep durable records for reconciliation.

Atomic task: TASK-P12D-050
Depends on: TASK-P12D-040
Purpose: prove legacy/new equivalence, concurrency, retry/crash/replay, denial, restore, and bypass.
Allowed future change: preregistered fixtures, isolated integration tests, and evidence.
Gate: redlines=0; receipt gaps=0; recovery divergence=0; skip/xfail=0.
Rollback: allocation zero, prior writer, reconcile committed outbox, preserve receipts.

Atomic task: TASK-P12D-060
Depends on: TASK-P12D-050
Purpose: bounded cutover, observation, compatibility expiry, contract cleanup and rollback drill.
Allowed future change: approved route/allocation and later contract migration only.
Gate: approved primary result and guards pass; prior-writer rollback and restore pass.
Rollback: stop allocation, restore prior writer, retain compatible schema/data/evidence.

## Acceptance and merge

TASK-P12D-990 independently verifies the named trigger, one-write scope, authorization/approval,
CAS/idempotency, RLS, transaction/outbox, receipts, replay/restore, compatibility, cohort and rollback.
TASK-P12D-999 may merge only an accepted candidate into `codex/gonow-agent-landing`, followed by tree
equality and exact-merge smoke. Neither task exists or runs under this design-only package.

## Current closure

Design ready count: 1. Formal selected count: 0. Named write entries, implementation, contract,
allocation, multi-Agent, migration, and production write counts are zero. Review is pending_external.
