# P12A dormant Memory implementation plan

Task: TASK-P12A-000
Selection candidate: 12A
Portfolio mode: dormant_design_ready
Formal dependency status: pending
Formal selection asserted: false
Cycle: pending_formal_selection
P12-002 head: pending
Implementation commit count: 0
Contract change: false
Production write count: 0
Applicable CT: CT-009,CT-015
Acceptance task: TASK-P12A-990
Merge task: TASK-P12A-999

## Authority and machine-contract index

- Primary guidance: `AGENTS.md` §0.1, §0.4, §2.3, §5, §6, §7.3-7.5, §10 Phase 12,
  §14, §15.3.1-15.3.4 and §16.1; `execplan.md` TASK-REL-C-000, TASK-P12-000/001/002,
  TASK-P12A-000, TASK-P12-089 and TASK-REL-C-001.
- Target architecture: v1.6.1 §14.6-14.14, bound through
  `docs/execution/evidence/phase-12/ABD-PLAN-HARDENING/guidance-index.json`.
- Proposed machine contract:
  `docs/execution/evidence/phase-12a/P12A-000/proposed-execution-contract.json`.
- STAR pre-registration:
  `docs/execution/evidence/phase-12a/P12A-000/metrics-preregistration.json`.
- These candidate files do not supersede `TaskGateCatalog.psd1`. Formal activation requires an
  approved `execplan.md` and Catalog revision with exact `required_changes[]`, `file_allowlist`,
  commands, evidence schemas and merge IDs. Empty future allowlists fail closed.

ADR triggers: §16.1 items 2 (Memory data/RLS/deletion/restore), 3 (consent/privacy/injection),
4 (Phase gate activation), 6 (Release C scope) and 7 (Candidate/Domain Command/CAS/outbox/runtime
invariants). Item 5 also applies if a public contract changes. No item 1 dependency or process-boundary
change is authorized by this dormant plan.

## CT and test-node disposition

CT-009 and CT-015 are directly applicable. CT-001/002/005/006/007/012/013 are inherited Release B
regressions, not redefined Memory tests. CT-011 remains out of scope because this package is
Single-Agent and has no parallel specialist branches. New candidate-only cases use the `P12A-ME-*`
namespace; those IDs cannot enter the stable CT catalog until an approved plan/Catalog amendment.

Before TASK-P12A-010 evidence is accepted, the exact accepted Release B manifest must replay all
implemented mandatory CT/gates, kill/replay, cross-tenant=0, flag-off Behavior Package digest
equivalence, Phase 4 E0 parity and legacy critical journeys with `skip=0; xfail=0`.

## Pre-registered STAR contract

This plan makes no improvement claim while dormant. TASK-P12A-010 must freeze the exact Release B
OID, candidate base, dataset hash, eligible/excluded rules, evaluator, model/parameters, tool/database
versions, seeds/repeats, hardware, time window and owner-approved decision margins before candidate
measurement. The pre-registered roles are:

- Primary: `paired_task_success_net_gain_pp` on identical scenario-seed pairs.
- Diagnostic: `correct_recall_rate`, whose denominator includes every gold eligible recall opportunity,
  including misses.
- Guardrail: non-Memory task success non-inferiority.
- Hard redlines: cross-tenant materialization, negative-consent bypass, retrieved-injection executed
  actions and deletion/restore propagation failures are all exactly zero and are never averaged.

The primary uses a paired, task-family-clustered 95% interval; run order is randomized and evaluation
is blind. Candidate-caused timeout, rejection or trace loss is a failure. Infrastructure-only pair
exclusion must be symmetric and follow the frozen rule. No outlier success is removed. If baseline,
power, bindings or comparability is missing, `TASK-P12-089` records
`not_applicable + reason=measurement_pending:<exact_missing_evidence>` rather than a STAR result.

## Frozen architecture markers

- Negative consent
- Conflict state
- Poisoning boundary
- Deletion and export
- Backup non-resurrection
- Single-Agent read port

## Entry and scope

Entry requires an accepted Release B head, accepted P12-002 selecting 12A, a calibrated real trigger,
and owner-approved data purpose. Until then every task below is dormant and has no implementation
branch. The selected package remains inside the existing Agent codebase and the two-process
`agent-api`/`agent-worker` boundary; no multi-agent coordinator, Redis, queue, dynamic MCP market, or
new production service is permitted.

