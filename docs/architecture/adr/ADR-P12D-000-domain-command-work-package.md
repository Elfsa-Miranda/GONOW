# ADR-P12D-000: Dormant one-write-entry Domain Command work package

Status: local provisional design ready; formal selection pending

Decision owners: DomainPlatform, Security, Data, Product, SRE

## Trigger Evidence

Phase 12D may migrate One write entry only after an accepted Release B head and an immutable,
representative evidence window identify a named legacy write point. The window must quantify request
volume, concurrency conflicts, duplicate effects, unauthorized attempts, partial writes, repair load,
latency/SLA, compatibility population, recovery objectives, and data criticality. No such approved
binding exists in this design package, so `selected_write_entry=none`, formal selection is pending,
and no schema or production write is authorized.

P12D is eligible only if the evidence shows that a bounded migration improves an agreed primary
reliability or security result without worsening compatibility, latency, data integrity, privacy, or
operational recovery. Synthetic results can validate mechanics but cannot select the write entry.
A credible negative or underpowered result closes this candidate with allocation zero.

## Options and Decision

Options considered are: retain and harden the current writer; migrate every legacy writer at once;
introduce generic infrastructure first; or migrate one evidence-selected entry through a typed Domain
Command. The dormant decision prepares the fourth option only. It creates no command implementation,
table, migration, API schema, public event, runtime flag, cohort, specialist ref, or production write.

The selected future command accepts a typed request plus authenticated RequestContext; the model may
only propose a Candidate. Principal and approval are evaluated server-side against tenant, resource,
purpose, command type, risk class, expected version, and approval receipt. Client identifiers or model
output cannot assert principal, tenant, approver, role, or authorization outcome.

CAS and idempotency form one write contract. The command requires an expected version and stable
idempotency key scoped to tenant, principal, command type, and target. A semantic retry returns the
same result; a key reused with different input is rejected; stale expected version returns conflict
without partial effect. Authorization and approval are revalidated before the transactional write.

The business mutation, command result pointer, and Transactional outbox event are committed in one
database transaction. No event is published before commit. Outbox delivery is at-least-once with
consumer idempotency, bounded retry, dead-letter evidence, ordering scoped only where explicitly
required, and fencing that prevents an expired worker from completing a newer claim.

A Stable receipt is returned and persisted without secret, prompt, response, reasoning, or unnecessary
PII. It binds command type/version, tenant-scoped target digest, principal digest, approval reference,
idempotency key digest, expected/actual version, result state, outbox identifier, policy/schema digest,
and timestamp. Denied or conflicted attempts receive a non-authorizing receipt and produce no business
or outbox write.

## Atomic Tasks

If and only if a formal XOR record selects 12D, a later plan amendment may create these serial tasks:

1. P12D-010 binds real evidence, names exactly one write entry, maps its current authorization,
   transaction, side effects, clients, SLA, recovery, and confirms the trigger.
2. P12D-020 freezes the typed command, Principal and approval rules, error taxonomy, CAS and idempotency,
   Stable receipt, compatibility, audit, and no-model-write invariants.
3. P12D-030 implements expand-only schema/RLS/grants/functions and validates backup, restore, rollback,
   cross-tenant denial, and least privilege before any route can use it.
4. P12D-040 implements the single command handler, atomic mutation plus Transactional outbox,
   idempotency/fencing, receipt, and isolated fake/integration tests behind a default-off flag.
5. P12D-050 proves legacy/new equivalence, concurrency, retry, crash, replay, restore, denial, and
   rollback in shadow and an approved bounded cohort.
6. P12D-060 performs the approved cutover, observes the frozen window, executes contract cleanup only
   after compatibility expiry, and proves Expand-contract rollback throughout.

P12D-990 remains the independent acceptance task and P12D-999 remains the landing merge task. Their
creation and execution are not authorized by this dormant package.

## Security and Privacy

The server derives principal and tenant from verified identity and maintains tenant scope through
authorization, SQL transaction, RLS, outbox, receipt, and replay. Approval is explicit, versioned,
unexpired, command-specific, and independently auditable for high-risk writes. Denial is fail closed.
No service role is exposed to clients, no generic arbitrary command endpoint is introduced, and tools
cannot bypass Domain Command validation.

Inputs are schema-bounded and minimized; receipts store digests or references where raw data is not
required. RLS and grants are tested with adversarial tenants. Logs, errors, events, and dead-letter
evidence exclude secret, token, prompt, response, reasoning, and unnecessary PII. Deletion, retention,
residency, and legal-hold behavior follow the selected domain's approved data contract.

## Reliability

The command state model is deterministic: received → authorized → approved → committed, or a terminal
denied/conflicted/rejected result. Transaction rollback leaves no business row, command-success
pointer, or outbox event. After commit, retries resolve from the idempotency record and the durable
dispatcher resumes outbox delivery. Lease fencing, bounded retry, dead-letter ownership, reconciliation,
and restore drills make partial outcomes observable and repairable.

Primary evaluation is the selected write entry's preregistered reliability/security result. Diagnostics
include conflict rate, duplicate-effect count, partial-effect count, receipt completeness, outbox lag,
replay convergence, p95 latency, and repair time. Cross-tenant access, unauthorized write, data loss,
receipt ambiguity, or mutation/outbox divergence are redlines and cannot be averaged away.

## Acceptance and Merge

Design readiness means the trigger and selection method, command invariants, principal/approval,
CAS/idempotency, transaction/outbox, receipt, compatibility, six atomic tasks, acceptance ID, merge ID,
and rollback are machine checked. It is not an accepted ADR, selected write entry, migration, or
production capability.

Formal work requires accepted Release B, accepted REL-C path=`phase12`, an accepted Phase 12 XOR
selecting exactly 12D, a named evidence-backed write entry, approved ADR/plan/migration review, and a
clean specialist worktree from the exact accepted object. Acceptance task: TASK-P12D-990. Merge task:
TASK-P12D-999. P12A, P12B, and P12C remain dormant.

## Rollback

For this document-only package, revert its commit; runtime remains unchanged. A future implementation
uses Expand-contract rollback: stop new allocation, route the bounded cohort to the prior authorized
writer, retain new compatible columns/tables, idempotency records, receipts, and outbox evidence,
replay Release B equivalence, then diagnose. Cleanup happens only after the approved compatibility
window and restore proof. Rollback never drops data, reuses a stale approval, disables RLS, rewrites a
receipt, publishes an uncommitted event, or resurrects an expired worker.
