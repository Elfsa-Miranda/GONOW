# BLK-P10-011: the release PR external action had no executable adapter

- Severity: P1 release-control gap
- Status: repaired locally; remote prerequisites remain explicit
- Affected actions: TASK-P10-011 and TASK-REL-C-001 only
- External changes during repair: zero

## Reproduction and root cause

The TaskGate runner already materialized strict `pr-request.json` files and independently verified a fresh `pr-observation.json`, GitHub pull request, required checks, merge commit, tree, and branch protection. Its workset contract, however, referred only to the abstract capability `github_authorized_external_action`; no tracked executable implemented that capability. Once all earlier release gates passed, an operator would still have needed to assemble PR creation, labels, polling, merge, observation, and command-ledger evidence manually. That late manual seam affected both Release B and Release C publication, but no application/runtime behavior or production data.

## Reversible repair

`docs/execution/commands/Invoke-GitHubReleasePullRequest.ps1` implements the missing boundary. `Plan` and `RollbackPlan` are externally read-only. `Apply` accepts only the two exact TaskGate request paths, requires an expected request SHA-256, opaque authorization reference and actor id, and uses only a process-scoped token. Before any PR mutation it proves the remote landing/main OIDs, exact protected-main contract, and existence of every requested repository label. It never pushes a ref, configures branch protection, creates label definitions, deletes a branch, requests a reviewer, or force-updates anything.

For an authorized Apply it creates or updates one exact PR, sets the exact label set, waits for the three required checks, re-reads every CAS input, and invokes the GitHub merge endpoint with the exact head SHA and `merge_method=merge`. It then proves a closed merged PR, exactly two parents in base/head order, merge-tree equality with the attested landing head, unchanged landing ref, main at the merge commit, zero review requests, zero branch deletion, and the same successful check set. Only then does it atomically write the bounded observation and the exact TaskGate external-action command row. A rerun can reconstruct the same observation from an already merged exact PR without a second mutation. Rollback remains a separately authorized non-force revert of the exact merge commit.

## Remaining remote prerequisites

A read-only GitHub query on 2026-08-04 found that `main` is unprotected and the required release labels are not defined. The existing CAS branch-protection adapter covers the first prerequisite after a separate settings authorization. Required labels are `automated-merge-authorized` plus `release-b` for Release B, and `automated-merge-authorized`, `release-c`, and `single-capability` for Release C. This PR adapter deliberately fails before PR creation if either prerequisite is missing; it does not silently expand the task into repository-settings management.

## Regression and STAR boundary

The fake-isolated suite covers request validation, missing-label Plan, request-hash CAS, protected-branch rejection before mutation, exact outbound PR/label/merge-CAS bodies, create/label/check/merge success, title/body request binding, token redaction, mutation-free already-merged recovery, failed checks without merge, wrong-tree rejection, command-ledger binding, and Release C single-capability validation. It is invoked by the complete TaskGate contract suite and `agent-required` workflow. This is governance capability evidence, not a production behavior-improvement claim; `behavior_improvement_claim=not_applicable`.
