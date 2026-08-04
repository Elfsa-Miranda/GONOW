# ADR-P12B-000: Dormant deterministic cost-router work package

Status: local provisional design ready; formal selection pending

Decision owners: ModelPlatform, Security, Eval, Finance, Privacy

## Trigger Evidence

The Four-week trigger requires four complete, comparable weeks of labelled Release B traffic before
P12B may be selected. The evidence window must freeze task-class strata, certified-route capability,
quality score, end-to-end latency, billed tokens or units, retries, fallback outcomes, region,
privacy class, and exclusions. The historical `1.5x` cost ratio is an initial hypothesis, not a
selection fact. No complete calibrated window is bound by this design package, so the formal
dependency remains pending and router allocation remains zero.

Selection may proceed only if a preregistered primary cost/TCO result improves, every quality and
safety floor remains non-inferior, uncertainty is reported, and the result cannot be explained by
changed task mix, cache policy, provider health, retry volume, or price-table staleness. A credible
negative result closes the candidate without implementation.

## Options and Decision

Considered options were: keep the existing certified route; add an LLM router; introduce a central
multi-provider gateway; or prepare a deterministic policy package. The decision is to prepare only
the last option as dormant design. It adds no runtime code, dependency, public contract, provider,
gateway, cohort, or production write.

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

If and only if a formal XOR record selects 12B, a later plan change may create these serial tasks:

1. P12B-010 binds the four-week dataset, price sources, strata, denominators, exclusions, uncertainty,
   TCO formula, and positive/negative trigger decision.
2. P12B-020 freezes certified-route capabilities, deterministic factor schema, finite reason codes,
   region/privacy eligibility, and policy digest rules.
3. P12B-030 implements a default-off deterministic policy evaluator and bounded fallback without a
   routing LLM, new gateway, or public Candidate-contract change.
4. P12B-040 implements reservation/commit/release budget-ledger semantics, idempotency, reconciliation,
   and redacted decision evidence using separately approved storage contracts.
5. P12B-050 replays the preregistered strata and exercises stale price, health, region, privacy,
   budget, quality-floor, kill-switch, and equivalence cases.
6. P12B-060 runs shadow then bounded cohort gates, verifies TCO/quality/latency/redlines, and proves
   allocation-zero rollback to the prior policy digest.

P12B-990 remains the independent acceptance task and P12B-999 remains the landing merge task. Their
creation and execution are outside this dormant package.

## Security and Privacy

Policy inputs are server-derived, typed, allowlisted, and tenant-scoped. Caller-supplied route,
provider, price, health, region, privacy, or budget fields are ignored or rejected. Route evidence is
redacted and access-controlled; secrets and request content never enter the ledger. Provider data-use,
residency, retention, deletion, and subprocessors are certified before eligibility. A lower price
cannot override a safety denial, privacy constraint, authorization failure, or tenant budget boundary.

This design adds no network or trust boundary. Later implementation requires threat-model review,
fail-closed tests, billing reconciliation tests, and independent Security, Privacy, Eval, Finance,
and ModelPlatform review.

## Reliability

The evaluator is pure and deterministic over an immutable snapshot. Health and price observations
carry freshness limits; stale or unavailable inputs take the bounded fallback. Reservations use a
stable idempotency key, are released after failed starts, and reconcile against provider receipts.
Retries are bounded and never select an uncertified route. The kill switch bypasses the router,
sets new experimental allocation to zero, preserves ledger evidence, and does not mutate Candidates.

Primary evaluation compares cost per successful quality-qualified task. Diagnostics include route
mix, fallback rate, p95 latency, retry amplification, price-estimate error, and budget-denial rate.
Redlines include safety, privacy, residency, authorization, or cross-tenant failure; no cost saving
can average away a redline.

## Acceptance and Merge

Design readiness means the trigger contract, policy inputs, route reason, eligibility, budget ledger,
quality floor, fallback, six atomic tasks, acceptance ID, merge ID, and rollback are machine checked.
It does not mean Release C selection or production readiness. Formal work begins only after an
accepted Release B head, accepted REL-C path=`phase12`, accepted Phase 12 XOR selecting exactly 12B,
approved ADR/plan change, and a clean specialist worktree from that exact object.

Acceptance task: TASK-P12B-990. Merge task: TASK-P12B-999. Neither may claim accepted without the
required independent review and applicable full regressions. P12A, P12C, and P12D remain dormant.

## Rollback

For this document-only package, revert its commit; runtime remains unchanged. For a future selected
implementation, first set experimental allocation to zero and activate the router bypass, restore the
last known-good policy digest and price version, keep route and budget receipts for audit, replay the
Release B equivalence suite, then diagnose. Never delete ledger evidence, route to an uncertified
provider, weaken the quality floor, or change region/privacy eligibility to recover availability.
