# REL-C-001 single-capability publication runner enabler

## Scope and evidence boundary

- Enabler branch: `codex/phase-10-release-b-gates`
- Enabler base: `3befc3b7c8e086d694dc49f9580190ff905ba8a2`
- Frozen task-card SHA-256: `105fd348eff5ffc2d3fd9a379793cbcbf5038170b84b606a4e0d7256bb00e7bf`
- Catalog CAS: `768bca58b158d13bc95128fbae752e2f772425c1730f7e03a4cd584fb07097ac` → `37dd1f09a9c0d5820b984846143ef1f833f1608490cb22cee38cc7e23bc33551`
- This record proves a local runner contract and its regression tests. It does not prove that Release B, REL-C-000, Phase 11, Phase 12, or REL-C-001 is accepted; that a Release C path or capability was selected; or that a PR, merge, push, production write, deployment, allocation, or Release acceptance occurred.

## Reproduction

The first complete inspection produced one control-plane root-cause cluster:

1. `TASK-REL-C-001` was the only conditional task not registered by `Get-ConditionalTaskRunnerRegistryState`, so every declared mode failed closed as unimplemented.
2. its Catalog card flattened the task-card XOR into an impossible three-item AND (`P11-999`, `P12-089`, and `REL-C-000`), declared all 15 CT IDs instead of the card's empty set, expanded five security checks to 14, and omitted the PR metadata adapter, `C.json`, receipts, and dynamic governance inputs;
3. no specialized handler distinguished outer `phase11|phase12|none`, the Phase 12 inner selection, the selected capability merge, or unselected-path commit/ref counts;
4. no pre-materialization boundary preserved `not_started` when execution was provisional, the outer receipt was unavailable, or the selected outer path was `none`;
5. the first formal negative probe exposed a PowerShell 5 compatibility defect: an expected missing Git ref was promoted from a read-only query result to terminating exit `1` under `$ErrorActionPreference=Stop`.

The first full TaskGate run after the initial implementation returned one aggregated static-test mismatch. A single diagnostic decomposition showed all seven implementation markers were present; the test used a case-sensitive lowercase `path` marker while the runner variable was `$Path`. The test was corrected once, without changing the implementation or rerunning unrelated suites.

## Root cause and impact surface

The generated Catalog provided only generic card metadata for the final Release C publication task, while TaskGate intentionally requires explicit conditional registration before dispatch. The generic metadata could not represent dynamic XOR prerequisites or a metadata-only external action, so registering it unchanged would have permitted an incorrect dependency model and incomplete evidence.

The affected surface was collected before implementation:

- `docs/execution/commands/Invoke-TaskGate.ps1`;
- `docs/execution/commands/TaskGateCatalog.psd1`;
- `docs/execution/commands/tests/Invoke-TaskGate.Tests.ps1`;
- immutable REL-C-000 outer records and Release B acceptance;
- P11 merge/close/gate/rollback records for the `phase11` path;
- P12 inner selection, P12-089 status, and an approved implementation-close registration for the future `phase12` path;
- read-only remote `main` and `codex/gonow-agent-landing` refs plus GitHub PR/check observations.

No runtime application, database schema, dependency lock, Flutter source, production configuration, remote ref, `main`, or selected capability implementation is in the write set.

## Reversible repair

- Registered all seven REL-C-001 TaskGate modes and routed evidence to `docs/execution/evidence/releases/REL-C-001/`.
- Replaced the Catalog's false AND with `TASK-REL-C-000` plus runner-enforced dynamic XOR; set `applicable_ct_ids=[]`; restored the five task-card security IDs; added the exact task-card required change, complete evidence/read surface, and one authorized GitHub metadata action.
- Added pre-materialization guards:
  - `local_provisional` returns `rel_c_001_formal_predecessor_required`;
  - absent/invalid outer governance returns `rel_c_001_outer_governance_invalid`;
  - outer `none` returns `rel_c_001_outer_path_none`;
  - each rejection leaves evidence and status paths absent.
- Validated the outer immutable selection, trigger, four reviewer roles, two owner roles, distinct actors, unexpired decisions, CAS ancestry, accepted status, seven mandatory modes, and selection/trigger artifact bindings. The artifact contract intentionally does not require a self-referential post-acceptance status hash.
- Implemented both selected paths:
  - `phase11` requires accepted P11 close evidence, exactly one RAG merge after the Release B base, all 11 merge modes, the production-same-configuration rollback drill, no P12 refs, and zero P12-like changes;
  - `phase12` requires a non-`none` inner selection and an approved, hash-bound implementation-close registration with four distinct unexpired roles, safe registered paths, one accepted merge, selected rollback, and zero P11 or unselected P12 refs. This records the future approved plan rather than guessing task IDs from the current dormant work packages.
