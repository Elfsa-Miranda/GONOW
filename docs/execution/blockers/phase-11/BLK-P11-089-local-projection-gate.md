# BLK-P11-089 local projection gate mismatch

- Status: repaired locally; formal review remains pending.
- First reproduced command: `Invoke-TaskGate.ps1 -TaskId TASK-P11-089 -Mode WorkPreflight`.
- Failure: `p11_089_work_preflight_failed` with `accepted_implementation_task_count=0`, while Preflight proved `projected_implementation_task_count=10` and `implementation_terminal=true`.
- Root cause: P11-089 Preflight honored the `local_provisional` dependency projection, but WorkPreflight, Evidence, Documentation, Harness aggregation, and Handoff still required formal acceptance or an external reviewer.
- Impact: safe local convergence was blocked even though all ten implementation tasks were `ready_for_review` with complete mechanical gates. Formal acceptance, remote push, production rollout, and Release C authority were not affected.
- Excluded causes: implementation task gate failures, phase-base drift, Phase 12 branch activity, production writes, catalog drift, and missing local tests.
- Reversible repair: add local-only handlers that consume projected predecessors, execute a real isolated handoff regression, mark the implementer review and independent review status honestly, and leave every formal-mode branch unchanged.
- Regression scope: P11-089 Preflight, WorkPreflight, HandoffVerification, Documentation, HarnessCatalogAggregate, Evidence, Security, RollbackVerify, and WorksetVerify.
- Rollback: revert this repair commit; no schema, runtime, production data, remote ref, or release state changes are involved.
- Recovery condition: all local P11-089 modes pass with `satisfied_implementation_task_count=10`, while receipts continue to show `independent_review_status=pending_external` and `production_write_count=0`.
