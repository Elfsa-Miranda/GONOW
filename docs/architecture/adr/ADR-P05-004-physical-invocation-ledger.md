# ADR-P05-004: Atomic physical invocation ledger

- Status: local provisional decision; formal Security, Data, and Finance approval pending
- Date: 2026-08-01
- Owners: Reliability, Security, Data, Finance
- Scope: Phase 5 physical Tool invocation reservation and result receipts

## Context

GoNow uses at-least-once Job delivery. A Worker can therefore die after reserving a Tool call, after the provider has produced a side effect, or before the result is persisted. An in-memory counter, a checkpoint-only marker, or a reservation held in the same uncommitted transaction as an external handler would disappear on process death and permit a second physical call.

The governing contract requires the budget condition update and reservation to be atomic in PostgreSQL before the real handler, uniqueness on `(run_id, tool_call_id)`, replay for an identical fingerprint, conflict for a changed fingerprint, and no refund when a third-party outcome is unknown. Runtime writes must remain tenant-scoped, audit-bound, and protected from a stale fencing token.

## Decision

1. Add `agent_runtime.invocation_budgets` as the per-Run immutable physical-call limit and monotonic reservation counter. The first reservation creates the row; later callers must present the same limit. PostgreSQL row locking serializes all reservations for one Run.
2. Add `agent_runtime.physical_invocations` with a unique `(run_id, tool_call_id)` key. It stores only canonical digests, bounded identifiers, result references, safe error codes, audit receipt identifiers, and database timestamps. Prompt, request, response, secret, reasoning, and arbitrary provider bodies are excluded.
3. Reserve by locking the budget row, checking an existing call, conditionally incrementing the counter, and inserting the invocation in one transaction. That transaction commits before the external handler is eligible to run.
4. Classify the first reservation as `execute`; an identical terminal record as `replay`; and an identical still-`reserved` record as `reconcile`. A reserved replay never calls the handler because the prior external outcome may be unknown.
5. Treat `succeeded`, `failed`, and `unknown_outcome` as immutable terminal invocation states. `unknown_outcome` and known failure both retain the consumed physical reservation. A retry must use a new Tool call ID and consume another available reservation.
6. Enforce tenant RLS and least-privilege Worker/observer grants. Database triggers make the Run budget limit immutable, prevent counter decrement or jumps, enforce legal invocation transitions, and require the current live Job lease/fencing identity for reservation and completion.
7. Expose bounded failure-injection hooks only inside the ledger coordinator so Phase 5 replay tests can stop after reservation or after the handler but before persistence. Production process termination is outside this task.

## Alternatives considered

| Option | Safety and data | Compatibility | Cost and rollback | Decision |
|---|---|---|---|---|
| In-memory or checkpoint counter | Lost on crash; cannot serialize concurrent branches | Simple | Low cost, unsafe recovery | Rejected |
| One invocation table with `count(*)` as budget | Concurrent scans and inserts make the budget condition harder to prove and lock | PostgreSQL-only | Fewer rows, weaker invariant | Rejected |
| Redis reservation | Adds a second recovery truth and violates the target fact-source boundary | Operationally familiar | Additional service and split-brain recovery | Rejected |
| PostgreSQL budget row plus invocation ledger | Atomic, tenant-scoped, auditable, fenceable | Fits existing SQLAlchemy/Alembic runtime | Two tables; clean isolated downgrade | Selected |

## Consequences and controls

- Reservation throughput for one Run is intentionally serialized. The Release B limit is small and the correctness boundary is more important than intra-Run reservation throughput.
- The numeric limit is supplied from the Run-pinned Behavior contract. The database does not hard-code the current eight-call initial hypothesis, but it prevents changing the selected limit during the Run.
- `reserved` after a crash is not guessed to be success or failure. It requires reconciliation and blocks blind replay.
- Formal approval remains required before merge, push, production use, or acceptance. Local PostgreSQL implementation and tests remain provisional.

## Rollback

Stop Tool execution, preserve invocation evidence for reconciliation, downgrade only the P05-004 Alembic revision, and revert the repository/model files. The prior checkpoint, Job, Lease, Run, Event, and outbox schemas remain intact. Do not refund or replay any external call whose outcome is unknown during rollback.
