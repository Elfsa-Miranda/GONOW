# P11-999 PhaseMerge runner enabler

## Scope and evidence boundary

- Enabler branch: `codex/phase-10-release-b-gates`
- Enabler base: `69a81b578936cb15902ebdeace997479c83ec592`
- Frozen task-card SHA-256: `ce1c152c01684c6ec9c743f34cc5e57b6d7b9db3b65874815cc8ff9099bbb1cd`
- Catalog CAS: `9fb4f85d133ce227bfe609b7091ed0dfca1397de89a9a7940f36660f3663add5` → `768bca58b158d13bc95128fbae752e2f772425c1730f7e03a4cd584fb07097ac`
- This record proves a local runner contract and its tests. It does not prove that Phase 11 exists, that P11-990 is accepted, that an owner approved a merge, or that any merge, push, production write, or Release C action occurred.

## Reproduction

The first complete inspection produced one root-cause cluster rather than independent small failures:

1. `Get-ConditionalTaskRunnerRegistryState` did not register `TASK-P11-999`, so its only TaskGate mode failed closed as unimplemented.
2. the P11-999 Catalog card exposed eleven PhaseMerge modes but left the file/directory allowlist, assertions, work contract, full applicable CT set, and final evidence set empty or generic;
3. every PhaseMerge handler either rejected non-P10 tasks or used Phase 10 evidence paths and reason codes;
4. generic TaskGate `Evidence` would append to `commands.json` and `gate-results.json` and update task status after PhaseMerge close, invalidating the hashes it was meant to verify.

The bounded negative probes after repair returned:

- `TASK-P11-999 / Evidence / local_provisional`: exit `2`, reason `p11_formal_predecessor_required`, materialization delta `0`;
- `TASK-REL-C-001 / Preflight / local_provisional`: exit `2`, reason `conditional_task_runner_unimplemented`, materialization delta `0`.

These are expected fail-closed results, not formal task failures.

## Root cause and impact surface

The Catalog had registered the generic PhaseMerge mode names without supplying a Phase 11 execution profile or a non-mutating final verifier. That made the apparent P11-999 entry non-executable and made a naive registration unsafe because the generic Evidence epilogue would mutate immutable close evidence.

The affected surface was collected before editing:

- `docs/execution/commands/Invoke-PhaseMerge.ps1`;
- `docs/execution/commands/Invoke-TaskGate.ps1`;
- `docs/execution/commands/TaskGateCatalog.psd1`;
- both runner contract test files;
- P11-990 owner receipts, gate summary, rollback receipt, P11-007 identity/authorization gate, P11-010 rollout contract, BOOT-004 governance receipt, Phase 11 manifest, and premerge manifest as read-only formal inputs.

No runtime application, database schema, Flutter source, production configuration, remote ref, `main`, or Phase 12 implementation path is in the write set.

## Reversible repair

- Added a PhaseMerge profile for P10 and P11 while preserving the existing P10 formal preflight.
- Added a P11-specific formal preflight that requires:
  - accepted P11-990 status bound to its exact gate hash;
  - all ten P11-990 mandatory modes passed and forced rejection count zero;
  - five distinct P11-990 owner roles (`Data`, `Engineering`, `Privacy`, `Product`, `Security`);
  - a separate three-role ReleaseC Board merge authorization (`Engineering`, `Product`, `Security`) bound to the candidate, phase base, landing OID, P11-990 receipt hash, and gate hash;
  - unexpired approvals, zero open conditions/P0/P1, clean source, approval-only diff, exact landing base, formal BOOT-004, candidate ancestry, and zero parallel Phase 12 refs.
- Derived `approval_tip_oid` from the current source tip after approval-only evidence. The tracked authorization uses an explicit locator rule instead of an impossible commit self-reference.
- Generalized cleanup, merge, tree proof, smoke, post-merge evidence, retrospective, versioned archive, and close verification over the phase profile. Merge runs from the resolved landing worktree and still uses `--no-ff --no-edit` on the frozen approval tip.
- Added P11 security aggregation for secret, PII, audit, identity, and authorization counters, plus a merge-authorization hash check.
- Added P11 rollback verification against the production-same-configuration isolated P11-990 receipt and P11-010 flag/rollback contract. The only post-merge Git rollback is an owner-approved `git revert -m 1`; reset and force-push remain forbidden.
- Registered P11-999 TaskGate `Evidence` as a read-only final validator. Its main path skips evidence/status materialization and skips the normal append/status epilogue, so it cannot invalidate PhaseMerge hashes or downgrade `accepted`.
- Expanded P11-999 Catalog scope from 4 to 13 applicable CT IDs and bound its complete fixed/dynamic evidence surface to the frozen card hash.

Rollback is one local `git revert` of the enabler commit. No migration, production data, external object, remote branch, or published contract requires cleanup.

## Affected regression

Final parallel run from the repository root:

| Suite | Exit | Duration | Result |
|---|---:|---:|---|
| `Invoke-TaskGate.Tests.ps1` | 0 | 65.6 s | 153-card Catalog import, exact P11-999 contract, read-only final Evidence, and conditional registry passed |
| `Invoke-PhaseEntryRegression.Tests.ps1` | 0 | 4.9 s | positive dispatch and all negative base/source/create-only boundaries passed |
| `Invoke-IntegrationSmoke.Tests.ps1` | 0 | 3.9 s | exact merge OID, cwd, state, duration, and tracked-write contract passed |
| `Invoke-PhaseMerge.Tests.ps1` | 0 | 4.2 s | P10 compatibility, P11 authorization positive/expired cases, cross-shell state, and destructive-command rejection passed |

Additional checks:

- PowerShell AST parse errors: `0` across both runners and both test files;
- `git diff --check`: exit `0`;
- registered conditional Release C tasks: `22 → 23`;
- unimplemented conditional tasks: `2 → 1` (`TASK-REL-C-001` only);
- local negative-probe evidence/status materialization delta: `0`;
- remote writes, production writes, merges, pushes, and `main` writes: `0`.

## STAR record

### Situation

P11-999 appeared in the Catalog but was not executable: the merge engine was Phase-10-specific, and the apparent final Evidence path could corrupt its own immutable hash chain.

### Task

Make the formal P11 merge/close path mechanically complete while keeping every external approval, actual merge, push, production action, and accepted transition fail closed.

### Action

Collected the full Catalog/TaskGate/PhaseMerge impact surface, separated candidate approval from approval-tip derivation to avoid self-reference, implemented exact P11 authorization/security/rollback/merge-tree contracts, and made final Evidence read-only before registering it.

### Result

The P11-999 runner contract now has 11 implemented PhaseMerge modes, 13 applicable CT bindings, two independent approval layers, exact tree/smoke/close verification, and zero-write local rejection. All four affected regression suites passed. This is a governance capability result, not a claim of RAG quality improvement or Release C completion.

## Difficulty and decision log

The main difficulty was the approval-tip and close-evidence self-reference trap. A tracked file cannot contain the Git OID of the commit that contains that same file, and a final verifier cannot append to files whose hashes it is verifying. The reversible solution was:

1. approvals bind the immutable implementation candidate and evidence hashes;
2. the authorization declares `current_source_tip_after_approval_only_evidence`, and MergePreflight derives/freezes that exact tip after validating the diff;
3. `phase_close_oid` is resolved by the documented “commit containing this record” locator;
4. TaskGate final Evidence is read-only and PhaseMerge remains the sole close-evidence writer.

Formal execution remains pending P11 branch creation, accepted P11-990 evidence, real independent actors, BOOT-004 formal adoption, and an authorized landing worktree. None was synthesized.
