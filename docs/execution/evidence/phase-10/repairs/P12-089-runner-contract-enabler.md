# P12-089 runner contract enabler repair receipt

- Recorded: 2026-08-02 (Asia/Shanghai)
- Classification: Phase 10 local-provisional repair/enabler for a future conditional Phase 12 task
- Candidate branch: `codex/phase-10-release-b-gates`
- Candidate base before this repair: `d5934b0a2696b8e84e075d16a5d52f99a94c95eb`
- Execution boundary: local implementation and contract tests only; no Phase 12 selection, specialist branch, status, evidence, merge, push, production write, or acceptance was created
- Formal state: pending external governance, owner approvals, independent review, and the real Release C evidence chain

## Reproduction

The conditional-task inventory showed that `TASK-P12-089` existed in the 153-task Catalog but its ten mandatory gate modes were not registered or specialized. A future invocation could therefore fall through to a generic pending handler instead of enforcing Release C convergence.

The first complete inspection also exposed four related failures in the same execution boundary:

1. The static prerequisite list represented all four optional work packages as mandatory, although the governing contract permits exactly one selected package or `none`.
2. Existing P12-000, P12-001, P12-002, and P12A-D evidence handlers referenced `New-ArtifactHashesDocument` and `$ArtifactPath` before either was defined. The defect was dormant only because formal dependencies had not yet allowed those handlers to execute.
3. The P12 work-package dependency validator required an accepted status `head_oid` to equal the current candidate HEAD. Once a status commit is followed by the convergence commit, that relation is self-referential and impossible; the immutable accepted status must instead be an ancestor of the current candidate.
4. The first P12-089 Preflight implementation summed every integer telemetry field. A valid selected shape has `selected_count=1`, `accepted_work_package_count=1`, and `materialized_work_package_count=1`, so the implementation would incorrectly block the only legal non-`none` shape.

A negative public-dispatch probe used the next still-unimplemented task, `TASK-REL-C-001 Preflight local_provisional`. It exited `2` with `conditional_task_runner_unimplemented:TASK-REL-C-001:Preflight`; status-row counts remained `3 → 3`, and no task evidence directory or status file was created. This proves the registry guard still fails before materialization.

## Root cause and impact surface

The Catalog had advanced ahead of runner coverage. Static dependency expansion could not represent a conditional XOR, while evidence and status checks had copied assumptions that were safe only at an earlier commit boundary. The impact surface was the future P12-089 gate dispatch, all four dormant P12 work-package evidence paths, convergence documentation, Harness/board aggregation, and the no-selection branch. No current product runtime, database, Flutter code, production state, or remote ref was affected.

## Reversible repair

- Registered exactly the ten P12-089 modes required by the execution plan and added a dedicated handler for each.
- Reduced the static prerequisite to P12-002 and moved the dynamic `none/zero` versus `one matching accepted package` rule into a pure convergence validator.
- Rejected materialization of unselected packages and rejected any P12 specialist branch or worktree during convergence.
- Added the missing artifact helper and task evidence path shared by the already-specialized P12 handlers.
- Changed accepted P12-002 status binding from HEAD equality to a Git ancestor proof.
- Limited Preflight failure arithmetic to actual failure counters; valid selection telemetry is now observational only.
- Bound P12-089 write targets to convergence documentation, threat-model receipt, STAR/N/A index, premerge manifest, immutable Harness receipt, task boards, and its own status/evidence files.
- Left the change locally reversible as one enabler commit; reverting that commit restores the prior runner and Catalog without touching production data or remote refs.

Catalog SHA-256 changed only for the P12-089 contract:

- Before: `49b1b04f487bf0a0b04c0e264d81257a09d3e6bac80a5e713506e8cd7691349e`
- Candidate: `56433fd195ed93c39302882ea710a065016fe9b25f46bf1357c34f25e8bf2c27`
- Task count: `153`

Candidate implementation hashes before commit:

- `Invoke-TaskGate.ps1`: `f72fdda9f2013595ed2f6c9d23a7b10a6a10fc5883d4312ec07ceddd654ed522`
- `TaskGateCatalog.psd1`: `56433fd195ed93c39302882ea710a065016fe9b25f46bf1357c34f25e8bf2c27`
- `Invoke-TaskGate.Tests.ps1`: `66230bc30614f7d47ba3b847c2b0581fdc91092821e322c954be167c0fcb39e6`

## Affected regression

Final affected regression after the last implementation change:

| Check | Result | Duration / signal |
|---|---|---|
| `Invoke-TaskGate.Tests.ps1` | passed, exit `0` | 37.3 s; exact Catalog, registry, handler, pure XOR, ancestor, and telemetry-count contracts |
| `Invoke-IntegrationSmoke.Tests.ps1` | passed, exit `0` | 3.3 s; `tracked_write_count=0` |
| `Invoke-PhaseEntryRegression.Tests.ps1` | passed, exit `0` | 5.2 s; `implementation_write_count=0` |
| `Invoke-PhaseMerge.Tests.ps1` | passed, exit `0` | 3.7 s; `remote_write_count=0` |
| `git diff --check` | passed, exit `0` | no whitespace error; line-ending warnings only |
| Phase 12/Release C materialization audit | passed | zero P12 refs, zero P12 status rows, zero Release C status rows, and no Phase 12 evidence directory |

The suites intentionally exercise synthetic `none` and `multi_agent` shapes. They prove runner behavior only and MUST NOT be treated as a real capability choice, owner approval, benefit result, or Release C evidence.

## Difficulties and resolutions

- The first parser run found a missing `}` in the new `Where-Object` expression. The full runner parse isolated the line; the brace was restored before any gate was executed.
- The first Catalog assertion built the expected optional-package inputs as one concatenated string because of PowerShell comma/`+` precedence. The fixture now constructs each path explicitly.
- The next contract run found that StatusBoard aggregation reused the common handler without first enforcing the dynamic dependency. A dependency guard was added before board generation.
- The initial ancestor assertion searched the entire runner and collided with unrelated P12 functions. It was narrowed to the `Get-P12WorkPackageDependencyState` AST.
- The final review found the selected-count telemetry aggregation defect before commit. The arithmetic was narrowed and a static regression now rejects a return to whole-map integer summing.
- `rg.exe` was denied by the Windows host during the final context lookup. Read-only `Select-String` was used as the compatible fallback; no source or evidence content was altered by that substitution.

Each failed check supplied a new distinguishing signal. Only the smallest affected check was rerun after each repair, followed by the single final four-suite regression above.

## STAR result classification

`not_applicable` for behavioral-improvement STAR scoring. This enabler establishes a missing governance/runner capability and prevents invalid future execution, but no real Phase 12 capability was selected or run and no comparable product-behavior baseline/candidate measurement exists. Therefore no latency, quality, cost, RAG, Memory, Multi-Agent, or production outcome is claimed. The hard guardrail result is recorded separately: invalid convergence shapes and unimplemented conditional tasks fail closed without creating status/evidence or remote writes.
