# ADR-P12A-000: Selected local-provisional explicit structured Memory work package

Status: selected local provisional; formal acceptance pending external review
Selection candidate: 12A
Implementation commit count: 0
Contract change: false

The user's direct XOR instruction activates only reversible local implementation and tests. Exact
allowlists are bound by Catalog 2.5.0. Formal acceptance, remote integration, production schema/RLS
claims and production writes remain unauthorized. The closed data scope is `travel_pace`,
`mobility_requirement`, `dietary_requirement`, and `transport_preference`, each an enum, solely for
`itinerary.personalization`, user-visible, and retained at most 365 days. Free text, transcripts,
hidden profiles and model inference are excluded. Production schema/RLS facts remain `unknown`.

## Authority, ADR Triggers, and Execution Boundary

This ADR is indexed to `AGENTS.md` §0.1, §5, §6, §7.3, §10 Phase 12, §14, §15.3 and §16;
`execplan.md` TASK-P12A-000 and the global TASK-P12-089; and v1.6.1 §14.6-14.14. Exact hashes and
supporting release/threat-model documents are recorded in
`docs/execution/evidence/phase-12/ABD-PLAN-HARDENING/guidance-index.json`.

Formal implementation triggers AGENTS.md §16.1 items 2, 3, 4, 6 and 7; item 5 applies to any public
contract change. This dormant ADR does not approve those changes. Its proposed execution and STAR
contracts are machine-readable in `phase-12a/P12A-000/proposed-execution-contract.json` and
`metrics-preregistration.json`, but remain non-authoritative until `execplan.md` and
`TaskGateCatalog.psd1` are jointly amended with exact allowlists.

## Trigger Evidence

Production activation may occur only after a stable Release B failure ledger proves that missing
durable user-approved facts materially cause failures. The `>15%` value is an initial hypothesis,
not a result. A valid analysis must freeze the window, eligible failure taxonomy, numerator,
denominator, exclusions, confidence/uncertainty, tenant and locale slices, and the accepted Release B
head. This design imports no user records and asserts no trigger.

The current outcome is local provisional selection: the production trigger remains unknown,
production allocation/write count is zero, and isolated local tests do not prove production facts.

## Options and Decision

### Option 0: keep Release B unchanged

Safest and lowest cost while the calibrated trigger is absent. Users repeat stable facts and the
Agent cannot recall them, but there is no new privacy, deletion, or poisoning boundary.

### Option 1: infer Memory from transcripts or model summaries

Rejected. It creates hidden profiles, weak provenance, ambiguous consent, hard-to-complete deletion,
and prompt-injection persistence. It also lets model output become durable truth without a Domain
Command.

### Option 2: explicit typed Memory with negative consent

Chosen for this local provisional cycle. Memory is a user-visible typed domain record with
purpose, provenance, version, consent, conflict, retention, and deletion state. The model can only
produce a Memory Candidate. Formal mutation requires an authenticated user confirmation and a typed
Domain Command using row-level security, compare-and-swap, idempotency, and outbox receipt.

The local task DAG is activated; formal owner acceptance and any production cohort remain future work.

## Atomic Tasks

1. Calibrate the real trigger and freeze a licensed, de-identified Memory failure/eval corpus.
2. Define the typed record, Negative consent state machine, purpose/retention and row-level policy.
3. Implement Candidate confirmation and the sole authorized Memory Domain Command.
4. Implement Conflict state, provenance, poisoning resistance, and deterministic read policy.
5. Prove Deletion and export across primary/derived surfaces plus Backup non-resurrection.
6. Add the principal-aware Single-Agent read port, default-off flag, CT-009/015, rollout and rollback.

Exact future task IDs, allowlists, gates, and rollback units are frozen in the companion task plan.
They are proposed implementation tasks and cannot start until the Release C XOR slot selects 12A.

## Security and Privacy

Negative consent is the default. Missing, expired, revoked, purpose-mismatched, or identity-ambiguous
consent denies both write and materialization. Tenant membership alone is insufficient; reads bind
tenant, principal, groups, purpose, record version, consent version, and deletion generation before
materialization and recheck them before Candidate persistence.

Retrieved text is untrusted data. It cannot grant permissions, change system instructions, invoke a
Tool, create another Memory, or select its own retention. Prompt-like content is quoted and labelled;
poisoning can quarantine a record but never silently upgrade trust.

Poisoning boundary: retrieved or user-supplied content can affect the typed fact under review only;
it cannot modify authority, consent, policy, tools, retention, or other records.

Memory stores the smallest typed fact needed for the approved purpose. It excludes secrets, access
tokens, full prompts/responses, hidden reasoning, raw transcripts, precise location history unless
separately approved, and unrelated tenant data. Export follows the same principal/purpose policy and
contains provenance and state without internal security metadata.

## Reliability

The proposed state machine is monotonic and versioned: `proposed -> active|rejected`, active records
may become `conflicted|superseded|revoked|deleted`, and deleted/revoked generations never become
active by ordinary restore. Conflict state retains competing claims and provenance; resolution is an
explicit CAS transition. Duplicate commands resolve through a stable idempotency receipt.

Deletion writes a durable tombstone in the same transaction as the command receipt, then fans out to
indexes, caches, exports, candidates, and eval derivatives. Restore replays tombstones and negative
consent before any read alias becomes available. Partial propagation fails closed for reads and is
repairable from the durable ledger.

The Single-Agent read port returns only typed, already-authorized facts. Provider absence, unknown
consent, stale policy generation, or deletion uncertainty fails closed or continues on the Release B
path without making a Memory-backed claim. It never adds an Agent coordinator.

Behavior value is preregistered as paired task-success net gain against the exact Release B no-Memory
baseline, with correct recall as a diagnostic and non-Memory task success as a non-inferiority guard.
Cross-tenant recall, negative-consent bypass, retrieved-injection action and deletion/restore leakage
are zero-tolerance redlines. Schema existence or a high recall rate alone is not a STAR improvement.
The complete formula, denominator, clustered paired interval, missing-run rule and no-claim boundary
are frozen in `metrics-preregistration.json` before any candidate result can be unblinded.

## Acceptance and Merge

Formal acceptance requires the calibrated trigger, selected P12-002 cycle, approved schema/ADR,
CT-009 and CT-015 with zero tenant/consent/deletion redlines, restore and export drills, cost/latency
budgets, single-Agent flag-off equivalence, independent Product+Security+Privacy+Data review, and a
dedicated P12A-990 acceptance task. P12A-999 may merge only the accepted package to
`codex/gonow-agent-landing` with a two-parent tree-equivalent merge and bounded smoke.

This document is locally ready for design review only. It is not formal acceptance and cannot reserve
the XOR slot.

## Rollback

Set allocation to zero, disable proposals and the read port, pin the Release B Behavior Package, and
preserve records, receipts, consent history, and tombstones for diagnosis/export/deletion. Rollback
must not restore revoked consent or deleted data. Schema contraction waits for retention, export,
outbox drain, backup/restore verification, old-client compatibility, and explicit owner approval.