## Proposed atomic tasks

Atomic task: TASK-P12A-010

- Scope: freeze trigger analysis, licensed/de-identified dataset, denominator/exclusions, consent and
  deletion redlines, and accepted Release B comparison head.
- Allowlist after plan approval: dataset manifests, eval fixtures, analysis receipts, no user rows.
- Evidence schema: future output
  `docs/execution/evidence/phase-12a/P12A-010/trigger-evidence.json` must validate against
  `phase12-trigger-evidence-v1`; all required fields are non-null and `trigger_decision` is
  `positive|negative`.
- Gate/P12A-ME-001: entry regression passes; trigger interval and every slice are reproducible;
  privacy/license gaps and raw-data findings zero; thresholds and metrics are frozen before any
  candidate result is unblinded. A negative or underpowered decision terminates the package cleanly.
- Rollback: discard the candidate selection, retain immutable aggregate evidence.

Atomic task: TASK-P12A-020

- Scope: design and migrate typed Memory records, purpose, provenance, retention, Negative consent,
  row-level security, grants, tombstone identity, outbox, and expand-contract rollback.
- Gate/P12A-ME-002..003: clean migration/restore, cross-tenant/consent denies, schema diff, grant diff, backup
  non-resurrection plan, production write count zero during certification.
- Rollback: keep new columns/tables dormant; do not contract until old code and exports are safe.

Atomic task: TASK-P12A-030

- Scope: Memory Candidate, explicit confirmation, principal/approval reauthorization, CAS,
  idempotency, transactional outbox, and stable Domain Command receipt.
- Gate/P12A-ME-004..005: forged/replayed/stale/unknown-outcome vectors; model and Worker have no direct formal write.
- Rollback: disable proposal/adopt route, preserve candidates and receipts.

Atomic task: TASK-P12A-040

- Scope: Conflict state, competing-claim provenance, deterministic resolution, poisoning quarantine,
  instruction-as-data handling, and stable materialization policy.
- Gate/P12A-ME-006..009: `retrieved_injection_executed_action_count=0` under direct injection,
  indirect RAG injection when P11 is active, multilingual variants and encoded/obfuscated variants;
  permutation/replay deterministic; conflicts never silently overwrite active facts. The phase threat
  review must bind the package delta before this task.
- Rollback: quarantine uncertain records and bypass Memory reads.

Atomic task: TASK-P12A-050

- Scope: Deletion and export fanout across primary rows, indexes, caches, candidates, eval derivatives,
  exports, and backups; restore applies tombstones and consent before aliases open.
- Gate/P12A-ME-010..011: all surfaces unreadable after deletion, export authorization exact, Backup non-resurrection,
  repair idempotent, CT-015 passed without skip/xfail.
- Rollback: deletion never rolls back; repair propagation from the durable tombstone.

Atomic task: TASK-P12A-060

- Scope: principal-aware Single-Agent read port, feature flag/generation, observability, quality and
  latency budgets, CT-009/015, bounded cohort, kill switch, runbook, and Release B equivalence replay.
- Gate/P12A-ME-012..013: flag-off digest equivalence; tenant/consent/deletion leakage zero; the frozen
  STAR primary confidence bound and non-Memory guardrail pass; quality/cost/latency meet
  approved values; no Multi-Agent implementation.
- Rollback: allocation zero and Release B Behavior Package; retain audit and compatible data.

## Dependency and merge DAG

`010 -> 020 -> 030 -> 040 -> 050 -> 060 -> P12A-990 -> TASK-P12-089 -> P12A-999`.
Implementation tasks require a plan change that freezes exact file allowlists, commands, datasets,
thresholds, owner identities, and merge IDs. A design-ready receipt is not a substitute for that
change. `TASK-P12-089` is the single Phase 12 documentation/knowledge-transfer task required by
AGENTS.md §14; no candidate-specific `P12A-089` is created. P12A cannot run in the same Release C
cycle as P12B, P12C, or P12D.

## Acceptance evidence

The future package must preserve commands, exit codes, JUnit, migration/restore queries, security
canaries, dataset/price hashes, trace/run/package digests, deletion/export receipts, rollback timings,
STAR metrics, independent reviews, candidate/merge OIDs, and artifact hashes. It must report unknown
or unmeasured values as pending, never as pass.
