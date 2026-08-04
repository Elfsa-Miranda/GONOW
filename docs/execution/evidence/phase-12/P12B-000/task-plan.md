# P12B-000 selected local-provisional cost-router task plan

Task: TASK-P12B-000
Selection candidate: 12B
Portfolio mode: selected_local_provisional
Formal dependency status: pending_external
Local selection asserted: true
Implementation commit count: 0
Contract change: false
Production write count: 0
Applicable CT: none
Acceptance task: TASK-P12B-990
Merge task: TASK-P12B-999

## Authority and machine-contract index

- Primary guidance: `AGENTS.md` §0.1, §0.4, §2.3, §5, §6, §7.3-7.5, §10 Phase 12,
  §14, §15.3.1-15.3.4 and §16.1; `execplan.md` TASK-REL-C-000, TASK-P12-000/001/002,
  TASK-P12B-000, TASK-P12-089 and TASK-REL-C-001.
- Target architecture: v1.6.1 §27.4-27.7, indexed by
  `docs/execution/evidence/phase-12/ABD-PLAN-HARDENING/guidance-index.json`.
- Proposed machine contract:
  `docs/execution/evidence/phase-12b/P12B-000/proposed-execution-contract.json`.
- STAR pre-registration:
  `docs/execution/evidence/phase-12b/P12B-000/metrics-preregistration.json`.
- The direct user XOR decision activates exact `execplan.md`/Catalog allowlists for local work.
  Formal owner approval, production provider certification, four production weeks and production
  allocation remain pending and cannot be inferred from this activation.

ADR triggers: §16.1 items 4 (Phase gate activation), 6 (Release C allocation) and 7 (routing/budget
invariants) apply; items 2, 3 and 5 become mandatory if the selected ledger, external data use or
public Behavior/route contract changes. No new gateway, provider or process boundary is authorized;
any such addition triggers item 1 and a new decision.

## CT and test-node disposition

`Applicable CT: none` remains correct for the current stable catalog. CT-001/002 are Run-creation
contracts, CT-005/006 are Tool-boundary crash contracts, and CT-011 is explicitly parallel-branch
Multi-Agent budget semantics. They must not be silently repurposed as cost-router tests. The selected
package nevertheless replays CT-001/002/005/006/012/013 as inherited Release B regressions and adds
candidate-only `P12B-CR-*` nodes for reservation collision, concurrency, deterministic routing,
eligibility and fallback. Stable CT promotion requires an approved plan/Catalog revision.

TASK-P12B-010 binds landing `f941051871ecd7ea811540072a032ce7aaa0119d` and reuses the immediately
preceding stable post-P12D smoke rather than rerunning the full suite at entry. Each implementation
task runs only affected routing, quality, cost and security tests. P12B-990 runs the single full
regression; P12B-999 runs one focused post-merge smoke.

## Pre-registered STAR contract

- Primary: total TCO per successful quality-qualified task. The numerator includes every billed
  attempt, failure, retry and fallback plus frozen serving overhead; the denominator contains only
  successful quality-qualified tasks. Zero successes is `undefined_fail_closed`.
- Diagnostic: retry/fallback cost amplification, which explains whether route savings survive recovery
  behavior. Quality-floor violations are not a diagnostic; they are a hard redline.
- Guardrail: paired quality-qualified task-success non-inferiority overall and for every critical
  stratum. The reviewer's suggested 1 pp margin is retained only as an Initial Hypothesis ceiling;
  the actual margin and power must be justified and owner-frozen before candidate measurement.
- Hard redlines: quality-floor violation, uncertified/region/privacy-ineligible use, Route reason
  sensitive-content leak and reservation-race overspend are all zero.

The primary decision uses the one-sided 95% upper bound of candidate/baseline cost ratio; quality uses
a one-sided lower bound. Price snapshot, task mix, cache policy, health state, evaluator and retries
are frozen. No billed attempt is removed as an outlier. Shadow duplicate traffic is reported
separately from projected serving TCO. Negative or underpowered four-week evidence archives the
package without running 020-060.

## Frozen scope

