# BLK-P11-990: personal formal projection and cross-worktree evidence identity

- Severity: P1 release-control defect
- Status: repaired locally
- Affected action: `TASK-P11-990` personal automated formal attestation and downstream `TASK-P11-999`
- Production impact: none; production writes, allocation, merge, and remote push remained zero

## Reproduction

1. Check out the Phase 11 candidate in a fresh Windows worktree with `core.autocrlf=true`.
2. Compare the SHA-256 values in `phase-11/artifact-manifest.premerge.json` with the worktree bytes. Before the repair, all 12 listed text artifacts drifted after checkout even though Git reported a clean tree.
3. Evaluate `Get-P11990DependencyState` with `ExecutionMode=formal_adopted` and the approved `personal_automated` profile. The P11-990 mode handlers selected the personal attestation path, but predecessor aggregation still rejected every complete `ready_for_review` P11 task because it required enterprise-style independent `accepted` status.

## Root cause and impact surface

The repository did not define a global LF checkout contract for hashed text artifacts, so byte hashes generated in the originating worktree were not portable to a fresh worktree. Independently, the personal P11-990 routing change did not propagate its governance scope into predecessor-state evaluation. The combined impact was a false formal gate failure after Release C selected Phase 11; it did not weaken any runtime or security boundary.

## Reversible repair

- Declare LF checkout for repository text formats in `.gitattributes`, while preserving `-text` overrides for immutable bootstrap inputs and `TaskGateCatalog.psd1`.
- Allow `ready_for_review` predecessor projection only when `Get-P11990DependencyState` proves `formal_adopted + personal_automated`; require exact task id, ancestor status head, status-to-gate SHA binding, valid artifact evidence, every mandatory gate passed, and `reviewer_independent=false`.
- Keep enterprise formal execution unchanged and fail closed. The projection does not mark predecessor tasks independently reviewed or accepted; only the candidate-bound P11-990 automated attestation can accept the aggregate.

## Regression and rollback

The TaskGate suite contains positive local/personal cases and negative enterprise, hash-drift, artifact, and gate predicates. A fresh worktree must reproduce every recorded Phase 11 text hash at its bound Git snapshot. Rollback is a non-force revert of this repair commit; doing so restores the prior fail-closed behavior and must leave Release C allocation at zero.
