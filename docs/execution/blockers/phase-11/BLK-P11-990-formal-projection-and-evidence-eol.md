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

The refreshed read-only three-way simulation used Phase 10 convergence candidate `68ec8dd3233e536ccd404c4d3306c6ed2d0b609b`, Phase 11 provisional source `3ae846722e289166f5ff1079e92a83183962336d`, their merge base `7b5913d53a65316b2c22a17cd52b8ee45562fae1`, and combined checkpoint `2a30e1caabc7c81214d78dc24cd4c38ec9467d62`. The Phase 11 source changes 205 paths and the Phase 10 target changes 42 paths: 199 Phase 11 paths and 36 Phase 10 paths are exclusive, two CI contract paths merge automatically, and exactly four governance paths produce content conflicts:

- `docs/execution/commands/Invoke-PhaseMerge.ps1`
- `docs/execution/commands/Invoke-TaskGate.ps1`
- `docs/execution/commands/tests/Invoke-PhaseMerge.Tests.ps1`
- `docs/execution/commands/tests/Invoke-TaskGate.Tests.ps1`

The path-by-path Git-object audit found zero mismatches across all 199 Phase11-exclusive blobs and all 36 Phase10-exclusive blobs. Both PhaseMerge blobs in the combined snapshot equal the latest Phase10 target exactly. The two CI paths equal Git merge-tree `35d69ebc71dfa07b60a8f2a751e8b1c10cbd3709` exactly, with zero auto-merge mismatch. The remaining two TaskGate blobs intentionally equal neither parent nor the conflict-marker merge tree because they contain the fully regressed combined personal/formal, protected-release, atomic-push, owner-canary, and credential-provider controls; they are the only governance content that must be selected from the combined snapshot during formal materialization.

The deterministic formal resolution is frozen as follows: retain the Phase 10 convergence versions of `Invoke-PhaseMerge.ps1` and its test; use the fully regressed combined versions of `Invoke-TaskGate.ps1` and its test from provisional integration `2a30e1caabc7c81214d78dc24cd4c38ec9467d62`; retain the automatically merged CI contract paths, the LF checkout contract, Phase10 historical-SBOM immutability repair `8b2380b57a3cfb82802641303e34da403b3b63b4`, locked-Dart/report-isolation repair `6662d7fb3e942c803ef1f84c0712c3378b8a8158`, protected-main fail-closed repairs `7e6c6de2213d2089663f399d6e649aaf0ac6dc29` and `6be069a9d6e11357a7c7c45610888daa81ce8221`, the CAS settings enabler `f99620939e4de986566db682c0a771ffbef2a8e0`, the request-hash-CAS Release B/Release C PR adapter `cc3b4212d90b0452e0633f4b27901fbcff16e11e`, the label-ID-CAS release-label adapter `238f3c970e61618e69b5ef33e1d639527d81a1f9`, the atomic non-force PhaseMerge Push repair `d362ddaafc3c7f71e6196017d5d964df469cf19a`, the measured owner-canary HTTPS/SecretManagement adapter repair `b7c1528ebfbd5cdc833ce59501b7cdcac7da33e8`, and the noninteractive Git Credential Manager fallback `fb49ce5df36d68bd2e2b366697c01761b1635f29`. The owner-canary repair supplies all seven executable adapter slots while keeping the real endpoint, owner identity, credential-vault reference, budget reference, and deployment-private relay fail closed; the credential fallback keeps environment-token precedence and otherwise reads only fixed-host `github.com` credentials with prompts disabled and no credential output. The application-code snapshot at `9cc9aa96dd13e1f91c969ad80a5e3e6d27ad1b22` passed 695 Unit tests, 182 Contract tests, all mandatory quality/supply-chain gates, and a clean-worktree `0 -> 0` invariant. The refreshed combined control snapshot `2a30e1caabc7c81214d78dc24cd4c38ec9467d62` adds no application/runtime code and passed the isolated credential-provider suite plus the complete post-merge TaskGate suite in 93.5 seconds, including main-protection, release-label, Release B/Release C PR, atomic bare-remote phase-push, owner-canary HTTPS/credential, GCM fallback, CAS, redaction, tamper rejection, and scoped rollback contracts. The staged tracked-source scans for the adapter repairs recorded zero valid secret findings, zero secret-value output, and zero untracked-file reads. Formal P11-000/P11-990 status, runtime manifests, candidate OIDs, and attestations must be regenerated from the accepted Release B/REL-C-000 chain rather than copied as accepted facts. No `codex/phase-11-rag` ref or formal worktree may be created before REL-C-000 selects `phase11`.
