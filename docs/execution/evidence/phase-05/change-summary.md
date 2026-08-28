# Phase 5 change summary

Before Phase 5, PostgreSQL persisted Runtime records but the Worker had no complete durable claim,
lease/fencing recovery, LangGraph-compatible checkpoint saver, physical Tool invocation ledger,
bounded orphan reconciler, or real process-kill replay proof. Phase 5 adds those local boundaries.

Observable local differences:

- ready Jobs are claimed with `SKIP LOCKED`; ten claimers gave each of six Jobs exactly one owner;
- lease heartbeat/reclaim uses database time, holder identity, CAS, and monotonic fencing;
- checkpoint state is canonical, content addressed, versioned JSON under current tenant/job/fence;
- physical Tool calls reserve budget and fingerprint before execution; terminal results replay and
  unknown outcomes are not refunded or blindly retried;
- the reconciler applies bounded, audited, CAS-protected repairs while preserving live owners;
- seven real process-termination boundaries cover reservation, result, checkpoint, and terminal
  persistence; all old-Worker writes were denied and CT-005/CT-006 passed;
- API/Worker restart recovered one Run from PostgreSQL only with zero budget delta, duplicate side
  effect, orphan process/database row, or Redis dependency; and
- Harness controls 18 and 24 move to implemented; control 34 receives the Phase 5 lease/fencing
  regression extension. The first-phase-through-P5 unimplemented Harness count is zero.

The public OpenAPI and Flutter/Dart contracts are unchanged. All implementation tasks are local
`ready_for_review`; independent review, production validation, push/merge, deployment, and
`accepted` remain pending.
