# Worker recovery runbook

## Authorization and first action

This runbook is executable in a local isolated environment or an explicitly authorized target.
For an incident, first turn Agent routing off and stop new Worker allocation while preserving Run,
Event, Job, Lease, checkpoint, invocation, budget, and audit rows. It does not authorize production
termination, database writes, deletion, or acceptance.

## Start and health check

1. Confirm the intended environment, tenant, PostgreSQL endpoint, API role, and Worker role without
   copying credentials into evidence.
2. Verify PostgreSQL readiness and migration head. PostgreSQL is the only recovery source.
3. Start the API and confirm lifecycle/readiness using its least-privilege role.
4. Start one Worker identity. Verify it claims one ready Job, creates one live Lease, and records a
   positive fencing token. A duplicate request with the same holder must replay the same claim.
5. Verify heartbeat advances expiry using database time and that a deliberately stale token is
   rejected before enabling routing.

For the full local PostgreSQL-only rehearsal, run from the repository root:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\agent-service\scripts\test_full_recovery.ps1
```

Review the structured report, not only the process exit. Require a legal terminal Run and zeros for
budget delta, duplicate side effects, orphan processes, orphan database records, missing audit
receipts, skipped cases, xfails, and Redis runtime dependencies.

## Recover a stopped Worker

1. Record the managed service identity and confirm the old process is stopped through the approved
   service manager. Never act on an unverified numeric PID supplied by a caller.
2. Wait for the database lease to expire; do not edit expiry or reuse the old holder.
3. Start a new Worker identity. It must reclaim through `SKIP LOCKED`, expiry CAS, and a strictly
   larger fencing token.
4. Classify the invocation ledger before any physical handler call: replay a terminal receipt;
   reconcile `reserved`; preserve `unknown_outcome` without refund or blind retry.
5. Load the latest checkpoint only after tenant/run/job/holder/fence validation. Reject unknown
   envelope versions and any payload containing a forbidden raw object or secret field.
6. Run one bounded reconciler pass if stale Job/Run/Lease rows remain. Confirm an audit Event for
   each applied repair and no change to a live owner.
7. Compare Run state, physical budget, and side-effect counts before/after. Re-enable routing only
   after the authorized owner confirms the structured postconditions.

## Failure triage

- No claim: inspect `available_at`, attempt count, state, tenant, and current lease before retrying.
- Lease does not reclaim: compare database time, expiry, holder, and fence; do not weaken the CAS.
- Checkpoint fails: inspect envelope version, content digest/reference, current fence, and RLS role.
- Invocation stays reserved: preserve provider evidence and reconcile; ambiguity becomes
  `unknown_outcome`.
- Run remains active with no owner: run one bounded reconciler pass, read its audit classification,
  and diagnose the distinct remaining state rather than looping.
- Duplicate effect, budget increase, stale write, or cross-tenant result: keep routing off, preserve
  evidence, and escalate to Security+Data immediately.

## Disable and rollback

Disable by keeping the Agent flag off and stopping Workers. Route to the existing non-Agent path.
Do not delete or rewrite durable rows. If a Phase 5 code rollback is approved, drain valid leases,
preserve invocation/checkpoint evidence, and apply the migration-specific downgrade procedure only
after the isolated downgrade proof is repeated against the exact candidate. Redis is not a fallback.
