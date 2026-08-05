# P12D-000 selected Domain Command task plan

Task: TASK-P12D-000
Selection candidate: 12D
Portfolio mode: local_provisional_selected
Formal dependency status: governance receipt and independent owner acceptance pending
Local XOR selection asserted: true
Implementation commit count: 0
Contract change: false
Production write count: 0
Applicable CT: none
Acceptance task: TASK-P12D-990
Merge task: TASK-P12D-999

## Authority and machine-contract index

- Primary guidance: `AGENTS.md` §0.1, §0.4, §2.3, §5, §6, §7.3-7.5, §8, §10 Phase 12,
  §14, §15.3.1-15.3.4 and §16.1; `execplan.md` TASK-REL-C-000, TASK-P12-000/001/002,
  TASK-P12D-000, TASK-P12-089 and TASK-REL-C-001.
- Target architecture: v1.6.1 §17, §20-21, §26 and §28, indexed by
  `docs/execution/evidence/phase-12/ABD-PLAN-HARDENING/guidance-index.json`.
- Proposed machine contract:
  `docs/execution/evidence/phase-12d/P12D-000/proposed-execution-contract.json`.
- STAR pre-registration:
  `docs/execution/evidence/phase-12d/P12D-000/metrics-preregistration.json`.
- The selected execution contract is activated only by the matching `execplan.md` and
  `TaskGateCatalog.psd1` entries with exact `required_changes[]`, file allowlists, commands, schemas
  and IDs. `selection-record.json` binds this activation to the user's direct XOR decision.

ADR triggers: §16.1 items 1 (API/Worker/Command responsibility), 2 (schema/RLS/outbox), 3
(principal/approval/privacy), 4 (Phase gates), 5 (typed command/receipt if public), 6 (Release C
scope) and 7 (CAS/idempotency/fencing/outbox runtime invariants). This activation authorizes only
reversible local-provisional implementation and tests; it does not supply owner approval, production
write authority, remote-push authority, or Release acceptance.

## CT and test-node disposition

The stable Catalog correctly records no directly applicable CT. CT-001/002 specifically test Run
creation and CT-005/006 test Tool reservation/result boundaries; claiming they directly test Domain
Command would change their semantics without governance. They remain inherited Release B regressions.
New Domain Command cases use `P12D-DC-*`: semantic duplicate, idempotency collision, concurrent
commit, commit-boundary crash, relay replay, stale fencing, approval/RLS denial and restore. Stable
promotion requires an approved plan/Catalog change.

The entry regression reuses the recorded same-runtime smoke bound in `selection-record.json`. The
next complete regression is deferred to TASK-P12D-990 as instructed; TASK-P12D-010 through 060 run
only their affected schema, contract, RealPG/fault-injection, security and Flutter test sets.

## Pre-registered STAR contract

`duplicate_formal_write_count=0`, `unauthorized_or_cross_tenant_write_count=0`,
`mutation_outbox_divergence_count=0` and data-loss/ambiguous committed outcomes=0 are hard redlines,
not an improvement score. Using duplicate count as the primary would be invalid when the Release B
baseline is already zero and could hide a different failure.

TASK-P12D-010 must name one write entry and preselect exactly one causally matching primary from a
closed profile before unblinding: duplicate-effect rate, partial-write/event-loss rate,
ambiguous-outcome repair minutes, or stale-conflict partial-effect rate. It cannot combine them.
The diagnostic is stable receipt coverage; the guardrail is normal-write success non-inferiority.
Rare event profiles use exact one-sided binomial bounds; the duration profile uses a resource-clustered
bootstrap. Synthetic fault injection proves mechanics only and cannot be called a production incident
reduction. Missing write entry, denominator, comparable baseline or power leaves STAR
`measurement_pending`.

## Frozen scope

