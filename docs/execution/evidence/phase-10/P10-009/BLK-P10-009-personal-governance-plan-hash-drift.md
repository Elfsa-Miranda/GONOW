# BLK-P10-009 — personal governance plan hash drift

- Status: open; blocks TaskGate status transition only. C1–C5 certification itself passed.
- First failure: `Invoke-TaskGate.ps1 -TaskId TASK-P10-009 -Mode Preflight` stopped before recording a pass with `Active governance profile validation failed`.
- Root cause: `docs/execution/evidence/governance/personal-automation-adoption-v1.json` binds `execplan.md` SHA-256 `94217c013ae1b84be05ae69c72cd235f1b63c908092377e287281a7a464da859`, while the inherited landing tree contains the later Phase 12-expanded plan SHA-256 `51f6ccc1cf1936f886f2f39cee3752ac41389fef3e0dc72204155e69710aaab7`.
- Eliminated paths: AGENTS, governance ADR, architecture digest, decision commit ancestry, and canonical remote all match. Every discovered sibling worktree contains the same v1 receipt; no valid successor receipt exists to reuse.
- Impact: the fail-closed governance checker cannot transition TASK-P10-009 from its historical blocked state to ready/accepted. It does not invalidate the candidate-bound C1–C5 results in `personal-release-certification.json`.
- Safety boundary: do not overwrite the v1 receipt, weaken hash validation, manually forge status, or relabel the certified candidate. A receipt/checker change would create a new candidate OID and must not reuse C1–C5 evidence as if it certified that new OID.
- Complete repair: add an authorized, additive successor receipt that binds the current guidance and records the supersedes chain; update the governance resolver through its approved CAS path; then certify the exact resulting candidate under unchanged C1–C5 thresholds before rerunning the eight affected TaskGate modes.
- Rollback: remove only the successor-receipt repair if it fails review; retain this blocker and all certification artifacts.
