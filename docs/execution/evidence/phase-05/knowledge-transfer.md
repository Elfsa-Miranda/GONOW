# Phase 5 knowledge transfer

## Responsibilities and dependency choices

`app.persistence.repositories.jobs` owns durable claim and fence CAS. `app.worker.lease` owns one
transaction per heartbeat/reclaim; `app.runtime.checkpoint` owns the locked LangGraph v1 adapter;
the invocation repository owns pre-call reservation and replay classification; the reconciler owns
bounded orphan repair. PostgreSQL is the only recovery source. The chosen direct LangGraph pin and
GoNow saver are recorded in ADR-P05-003; Redis, an external queue, pickle, and another Agent were not
introduced.

## Hardest items

1. Windows virtual-environment launchers did not provide a stable physical child identity. The
   repaired harness launches the base interpreter, proves process-handle/PID identity before kill,
   and never targets a later process by recycled PID. The STAR record contains before/after evidence.
2. The physical invocation boundary had to distinguish reservation, persisted result, and unknown
   external outcome without double charge, blind replay, or lost evidence across a kill.
3. PostgreSQL-only recovery had to combine new-fence reclaim, checkpoint and ledger replay, API role
   reads, legal terminal transition, and bounded cleanup while leaving durable history intact.

## Operations must know

Keep Agent routing off before Worker recovery. Verify database identity, then inspect Run, Job,
newest Lease, checkpoint, invocation, budget, and audit Event. Never reuse an old holder/fence,
refund an unknown outcome, delete a Run to retry, or add Redis as an emergency truth source. A stale
write, duplicate side effect, budget increase, missing audit receipt, or tenant mismatch keeps routing
off and escalates to Security+Data.

## Estimate comparison

The task-card estimates are person-day ordering inputs. Local automation produced deterministic
implementation and isolated PostgreSQL evidence in one continuous run, but that is not comparable to
independent owner review, production rollout, traffic observation, incident readiness, or measured
RPO/RTO. Those activities remain unknown and are not claimed as completed or saved time.

## Handoff verification

The local handoff reruns Job claim, lease/fencing, checkpoint, invocation ledger, reconciliation,
process-kill/replay, PostgreSQL-only recovery, and Harness controls 18/24/34 without skips or xfails.
Its receipt records exact test counts and postconditions. The implementer performs this run, so
`reviewer_is_implementer=true`; independent SRE+Data+Security handoff remains `pending_external` and
local success is not formal acceptance.
