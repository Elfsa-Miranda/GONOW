# ADR-P12B-000: Selected local-provisional deterministic cost-router work package

Status: selected for local provisional implementation; formal acceptance and production allocation pending

Decision owners: ModelPlatform, Security, Eval, Finance, Privacy

## Authority, ADR Triggers, and Execution Boundary

This ADR is indexed to `AGENTS.md` §0.1, §5, §6, §7.3, §10 Phase 12, §14, §15.3 and §16;
`execplan.md` TASK-P12B-000 and global TASK-P12-089; and v1.6.1 §27.4-27.7. Exact hashes and
supporting contracts are in `docs/execution/evidence/phase-12/ABD-PLAN-HARDENING/guidance-index.json`.

Selection/implementation triggers §16.1 items 4, 6 and 7, plus items 2, 3 or 5 if the chosen ledger,
data use or public contract changes. A new gateway/provider/process boundary would additionally
trigger item 1. The direct user XOR record under `phase-12b/P12B-000/` activates the execution and
STAR contracts for this local-only cycle, and the accompanying execplan/Catalog revision binds exact
allowlists and commands. It does not supply formal owner approval, production provider certification,
a four-week production window, or production allocation.

## Trigger Evidence

The Four-week trigger requires four complete, comparable weeks of labelled Release B traffic before
P12B may be selected. The evidence window must freeze task-class strata, certified-route capability,
quality score, end-to-end latency, billed tokens or units, retries, fallback outcomes, region,
privacy class, and exclusions. The historical `1.5x` cost ratio is an initial hypothesis, not a
selection fact. No complete production-calibrated window is bound by this package, so the formal
dependency remains pending and router allocation remains zero. For local implementation only,
TASK-P12B-010 freezes a repository-derived synthetic itinerary workload and the user-supplied live
call ceiling. That local window validates mechanics and a controlled comparison, not production.

Selection may proceed only if a preregistered primary cost/TCO result improves, every quality and
safety floor remains non-inferior, uncertainty is reported, and the result cannot be explained by
changed task mix, cache policy, provider health, retry volume, or price-table staleness. A credible
negative result closes the candidate without implementation.

## Options and Decision

Considered options were: keep the existing certified route; add an LLM router; introduce a central
multi-provider gateway; or implement a deterministic policy package at the existing Worker model
boundary. This cycle selects only the last option. The baseline remains the fixed Gemini itinerary
route and the local candidate is a fixed DeepSeek adapter. No routing LLM, central gateway, dynamic
provider discovery, new process, public contract, client credential, production cohort, or
production write is allowed.

Deterministic factors are restricted to versioned inputs: task class, certified capability,
region, privacy class, quality floor, latency budget, budget state, provider health, and an immutable
price-table version. Prompts, free-form model output, protected traits, inferred demographics, and
tenant identity are never optimization inputs. Stable ordering and a policy digest make identical
inputs produce the same route or fallback.

Every future decision emits a Route reason code, selected route identifier, policy digest, price
version, input-class digests, fallback reason, and budget reservation reference. It must not persist
prompt, response, reasoning, secret, or raw PII. The reason vocabulary is finite and contract-tested.

Region and privacy are eligibility constraints, not weighted preferences. A route is removed before
cost comparison when residency, data-use, retention, certification, or privacy requirements do not
match. Empty eligibility fails closed or uses the already approved current certified route exactly as
specified by the active Behavior Package.

The Budget ledger is append-only and auditable. Reservation, commit, and release are idempotent and
bound to run, tenant budget scope, policy digest, and price version. Budget exhaustion cannot weaken
quality, privacy, or region constraints. Estimated cost and provider-billed actual cost remain
separate fields so reconciliation does not rewrite historical decisions.

The Quality floor and fallback contract is evaluated before price ranking and after execution.
Unknown labels, stale prices, provider-health uncertainty, missing certification, floor violation,
or bounded retry exhaustion bypass the experimental route. The fallback target is the current
certified route or the existing fail-closed behavior; there is no recursive routing.

## Atomic Tasks

The local XOR record selects 12B and the activated plan creates these serial tasks:

1. P12B-010 binds the four-week dataset, price sources, strata, denominators, exclusions, uncertainty,
   TCO formula, and positive/negative trigger decision.
