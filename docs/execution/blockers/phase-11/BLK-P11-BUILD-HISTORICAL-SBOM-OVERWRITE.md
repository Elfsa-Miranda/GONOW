# BLK-P11: current build overwrote historical Phase 2 SBOM

- Severity: P1 evidence-integrity defect
- Status: repaired locally
- Affected action: fresh-worktree locked build and all later acceptance regressions that require a clean tree
- Production impact: none; no deployment, production write, allocation, merge, or remote push occurred

## Reproduction

Run `agent-service/scripts/build.ps1` from a clean post-Phase-2 worktree. Dependency sync and six entrypoint tests pass, but the script writes the current 96-package environment into `docs/execution/supply-chain/phase-02/P02-001/agent-service.cdx.json`. The worktree becomes dirty and the historical artifact no longer matches canonical Git blob `4ace79e826a8cad4232f7c41c3c17afca7e9402c`.

## Root cause and impact surface

The Phase 2 bootstrap script retained a hard-coded phase-scoped output path after later phases extended `agent-service/uv.lock`. A normal current build therefore confused a current derived SBOM with immutable Phase 2 evidence. The defect affects evidence integrity and clean-worktree gates; it does not alter runtime behavior or the locked dependency set.

## Reversible repair and regression

Current builds now write their derived SBOM beneath ignored `agent-service/.venv/artifacts/`. The build verifies the Phase 2 artifact through Git's canonical clean filter before and after execution and rejects an explicit attempt to select that historical path. This remains stable for both legacy CRLF worktrees and fresh LF worktrees; the original Phase 2 receipt's raw SHA-256 is retained as historical evidence rather than treated as a portable checkout hash. The TaskGate regression asserts the canonical blob, default current output path, rejection code, and byte preservation. Rollback is a non-force revert of this repair commit; doing so must leave acceptance and remote publication disabled until the historical overwrite defect is fixed another way.
