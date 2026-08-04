# ADR-P12D-000: Selected one-write-entry Domain Command work package

Status: local provisionally selected for implementation; independent owner acceptance pending

Decision owners: DomainPlatform, Security, Data, Product, SRE

## Authority, ADR Triggers, and Execution Boundary

This ADR is indexed to `AGENTS.md` §0.1, §5, §6, §7.3, §8, §10 Phase 12, §14, §15.3 and §16;
`execplan.md` TASK-P12D-000 and global TASK-P12-089; and v1.6.1 §17, §20-21, §26 and §28. Exact
hashes and supporting contracts are in
`docs/execution/evidence/phase-12/ABD-PLAN-HARDENING/guidance-index.json`.

Implementation triggers §16.1 items 1-7 as applicable to Command responsibility, schema/RLS/outbox,
principal/approval, Phase/Release scope, public typed contracts and runtime invariants. The user's
direct XOR decision activates reversible local implementation only. The execution and STAR contracts
under `phase-12d/P12D-000/` become machine-authoritative when the matching execplan/Catalog cards bind
the selection, exact allowlists, commands and evidence. Formal acceptance and production authority
remain pending with the named owners.

## Trigger Evidence

Phase 12D may migrate One write entry only after an accepted Release B head and an immutable,
representative evidence window identify a named legacy write point. The window must quantify request
volume, concurrency conflicts, duplicate effects, unauthorized attempts, partial writes, repair load,
latency/SLA, compatibility population, recovery objectives, and data criticality. At activation,
`selected_write_entry=none`; TASK-P12D-010 must bind exactly one tracked-repository entry without
inventing production observations. Local expand-only schema work may follow a positive trigger, but
no production write is authorized.

P12D is eligible only if the evidence shows that a bounded migration improves an agreed primary
reliability or security result without worsening compatibility, latency, data integrity, privacy, or
operational recovery. Synthetic results can validate mechanics but cannot select the write entry.
A credible negative or underpowered result closes this candidate with allocation zero.

## Options and Decision

Options considered are: retain and harden the current writer; migrate every legacy writer at once;
introduce generic infrastructure first; or migrate one evidence-selected entry through a typed Domain
Command. The selected local-provisional decision chooses the fourth option for exactly one evidence-
selected entry. It authorizes the plan's reversible implementation and isolated tests, but no
production cohort, production write, remote push, Release acceptance, or Multi-Agent framework.

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

The user's direct local-provisional XOR record creates these serial tasks in the amended plan/Catalog:

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

P12D-990 is the local provisional verification task and P12D-999 is the local landing merge task.
Their execution does not confer formal acceptance or authorize a remote push.

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

TASK-P12D-010 must select exactly one causally matched primary before unblinding from a closed profile:
duplicate-effect rate, partial-write/event-loss rate, ambiguous-outcome repair minutes, or stale-
conflict partial-effect rate. Receipt coverage is the mechanism diagnostic and normal-write success is
the non-inferiority guard. Duplicate formal write, unauthorized/cross-tenant write, mutation/outbox
divergence and lost/ambiguous committed outcomes are zero-tolerance redlines, not an averageable
primary score. Fault injection proves mechanics but cannot by itself prove a production incident-rate
improvement. Without a named write entry and denominator, the STAR result stays measurement pending.

## Acceptance and Merge

Design readiness means the trigger and selection method, command invariants, principal/approval,
CAS/idempotency, transaction/outbox, receipt, compatibility, six atomic tasks, acceptance ID, merge ID,
and rollback are machine checked. It is not an accepted ADR, selected write entry, migration, or
production capability.

Formal acceptance still requires the applicable Release/REL-C evidence, governance receipt,
independent owner decisions, a named evidence-backed write entry, approved ADR/plan/migration review,
and the exact verified candidate object. The current local work starts from the recorded clean
specialist worktree and cannot satisfy those external decisions. Verification task: TASK-P12D-990.
Local merge task: TASK-P12D-999. P12A, P12B, and P12C remain unselected.

## Rollback

For this document-only package, revert its commit; runtime remains unchanged. A future implementation
uses Expand-contract rollback: stop new allocation, route the bounded cohort to the prior authorized
writer, retain new compatible columns/tables, idempotency records, receipts, and outbox evidence,
replay Release B equivalence, then diagnose. Cleanup happens only after the approved compatibility
window and restore proof. Rollback never drops data, reuses a stale approval, disables RLS, rewrites a
receipt, publishes an uncommitted event, or resurrects an expired worker.
