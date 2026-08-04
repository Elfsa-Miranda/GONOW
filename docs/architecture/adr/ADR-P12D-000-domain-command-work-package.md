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

TASK-P12D-010 selected exactly one tracked-repository write point:
`flutter:ItineraryProvider.updateItineraryBasicInfo:user_itineraries`. The tracked implementation
updates provider state and local cache before issuing a Supabase update, does not carry an
expected-version predicate, and does not propagate the asynchronous result to its sole tracked UI
caller. These are repository facts and establish a positive local mechanism trigger. Production
volume, conflict and incident rates, database schema, RLS, SLA and recovery behavior remain
`unknown`/`measurement_pending`; no production write is authorized.

The frozen primary is `stale_conflict_partial_effect_rate_per_10k_intents`. TASK-P12D-050 compares the
tracked legacy behavior and candidate against identical isolated fixtures, seed `12040010`, 10,000
stale-conflict intents per arm, concurrency order and failure classification. This can establish a
local controlled-mechanism improvement only. It cannot establish a production-rate improvement; the
production measurement remains pending even if every local gate passes.

## Options and Decision

Options considered are: retain and harden the current writer; migrate every legacy writer at once;
introduce generic infrastructure first; or migrate one evidence-selected entry through a typed Domain
Command. The selected local-provisional decision chooses the fourth option for exactly one evidence-
selected entry. It authorizes the plan's reversible implementation and isolated tests, but no
production cohort, production write, remote push, Release acceptance, or Multi-Agent framework.

The selected command is `itinerary.basic_info.update` schema `1.0`. It accepts command ID, stable
idempotency key, target itinerary ID, expected version and a closed Basic Info patch only. Tenant,
principal, user, role, approval, force-overwrite, raw row, arbitrary plan data, prompt, reasoning and
tool-result fields are forbidden. The model may only propose a Candidate. Principal and tenant come
from authenticated `RequestContext`. This Basic Info command is classified by the server-owned,
versioned low-risk policy `policy:itinerary.basic_info.low-risk:v1`; it requires no client approval
token and cannot be promoted to a higher-risk operation by request data.

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
5. P12D-050 proves legacy/new equivalence, concurrency, retry, crash, replay, restore, denial and
   rollback in the isolated controlled workload, including the frozen 10,000-intent arms.
6. P12D-060 connects only the selected Flutter write point behind a default-off flag, proves local
   routing and rollback, and leaves production allocation at zero.

P12D-990 is the local provisional verification task and P12D-999 is the local landing merge task.
Their execution does not confer formal acceptance or authorize a remote push.

## Security and Privacy

The server derives principal and tenant from verified identity and maintains tenant scope through
authorization, SQL transaction, RLS, outbox, receipt, and replay. Approval is explicit, versioned,
unexpired, command-specific, and independently auditable when a different high-risk command requires
it; this selected low-risk Basic Info command uses the frozen server policy reference instead. Denial
is fail closed.
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

TASK-P12D-010 froze `stale_conflict_partial_effect_rate_per_10k_intents` before candidate measurement.
Both local arms use 10,000 intents and retain every failed run in the denominator. Receipt coverage is
the mechanism diagnostic and normal-write success is the non-inferiority guard. Duplicate formal
write, unauthorized/cross-tenant write, mutation/outbox divergence and lost/ambiguous committed
outcomes are zero-tolerance redlines, not an averageable primary score. Fault injection proves
mechanics but cannot prove a production incident-rate improvement. STAR therefore reports
`claim_scope=local_controlled_mechanism` and `production_improvement_claim=false`; production remains
`measurement_pending`.

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

Until P12D-060 routing, the typed contract is dormant and rollback is removal of the unreferenced
candidate contract after retaining its digest and evidence. Once routing exists, Expand-contract
rollback stops new allocation, returns new intents to the prior authorized writer, retains compatible
tables, idempotency records, receipts and outbox evidence, and diagnoses from the durable outcome.
Cleanup happens only after an approved compatibility window and restore proof. Rollback never drops
data, reuses stale authority, disables RLS, rewrites a receipt, publishes an uncommitted event, falls
back after an ambiguous commit, or resurrects an expired worker.
