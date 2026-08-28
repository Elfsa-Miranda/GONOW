# No-Redis PostgreSQL recovery

## Scope and safety

GoNow Phase 5 restores durable Agent work from PostgreSQL. Redis is not a runtime dependency or recovery source. This runbook covers the API/Worker restart path for a non-production or explicitly authorized environment; it does not authorize production process termination, production writes, deletion of Runs, blind replay of an unknown external result, or bypass of lease/fencing checks.

Stable owners: SRE operates the restart; Reliability owns convergence; Security is escalation owner for duplicate side effects, missing audit receipts, cross-tenant access, or an unexpected process target.

## Healthy recovery contract

After an API or Worker restart:

1. PostgreSQL remains reachable and is the only durable recovery source.
2. A new Worker claims an expired Job with a newer fencing token.
3. The old Worker cannot write after the new claim.
4. A completed physical invocation replays its persisted result without another handler call or budget reservation.
5. A reserved invocation with an unknown external outcome is reconciled; it is not blindly retried.
6. Every Run reaches a legal terminal or explicitly recoverable state, with no orphan process, Job, or Lease.
7. `budget_delta=0`, `duplicate_side_effect_count=0`, `missing_audit_receipt_count=0`, and `redis_runtime_dependency_count=0`.

## Local rehearsal

From the repository root:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\agent-service\scripts\test_full_recovery.ps1
```

The script is fail-closed to the task-owned evidence directory. It runs the real PostgreSQL recovery scenario, emits `direct-pytest.xml` and `no-redis-recovery-report.json`, and scans `agent-service/app`, `pyproject.toml`, and `uv.lock` for a Redis runtime dependency. A successful command alone is insufficient; inspect the structured report and require every numeric postcondition above.

## Operational sequence

1. Stop new Agent routing or disable the Agent feature flag. Do not delete Run, Event, Job, Lease, checkpoint, invocation, or audit rows.
2. Confirm PostgreSQL readiness, current database identity, and the environment/tenant in scope. Do not paste credentials into logs or evidence.
3. Stop the affected Worker using the approved service manager. Record the exact service identity and exit status; never accept a caller-supplied arbitrary PID.
4. Restart the API and validate its lifecycle/readiness. The API must re-read Run state using its tenant-scoped database role.
5. Start a new Worker. Let it reclaim only expired Jobs through `SKIP LOCKED`, database time, lease CAS, and a strictly newer fencing token.
6. Classify the physical invocation ledger before any handler call:
   - `succeeded` or `failed`: replay the persisted receipt without another physical call.
   - `reserved`: reconcile the external outcome; if the outcome cannot be proven, persist `unknown_outcome` and do not refund or retry blindly.
7. Resume from the latest fenced checkpoint when present. Reject any late write carrying the old holder or fencing token.
8. Run the bounded reconciler for stale Run/Job/Lease records. Confirm legal Run state, audit receipt presence, and zero orphan records.
9. Compare physical budget and side-effect counters before/after recovery. Any nonzero delta or duplicate is a P0 release blocker.
10. Re-enable routing only after the structured recovery checks pass and the authorized operator records the decision.

## First checks on failure

- PostgreSQL unavailable: keep routing off, verify the approved database endpoint and restore service; do not add Redis as an emergency truth source.
- Lease will not reclaim: inspect database time, `expires_at`, current fencing token, and holder. Do not shorten safety constraints or edit a live lease without an approved incident procedure.
- Invocation remains `reserved`: preserve the row and external receipt evidence, classify the outcome, and prefer `unknown_outcome` over a blind call.
- Old Worker can still write: stop all new Worker allocation, preserve evidence, and escalate to Security+Data immediately.
- Duplicate side effect or budget increase: treat as P0, keep routing off, preserve ledger/Run/Event evidence, and do not rerun the handler.
- Run remains nonterminal: run the bounded reconciler once, inspect its audit event and CAS result, then diagnose the distinct remaining state; do not loop indefinitely.

## Rollback

The first rollback action is to stop Workers and route traffic to the existing non-Agent path while preserving PostgreSQL rows. The local rehearsal rolls back by dropping only task-owned test schemas. Production rollback never restores an old Worker lease, deletes a Run, refunds an unknown physical invocation, or replaces PostgreSQL with Redis.
