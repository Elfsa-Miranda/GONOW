# TASK-P03-002 runner enabler

- Recorded at: `2026-08-01T05:28:08+08:00`
- Execution mode: `local_provisional`
- Assumption: the sealed 1.4.0 task card requires exact `Verify`, `Security`, `WorksetVerify`, `Evidence`, and `RollbackVerify` results, while the inherited runner has task-specific adapters only through `TASK-P03-001`.
- Reproduction: the first post-implementation gate pass returned BOOT-only assertions for `Verify`, classified all ten P03-002 paths as unexpected in `Security`, and returned `pending_task_specific_implementation` for `RollbackVerify`.
- Root cause: the Catalog declares the modes, but `Invoke-TaskGate.ps1` lacked the P03-002 dispatch adapters that turn the card's literal assertions into mechanical checks.
- Impact: mechanical acceptance evidence was invalid for this task; the runtime implementation and its eight PostgreSQL tests were unaffected.
- Reversible repair: add a P03-002-only adapter for the five modes plus Harness 25 fragment generation. The adapter reads only the task allowlist and isolated PostgreSQL report, recognizes the runner itself solely as this local enabler, and leaves the Catalog and product contract unchanged. The same enabler resolves `ci.ps1` report roots before its internal directory change so a caller-provided relative evidence directory cannot drift under `agent-service/`, and pins Agent PowerShell sources to LF so their content hashes survive clean Windows worktrees.
- Rollback: revert the enabler patch after an equivalent approved runner implementation supersedes it. Reverting the runtime candidate remains an independent additive migration downgrade/forward-fix operation.
- External effects: none. No remote push, production connection, production write, deployment, approval, or `accepted` transition occurred.