- Added PR request/observation/live-query contracts for exact base/head, one active capability, zero unselected commits, three labels, four review roles, required checks, audit receipt, and `auto_merge=false`. The runner only performs live HTTP `GET`; an authorized adapter supplies the metadata mutation receipt.
- `Verify` writes `C.json` with `accepted=false`, `merge_main_status=not_started`, and `production_deployment_status=not_started`. No runner path can self-accept or auto-merge.
- Hardened the shared Git-object reader so an expected missing object is represented as a structured result under Windows PowerShell 5 instead of terminating the process.

Rollback is one local `git revert` of the enabler commit. No migration, production data, external object, remote branch, or published PR requires cleanup.

## Affected regression

Final regression from the repository root:

| Suite | Exit | Duration | Result |
|---|---:|---:|---|
| `Invoke-TaskGate.Tests.ps1` | 0 | 65.2 s | 153-card schema/import, exact REL-C-001 Catalog, all conditional runners, handlers, and fail-closed boundaries passed |
| `Invoke-PhaseEntryRegression.Tests.ps1` | 0 | 1.9 s | positive dispatch and missing-source/base-drift/create-only boundaries passed |
| `Invoke-IntegrationSmoke.Tests.ps1` | 0 | 0.9 s | exact merge OID/cwd/state/duration and zero tracked writes passed |
| `Invoke-PhaseMerge.Tests.ps1` | 0 | 1.2 s | P10/P11 merge profiles, authorization, cross-shell state, and destructive-command rejection passed |

Bounded negative probes:

- `REL-C-001 / Preflight / local_provisional`: exit `2`, `rel_c_001_formal_predecessor_required`, evidence/status materialization delta `0`;
- `REL-C-001 / Preflight / formal_adopted` without the governance ref: exit `2`, `rel_c_001_outer_governance_invalid`, evidence/status materialization delta `0`.

Additional checks:

- PowerShell AST parse errors: `0` for the runner, Catalog, and contract test;
- `git diff --check`: exit `0`;
- conditional tasks registered: `23 → 24`;
- unimplemented conditional tasks: `1 → 0`;
- Catalog task count: `153` unchanged;
- temporary/backup Catalog rewrite files: `0`;
- remote writes, PR writes, merges, pushes, production writes, deployments, and `main` writes: `0`.

## STAR record

### Situation

The only remaining conditional task appeared complete in the plan but could not execute, and its generated Catalog metadata contradicted the task's single-capability XOR and no-CT publication contract.

### Task

Make Release C publication mechanically executable only after one formally accepted capability path, while keeping every PR mutation, merge, deployment, allocation, and accepted transition outside the local enabler.

### Action

Collected the complete outer/inner selection, merge, rollback, evidence, Git ref, and GitHub metadata surface; replaced generic dependency data with exact dynamic gates; added zero-materialization start guards; and verified both the current P11 closure and future plan-registered P12 closure without selecting either.

### Result

All 24 conditional task cards now have specialized fail-closed runners, the Release C publication contract proves one active capability and zero unselected commits/refs, and all four affected regression suites pass. This is a governance capability result, not a Release C selection, PR, quality improvement, or production result.

## Difficulty and decision log

Three design traps required explicit decisions:

1. **Post-acceptance hash self-reference:** REL-C-000 artifact evidence cannot contain the final accepted status hash if that status changes after evidence generation. REL-C-001 therefore binds the immutable selection and trigger in the artifact manifest, while the accepted status independently binds the final gate hash and remains an ancestor of the governance head.
2. **Unknown future Phase 12 task IDs:** current Phase 12 work packages are dormant design packages and explicitly require a later approved plan change to register acceptance/merge IDs. REL-C-001 reads a strict `implementation-close-registration.json` with safe path regexes, plan hash, four approvals, selected merge, and rollback instead of inventing future task IDs or treating P12-089 planning as implementation.
3. **Windows PowerShell native stderr:** a missing ref is an expected negative state, but PowerShell 5 promoted Git stderr to a terminating error. The bounded fix locally changes error action only around read-only Git queries, preserves the exit code, restores the prior setting, and returns a structured rejection.

Formal execution remains pending Release B acceptance/merge/stability evidence, an accepted REL-C-000 non-`none` choice, exactly one accepted capability close, valid independent approvals, an authorized GitHub adapter identity, and the user's later merge/production decisions. None was synthesized.
