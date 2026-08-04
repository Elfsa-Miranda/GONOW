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

## Formal materialization dry run

The refreshed read-only three-way simulation used Phase 10 convergence candidate `1883c45e81ff32b07bac49bc62daa657e017c818`, Phase 11 provisional source `3ae846722e289166f5ff1079e92a83183962336d`, and their merge base `7b5913d53a65316b2c22a17cd52b8ee45562fae1`. The Phase 11 source changes 205 paths and the Phase 10 target changes 25 paths: 199 Phase 11 paths have no Phase 10 convergence overlap, two CI contract paths merge automatically, and exactly four governance paths produce content conflicts:

- `docs/execution/commands/Invoke-PhaseMerge.ps1`
- `docs/execution/commands/Invoke-TaskGate.ps1`
- `docs/execution/commands/tests/Invoke-PhaseMerge.Tests.ps1`
- `docs/execution/commands/tests/Invoke-TaskGate.Tests.ps1`

The path-by-path Git-object audit found zero mismatches across all 199 Phase11-exclusive blobs and all 19 Phase10-exclusive blobs. Both PhaseMerge blobs in the combined snapshot equal the Phase10 target exactly. The two CI paths equal Git merge-tree `6e27bef3c41de59870a4ff9c7e25152c23a75a0b` exactly, with zero auto-merge mismatch. The remaining two TaskGate blobs intentionally equal neither parent because they contain the regressed combined personal/formal and protected-release controls; they are the only governance content that must be selected from the combined snapshot during formal materialization.

The deterministic formal resolution is frozen as follows: retain the Phase 10 convergence versions of `Invoke-PhaseMerge.ps1` and its test; use the fully regressed combined versions of `Invoke-TaskGate.ps1` and its test from provisional integration `64b62ac9fbec745fa2e52011a9f3a218b1f20c08`; retain the automatically merged CI contract paths, the LF checkout contract, Phase10 historical-SBOM immutability repair `8b2380b57a3cfb82802641303e34da403b3b63b4`, locked-Dart/report-isolation repair `6662d7fb3e942c803ef1f84c0712c3378b8a8158`, protected-main fail-closed repairs `7e6c6de2213d2089663f399d6e649aaf0ac6dc29` and `6be069a9d6e11357a7c7c45610888daa81ce8221`, and the CAS settings enabler `f99620939e4de986566db682c0a771ffbef2a8e0`. The application-code snapshot at `9cc9aa96dd13e1f91c969ad80a5e3e6d27ad1b22` passed 695 Unit tests, 182 Contract tests, all mandatory quality/supply-chain gates, and a clean-worktree `0 -> 0` invariant. The refreshed combined control snapshot `64b62ac9fbec745fa2e52011a9f3a218b1f20c08` adds no application/runtime code and passed the isolated branch-protection adapter contracts plus the complete post-merge TaskGate suite, including P10-011/REL-C-001 protected, unprotected, force-enabled, CAS, overwrite-refusal, postcondition, receipt-redaction, and rollback cases. Formal P11-000/P11-990 status, runtime manifests, candidate OIDs, and attestations must be regenerated from the accepted Release B/REL-C-000 chain rather than copied as accepted facts. No `codex/phase-11-rag` ref or formal worktree may be created before REL-C-000 selects `phase11`.
