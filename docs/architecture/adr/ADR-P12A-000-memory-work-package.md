# ADR-P12A-000: Dormant explicit structured Memory work package

Status: local provisional design ready; formal selection pending
Selection candidate: 12A
Implementation commit count: 0
Contract change: false

## Trigger Evidence

Phase 12A may be formally selected only after a stable Release B failure ledger proves that missing
durable user-approved facts materially cause failures. The `>15%` value is an initial hypothesis,
not a result. A valid analysis must freeze the window, eligible failure taxonomy, numerator,
denominator, exclusions, confidence/uncertainty, tenant and locale slices, and the accepted Release B
head. This design imports no user records and asserts no trigger.

The current outcome is design readiness only: `formal_dependency_status=pending`, allocation zero,
and no Memory table, service, profile, or branch.

## Options and Decision

### Option 0: keep Release B unchanged

Safest and lowest cost while the calibrated trigger is absent. Users repeat stable facts and the
Agent cannot recall them, but there is no new privacy, deletion, or poisoning boundary.

### Option 1: infer Memory from transcripts or model summaries

Rejected. It creates hidden profiles, weak provenance, ambiguous consent, hard-to-complete deletion,
and prompt-injection persistence. It also lets model output become durable truth without a Domain
Command.

### Option 2: explicit typed Memory with negative consent

Chosen as the dormant candidate architecture. Memory is a user-visible typed domain record with
purpose, provenance, version, consent, conflict, retention, and deletion state. The model can only
produce a Memory Candidate. Formal mutation requires an authenticated user confirmation and a typed
Domain Command using row-level security, compare-and-swap, idempotency, and outbox receipt.

Option 2 is not activated by this ADR. Formal selection, owner approval, schema design, migration,
tests, cohort, and release tasks remain future atomic work.

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