2. P12B-020 implements and freezes the pure deterministic evaluator: certified-route capabilities,
   closed typed factor schema, finite reason codes, region/privacy/quality-before-cost eligibility,
   immutable price and health freshness, stable policy/input-class digests, kill switch, and exactly
   one-hop fallback. It performs no I/O and reads no environment or request content.
3. P12B-030 implements the fixed provider adapter and wires that already-tested evaluator default-off
   inside the existing authenticated Worker boundary, without a routing LLM, new central gateway, or
   public Candidate-contract change.
4. P12B-040 implements reservation/commit/release budget-ledger semantics, idempotency,
   reconciliation, concurrency and redacted decision evidence in a content-free local reference
   ledger. Durable PostgreSQL production storage remains a separately approved contract.
5. P12B-050 replays the preregistered strata and exercises stale price, health, region, privacy,
   budget, quality-floor, kill-switch, and equivalence cases.
6. P12B-060 runs fake/replay and, when both environment credentials are available, one bounded local
   live calibration of at most 20 tasks, 40 calls and 100,000 total tokens. It verifies the
   preregistered local TCO/quality/latency/redlines and proves allocation-zero rollback. Missing
   credentials leave live calibration pending without weakening any gate.

P12B-990 is the local provisional acceptance candidate and P12B-999 is the local landing merge task.
Neither may claim formal acceptance or production readiness without external governance and
production evidence.

## Security and Privacy

Policy inputs are server-derived, typed, allowlisted, and tenant-scoped. Caller-supplied route,
provider, price, health, region, privacy, or budget fields are ignored or rejected. Route evidence is
redacted and access-controlled; secrets and request content never enter the ledger. Provider data-use,
residency, retention, deletion, and subprocessors are certified before eligibility. A lower price
cannot override a safety denial, privacy constraint, authorization failure, or tenant budget boundary.

The pure evaluator added by P12B-020 creates no network or trust boundary. It accepts only explicit,
immutable snapshots and fails closed when the existing baseline is unsafe. Provider integration in
P12B-030 is a later bounded trust-boundary change and remains default-off. Threat-model review,
billing reconciliation tests, and independent Security, Privacy, Eval, Finance, and ModelPlatform
review remain required before formal acceptance or production allocation.

## Reliability

The evaluator is pure and deterministic over an immutable snapshot. Health and price observations
carry freshness limits; stale or unavailable inputs take the bounded fallback. Reservations use a
stable idempotency key, are released after failed starts, and reconcile against provider receipts.
Retries are bounded and never select an uncertified route. The kill switch bypasses the router,
sets new experimental allocation to zero, preserves ledger evidence, and does not mutate Candidates.

Primary evaluation compares total cost per successful quality-qualified task and keeps every failed,
retried and fallback attempt in the cost numerator. Retry/fallback cost amplification is the causal
diagnostic. Quality-qualified task success is a non-inferiority guard, while quality-floor,
certification, privacy, residency, sensitive Route-reason content and budget-race violations are
zero-tolerance redlines. The historical 1.5x and a suggested 1 pp quality margin remain hypotheses;
TASK-P12B-010 must justify and freeze the actual thresholds, price snapshot, power and one-sided
confidence rules before unblinding. A negative result retires the package without implementing it.

## Acceptance and Merge

Design readiness means the trigger contract, policy inputs, route reason, eligibility, budget ledger,
quality floor, fallback, six atomic tasks, acceptance ID, merge ID, and rollback are machine checked.
It does not mean Release C selection or production readiness. Formal work begins only after an
accepted Release B head, accepted REL-C path=`phase12`, accepted Phase 12 XOR selecting exactly 12B,
approved ADR/plan change, and a clean specialist worktree from that exact object.

Acceptance task: TASK-P12B-990. Merge task: TASK-P12B-999. Neither may claim accepted without the
required independent review and applicable full regressions. P12A, P12C, and new P12D work remain
dormant for this cycle; prior P12D `ready_for_review` evidence is historical and unchanged.

## Rollback

For this document-only package, revert its commit; runtime remains unchanged. For a future selected
implementation, first set experimental allocation to zero and activate the router bypass, restore the
last known-good policy digest and price version, keep route and budget receipts for audit, replay the
Release B equivalence suite, then diagnose. Never delete ledger evidence, route to an uncertified
provider, weaken the quality floor, or change region/privacy eligibility to recover availability.
