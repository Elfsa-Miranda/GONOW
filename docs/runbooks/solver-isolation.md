# Optional solver isolation runbook

Scope: Phase 7 local provisional OR-Tools child process. Production activation is not authorized.

## Normal state

The expected default is `enabled=False`; calls return `solver.disabled`, `optimized=false`, and a
valid original-order fallback. Canonical validation and bounded repair do not depend on the solver.
An authorized local exercise may set `enabled=True`; item counts below the trigger return
`solver.not_needed`, while larger problems run in a spawned child.

## First checks

1. Capture only the stable reason code, item count, bounded soft/hard deadlines, child PID/liveness,
   fallback-valid flag, exact behavior digest, and environment. Do not capture item text, Prompt,
   response, secret, tenant data, or reasoning.
2. Confirm `hard_timeout_seconds > soft_timeout_seconds`, both are within typed bounds, and item IDs
   and durations have equal unique lengths.
3. Confirm the parent process is alive and any timed-out child is gone. A surviving child is an
   incident and the enabled path must remain off.
4. Confirm `agent-service/uv.lock`, SBOM, license report, and vulnerability audit still bind the
   tested dependency graph.

## Failure routing

| Signal | Meaning | Safe action |
|---|---|---|
| `solver.disabled` | Feature is off | Continue canonical validation; no repair needed |
| `solver.not_needed` | Trigger not reached | Continue with original order |
| `solver.soft_timeout` | CP-SAT did not return a feasible result in its soft limit | Accept valid fallback; review sizing offline |
| `solver.hard_timeout` | Parent deadline elapsed and child was killed | Keep solver off; verify child gone and parent healthy |
| `solver.child_failed` | Child exited, IPC closed, or result was invalid | Keep solver off; inspect redacted process exit and dependency integrity |

Do not retry automatically. Do not widen deadlines in response to one failure. Establish a measured
cold-start distribution and an approved change before altering bounds.

## Disable and rollback

The first action is to construct `SolverProcessRunner(enabled=False)` or remove the enabled call
path. Verify the next result is `solver.disabled` with `fallback_valid=true`. If package rollback is
required, revert `solver_process.py`, its replay test and ADR, remove the exact OR-Tools dependency,
regenerate `uv.lock`, then repeat canonical/golden/repair regressions. No database or production
write is part of this rollback.

## Recovery gate

Re-enable only after CT-014 proves: the intentionally hung child is gone, the main process remains
alive, fallback remains valid, SSRF/tool-execution counts are zero, and exact dependency audit is
clean. Formal Security/SRE approval and production-like evidence are still required before any
production activation.
