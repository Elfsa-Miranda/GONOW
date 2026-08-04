# P12B-000 dormant cost-router task plan

Task: TASK-P12B-000
Selection candidate: 12B
Portfolio mode: dormant_design_ready
Formal dependency status: pending
Formal selection asserted: false
Implementation commit count: 0
Contract change: false
Production write count: 0
Applicable CT: none
Acceptance task: TASK-P12B-990
Merge task: TASK-P12B-999

## Frozen scope

This package completes design and decomposition only. It creates no router, gateway, provider,
runtime flag, public schema, cohort, specialist ref/worktree, database migration, or production write.
Release B continues on the existing certified single-Agent route. The Four-week trigger and `1.5x`
ratio remain unproven initial hypotheses until immutable calibrated evidence is bound.

## Required design contracts

- Four-week trigger: comparable labelled strata, denominator, exclusions, price versions, uncertainty,
  quality, latency, retry/fallback volume, and positive/negative close decision.
- Deterministic factors: certified capability, task class, Region and privacy, quality floor, latency
  budget, Budget ledger state, provider health, and immutable price version only.
- Route reason: finite reason vocabulary, policy digest, route/fallback result, redacted evidence, and
  no prompt/response/reasoning/secret/raw-PII persistence.
- Quality floor and fallback: eligibility and quality precede cost; unknown/stale/unhealthy/budget-
  exhausted cases use current certified behavior or fail closed; no recursive routing.
- Reliability: idempotent reservation/commit/release, reconciliation, bounded retry, kill switch,
  stable ordering, allocation-zero rollback, and prior-policy replay.

## Proposed atomic DAG

Atomic task: TASK-P12B-010
Depends on: accepted Phase 12 XOR selecting 12B
Purpose: bind the four-week dataset, TCO formula, strata, exclusions, uncertainty, and trigger result.
Allowed future change: evidence and selected-plan amendment only; no runtime.
Gate: comparable weeks=4; unresolved price/label gaps=0; trigger decision is positive or negative.
Rollback: retain immutable evidence and leave allocation zero.

Atomic task: TASK-P12B-020
Depends on: TASK-P12B-010 positive and approved
Purpose: freeze certified capabilities, Deterministic factors, Route reason, Region and privacy rules.
Allowed future change: ADR and internal typed contract after owner approval.
Gate: nondeterministic inputs=0; protected-trait factors=0; uncertified eligible routes=0.
Rollback: keep current route and retire the proposed policy digest.

Atomic task: TASK-P12B-030
Depends on: TASK-P12B-020
Purpose: implement default-off pure policy evaluation and bounded fallback.
Allowed future change: exact internal model-routing modules/tests named by the approved amendment.
Gate: same-input divergence=0; recursive fallback=0; public contract changes=0.
Rollback: router bypass and prior policy digest.

Atomic task: TASK-P12B-040
Depends on: TASK-P12B-020
Purpose: implement Budget ledger reservation, commit, release, reconciliation, and audit receipts.
Allowed future change: separately approved migration/storage paths and internal modules/tests.
Gate: duplicate reservation effects=0; unreconciled terminal reservations=0; content leakage=0.
Rollback: disable new reservations, reconcile open entries, preserve append-only receipts.

Atomic task: TASK-P12B-050
Depends on: TASK-P12B-030,TASK-P12B-040
Purpose: replay quality/cost strata and exercise stale price, health, region, privacy, budget, and kill.
Allowed future change: preregistered datasets, fixtures, evaluator tests, and evidence only.
Gate: quality-floor violations=0; region/privacy violations=0; redlines=0; skip/xfail=0.
Rollback: allocation remains zero; fix only the failed deterministic path and rerun affected strata.

Atomic task: TASK-P12B-060
Depends on: TASK-P12B-050
Purpose: shadow and bounded cohort evaluation, TCO/quality/latency decision, rollback drill.
Allowed future change: approved allocation policy and evidence only.
Gate: approved primary result passes; guards pass; rollback restores Release B equivalence.
Rollback: zero allocation, bypass router, restore prior digest, retain receipts.

## Acceptance and merge

TASK-P12B-990 independently verifies trigger binding, factor/reason contracts, budget ledger,
quality/cost/fallback gates, redlines, replay, cohort evidence, and rollback. TASK-P12B-999 may merge
only its accepted candidate into `codex/gonow-agent-landing`, with tree equality and exact-merge smoke.
Neither task exists or runs under this design-only package.

## Current closure

Design ready count: 1. Formal selected count: 0. Implementation, contract, multi-Agent, allocation,
and production write counts are zero. Independent review is pending_external.
