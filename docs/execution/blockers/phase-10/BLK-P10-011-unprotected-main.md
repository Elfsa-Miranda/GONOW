# BLK-P10-011: `main` does not enforce the Release B required checks

- Severity: P1 release-control defect
- Status: repaired locally; remote configuration pending the authorized Release B action
- Affected action: TASK-P10-011 Release B pull-request merge only
- Production impact: none; no branch setting, push, pull request, merge, deployment, or production write was changed

## Reproduction and impact surface

An authenticated read-only GitHub query on 2026-08-04 returned repository admin/push permission but `GET /repos/Elfsa-Miranda/GO_NOW/branches/main/protection` returned HTTP 404 `Branch not protected`. The approved contract requires `main` to move only through the Release PR under platform required checks and forbids bypassing protected-branch policy. The existing live verifier queried the pull request, check runs, and Git commit trees, but could accept an unprotected branch when those three check runs happened to be green. The defect affects P10-011 and the structurally equivalent final Release C publication; it does not invalidate local Phase 10 or Phase 11 code/test evidence.

## Reversible repair

One shared evaluator now performs an authenticated, read-only branch-protection query for both P10-011 and REL-C-001 in addition to their existing live PR queries. Both fail closed unless `main` has the exact required check set (`agent-required`, `baseline-and-candidate`, `tracked-and-history`), strict head synchronization, administrator enforcement, pull-request-only changes, force pushes disabled, deletions disabled, and linear history disabled so the required two-parent merge remains possible. Missing `GH_TOKEN`/`GITHUB_TOKEN`, HTTP 404, an extra or missing required check, or any bypass setting is a release-gate failure. Both task requests record this configuration as a prerequisite and explicitly state that the current PR adapter is not authorized to manage branch protection.

The remote configuration is reversible through a separately authorized settings receipt. Until that receipt exists, only P10-011/Release PR merge is blocked; local certification, repair, Phase 11 materialization, and evidence work continue. Rollback of this code is a non-force revert, but reverting would restore the unsafe false-positive path and therefore cannot authorize a release.