This selected package may create one Domain Command handler, expand-only migration, RLS/grants,
transactional outbox, typed contract, default-off client flag and local test evidence within the exact
activated allowlists. One write entry must be named by real tracked-repository evidence during
TASK-P12D-010; until then `selected_write_entry=none`. Production facts remain unknown unless separately
proved, production allocation remains zero, and no Multi-Agent framework is in scope.

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
Depends on: the direct-user local-provisional XOR record selecting exactly 12D
Purpose: bind real evidence and name exactly one legacy write entry with trigger and impact map.
Allowed future change: evidence and selected plan/ADR only; no runtime or schema.
Evidence schema: future output `docs/execution/evidence/phase-12d/P12D-010/trigger-evidence.json`
validates against `phase12-trigger-evidence-v1`, including dataset SHA, denominator, exclusions,
selected write entry, impact-map SHA, one closed-profile primary and `trigger_decision=positive|negative`.
Gate/P12D-DC-001: entry regression passes; selected write entries=1 only for a positive decision;
unknown critical side effects=0; primary is frozen before candidate measurement. Negative or
underpowered evidence selects no entry and terminates the package.
Rollback: retain evidence, select no entry, keep allocation zero.

Atomic task: TASK-P12D-020
Depends on: TASK-P12D-010 positive and approved
Purpose: freeze command, Principal and approval, CAS and idempotency, receipt, errors, compatibility.
Allowed future change: ADR and internal typed contracts named by approved plan amendment.
Gate/P12D-DC-002..003: client-asserted authority=0; same semantic retry returns one receipt; key/body
collision conflicts with zero effect; public compatibility gaps=0; phase threat review binds the delta.
Rollback: keep legacy writer authoritative and retire candidate contract digest.

Atomic task: TASK-P12D-030
Depends on: TASK-P12D-020
Purpose: implement expand-only schema, RLS/grants, indexes/functions, backup and restore evidence.
Allowed future change: exact migration/test paths approved by Data and Security.
Gate/P12D-DC-004..005: cross-tenant allow=0; destructive migration steps=0; restore mismatches=0.
Rollback: leave compatible expansion dormant; route no traffic; preserve data.

Atomic task: TASK-P12D-040
Depends on: TASK-P12D-030
Purpose: implement one handler, atomic mutation plus Transactional outbox, fencing, Stable receipt.
Allowed future change: exact internal service/worker/test paths behind default-off flag.
Gate/P12D-DC-006..009: concurrent duplicate, crash before/after commit, relay replay and stale-fence
matrices produce duplicate effects=0; mutation/outbox divergence=0; unauthorized writes=0;
content leaks=0.
Rollback: disable handler route and keep durable records for reconciliation.

Atomic task: TASK-P12D-050
Depends on: TASK-P12D-040
Purpose: prove legacy/new equivalence, concurrency, retry/crash/replay, denial, restore, and bypass.
Allowed future change: preregistered fixtures, isolated integration tests, and evidence.
Gate/P12D-DC-010..012: redlines=0; receipt gaps=0; recovery divergence=0; fault-injection outcomes are
labelled mechanics-only; skip/xfail=0.
Rollback: allocation zero, prior writer, reconcile committed outbox, preserve receipts.

Atomic task: TASK-P12D-060
Depends on: TASK-P12D-050
Purpose: bounded cutover, observation, compatibility expiry, contract cleanup and rollback drill.
Allowed future change: approved route/allocation and later contract migration only.
Gate/P12D-DC-013..014: the frozen primary confidence bound and normal-write guard pass; every redline
is zero; prior-writer rollback and restore pass.
Rollback: stop allocation, restore prior writer, retain compatible schema/data/evidence.

## Acceptance and merge

TASK-P12D-990 independently verifies the named trigger, one-write scope, authorization/approval,
CAS/idempotency, RLS, transaction/outbox, receipts, replay/restore, compatibility, cohort and rollback.
TASK-P12D-999 may merge only the locally verified provisional candidate into the local
`codex/gonow-agent-landing`, followed by tree equality and exact-merge smoke. Neither remote push nor
formal acceptance is authorized. The tasks now exist in the activated plan/Catalog.

The selected 060/990 evidence feeds the existing global `TASK-P12-089`; no `TASK-P12D-089` is added.
This preserves AGENTS.md §14's one-089-per-Phase contract.

## Current closure

Design ready count: 1. Local-provisional selected count: 1. Formal accepted count: 0. Named write
entries, implementation, allocation, migration, and production write counts are zero at activation;
TASK-P12D-010 must select exactly one before implementation. Multi-Agent framework count remains zero.