This package implements one default-off deterministic router at the existing itinerary Worker model
boundary. It adds a fixed DeepSeek candidate adapter and a local content-free budget-ledger reference
implementation, but no central gateway, routing LLM, public schema, client key, extra process,
database migration, production cohort or production write. Release B behavior remains the fallback.
The four-week production trigger and any production improvement remain unknown; local fake/replay and
bounded live calibration are controlled mechanism evidence only.

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
Purpose: bind the repository-derived local dataset, official price snapshot, TCO formula, strata,
exclusions, uncertainty and no-production-claim boundary; formal four-week evidence stays pending.
Allowed future change: evidence and selected-plan amendment only; no runtime.
Evidence schema: future output `docs/execution/evidence/phase-12b/P12B-010/trigger-evidence.json`
validates against `phase12-trigger-evidence-v1`, including dataset SHA, denominator, exclusions,
price snapshot/version, TCO formula, frozen quality margin and `trigger_decision=positive|negative`.
Gate/P12B-CR-001: stable entry smoke is bound; local scenario and price gaps=0; estimator,
uncertainty and thresholds are frozen before candidate unblinding; production weeks remain unknown.
Rollback: retain immutable evidence and leave allocation zero.

Atomic task: TASK-P12B-020
Depends on: TASK-P12B-010 local scope frozen; formal production trigger remains pending
Purpose: freeze certified capabilities, Deterministic factors, Route reason, Region and privacy rules.
Allowed future change: ADR and internal typed contract after owner approval.
Gate/P12B-CR-002..003: nondeterministic inputs=0; protected-trait factors=0; uncertified eligible
routes=0; phase threat review binds the package delta.
Rollback: keep current route and retire the proposed policy digest.

Atomic task: TASK-P12B-030
Depends on: TASK-P12B-020
Purpose: implement default-off pure policy evaluation and bounded fallback.
Allowed future change: exact internal model-routing modules/tests named by the approved amendment.
Gate/P12B-CR-004..005: same-input divergence=0; recursive fallback=0; public contract changes=0.
Rollback: router bypass and prior policy digest.

Atomic task: TASK-P12B-040
Depends on: TASK-P12B-020
Purpose: implement Budget ledger reservation, commit, release, reconciliation, and audit receipts.
Allowed future change: content-free local reference ledger and tests; durable storage needs a later
approved migration/storage contract.
Gate/P12B-CR-006..008: same key/body reserves once; same key/different body conflicts; concurrent
single-Agent reservations cannot overspend; unreconciled terminal reservations=0; content leakage=0.
Rollback: disable new reservations, reconcile open entries, preserve append-only receipts.

Atomic task: TASK-P12B-050
Depends on: TASK-P12B-030,TASK-P12B-040
Purpose: replay quality/cost strata and exercise stale price, health, region, privacy, budget, and kill.
Allowed future change: preregistered datasets, fixtures, evaluator tests, and evidence only.
Gate/P12B-CR-009..011: quality-floor violations=0; region/privacy violations=0; redlines=0;
all frozen strata reported; skip/xfail=0.
Rollback: allocation remains zero; fix only the failed deterministic path and rerun affected strata.

Atomic task: TASK-P12B-060
Depends on: TASK-P12B-050
Purpose: fake/replay plus bounded local live calibration, TCO/quality/latency decision, rollback drill.
Allowed future change: approved allocation policy and evidence only.
Gate/P12B-CR-012..013: primary cost-ratio upper bound and quality lower-bound guards pass; actual and
estimated prices reconcile; rollback restores Release B equivalence.
Rollback: zero allocation, bypass router, restore prior digest, retain receipts.

## Acceptance and merge

TASK-P12B-990 independently verifies trigger binding, factor/reason contracts, budget ledger,
quality/cost/fallback gates, redlines, replay, cohort evidence, and rollback. TASK-P12B-999 may merge
only its accepted candidate into `codex/gonow-agent-landing`, with tree equality and exact-merge smoke.
Both are activated for local provisional execution only.

The selected 060/990 evidence feeds the existing global `TASK-P12-089` before merge. No formal
`TASK-P12B-089` is created because AGENTS.md §14 requires one 089 per Phase, and Phase 12 already has
that task.

## Current closure

Design ready count: 1. Local selected count: 1. Multi-Agent, production allocation and production
write counts are zero. Independent review and formal production evidence are pending_external.
