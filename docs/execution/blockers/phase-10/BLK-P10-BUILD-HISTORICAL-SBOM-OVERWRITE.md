# BLK-P10: current build overwrote historical Phase 2 SBOM

- Severity: P1 evidence-integrity defect
- Status: repaired locally
- Affected action: Release B fresh-worktree locked build and clean-tree acceptance regression
- Production impact: none; no deployment, production write, allocation, merge, or remote push occurred

## Root-cause closure

The clean-worktree reproduction synced the current 96-package lock and passed six entrypoint tests, then wrote that current environment into the immutable Phase 2 SBOM path. The Phase 2 bootstrap script had retained a phase-scoped output target after later phases extended `agent-service/uv.lock`; this confused a current derived artifact with historical evidence and dirtied every later worktree that ran the documented build.

Current builds now write the derived SBOM beneath ignored `agent-service/.venv/artifacts/`. Before and after build, the script verifies the historical file through canonical Git blob `4ace79e826a8cad4232f7c41c3c17afca7e9402c`, which is stable for legacy CRLF and fresh LF worktrees, and rejects an explicit historical output target. The TaskGate regression proves rejection and byte preservation. Rollback is a non-force revert; Release B remains disabled until an equivalent immutable-output repair passes the affected build and TaskGate regression.
