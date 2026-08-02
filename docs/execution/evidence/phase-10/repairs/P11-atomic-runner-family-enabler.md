# P11 atomic runner family enabler repair receipt

- Recorded: 2026-08-02 (Asia/Shanghai)
- Classification: Phase 10 local-provisional repair/enabler for future conditional Phase 11 execution
- Candidate branch: `codex/phase-10-release-b-gates`
- Candidate base before this repair: `a7350f6380fac9356e747f869d15b5ce7605fc38`
- Scope: `TASK-P11-001` through `TASK-P11-010` runner and Catalog contracts only
- Explicit non-scope: no Release C path choice, RAG implementation, Phase 11 branch/worktree, task status/evidence, owner approval, merge, push, production write, or acceptance
- Formal state: pending Release B acceptance/stability evidence, REL-C-000 `path=phase11`, P11-000 acceptance, governance receipt, and independent owners

## Reproduction

The conditional runner inventory contained 24 Release C task cards. Only ten were registered; the remaining fourteen were P11-001…010, P11-089/990/999, and REL-C-001. Public invocation of any unregistered card failed closed, which was safe, but there was no executable contract for the ten Phase 11 atomic implementation cards.

A complete P11-001…010 Catalog-to-execplan comparison then found a single systemic generation drift:

- all ten `required_changes[]` values had been reduced to generic “execute task card contract” summaries instead of the exact frozen pipelines in execplan;
- every card omitted the Phase 11 runtime manifest and predecessor status/artifact/gate objects from `read_only_inputs[]`;
- P11-001 omitted both policy YAML source targets;
- P11-007 omitted `contracts/knowledge-package-v1.schema.json`;
- P11-009 omitted `rag-manifest.json` from structured evidence;
- P11-010 omitted `rollout.yaml` from structured evidence.

The stale Catalog would either reject a compliant implementation, accept an ambiguous one, or allow a task to run without proving its exact accepted predecessors. Merely registering the task IDs would therefore have been unsafe.

## Root cause and impact surface

The Catalog generator preserved broad task metadata but flattened task-specific prose contracts for the conditional P11 cards. The runner registry was intentionally fail-closed, so the mismatch remained dormant while formal Release C inputs were absent.

The affected surface was limited to future Phase 11 orchestration: dependency ancestry, branch/worktree isolation, literal write targets, per-task verification, security assertions, evidence hashing, rollback verification, dependency audit, control 23 extension, and ready-for-review aggregation. Existing Release B product code, Flutter behavior, database state, remote refs, and production systems were not changed.

## Reversible repair

- Restored the ten exact execplan `required_changes[]` strings and the missing literal targets/evidence outputs.
- Added every direct predecessor's status, artifact, and gate object plus the immutable Phase 11 runtime manifest to each task read set.
- Registered the exact seven modes for P11-001/002/003/005/007/008/009/010 and eight modes, including `DependencyAudit`, for P11-004/006.
- Added one shared P11 atomic definition and dependency family while retaining each card's exact source paths, test paths, assertion text, security profile, and rollback strategy.
- Required accepted predecessor status and artifact heads to be Git ancestors of the candidate rather than equal to a later HEAD.
- Required the formal Phase 11 manifest, `codex/phase-11-rag`, the dedicated worktree path, a local exact branch ref, no remote specialist refs, and no Phase 12 refs.
- Added real workset checks for read-only writes, latest command failures, missing literal files, and an empty allowed dataset directory.
- Added pytest/JUnit verification for P11-002…009, static policy/rollout verification for P11-001/P11-010, and task-specific security-case name coverage plus secret/PII scans.
- Added P11-006 Harness control 23 `extend` receipt with S/I/D case partition and unchanged Catalog hash.
- Added per-task dynamic mode aggregation before `ready_for_review`; P11-004/006 cannot pass without `DependencyAudit`.
- Added a pre-materialization guard so local-provisional P11 atomic invocations exit `2` before creating evidence or status.
- Kept the change locally reversible as one enabler commit; reverting it restores the prior runner/Catalog without touching a P11 branch, task record, database, or remote ref.

Catalog SHA-256:

- Before: `56433fd195ed93c39302882ea710a065016fe9b25f46bf1357c34f25e8bf2c27`
- Candidate: `1de6581e8579b5bde28249e52dd37f7f92f6afaf45f6be15b5ab69bcd2844840`
- Task count: `153`
- Registered conditional tasks: `20`
- Remaining intentionally unimplemented close/release tasks: `TASK-P11-089`, `TASK-P11-990`, `TASK-P11-999`, `TASK-REL-C-001`

Candidate implementation hashes before commit:

- `Invoke-TaskGate.ps1`: `dd1d0f690d65cf9b0e5ce303ab038d4aeb493a27f3fe3ac2899997c980ce30bf`
- `TaskGateCatalog.psd1`: `1de6581e8579b5bde28249e52dd37f7f92f6afaf45f6be15b5ab69bcd2844840`
- `Invoke-TaskGate.Tests.ps1`: `b6a97cadc8088f84e4541086d969b6407dac9100fbaeef7cb97781c437eb30d5`

## Affected regression

Final affected regression after the last runner/status change:

| Check | Result | Duration / signal |
|---|---|---|
| `Invoke-TaskGate.Tests.ps1` | passed, exit `0` | 46.4 s; 153 cards, 20 registered conditional tasks, exact P11 contracts, pure predecessor positive/negative matrix, eight specialized handlers, per-task mode aggregation |
| `Invoke-IntegrationSmoke.Tests.ps1` | passed, exit `0` | 3.3 s; `tracked_write_count=0` |
| `Invoke-PhaseEntryRegression.Tests.ps1` | passed, exit `0` | 4.3 s; `implementation_write_count=0` |
| `Invoke-PhaseMerge.Tests.ps1` | passed, exit `0` | 3.6 s; `remote_write_count=0` |
| P11-001 public local-provisional probe | correctly rejected, exit `2` | `p11_atomic_formal_predecessor_required:TASK-P11-001:Preflight` |
| P11-089 public unimplemented probe | correctly rejected, exit `2` | `conditional_task_runner_unimplemented:TASK-P11-089:Preflight` |
| Probe materialization audit | passed | P11 status `0 → 0`; Phase 11 evidence files `0 → 0` |
| Conditional topology audit | passed | zero local/remote P11 or P12 refs |
| `git diff --check` | passed, exit `0` | no whitespace error; line-ending warnings only |

The dependency matrices and security/test definitions are synthetic runner-contract inputs. They do not prove a real RAG implementation, real owner approval, stable production traffic, or Release C benefit.

## Difficulties and resolutions

- `Import-PowerShellDataFile` under Windows PowerShell 5 cannot evaluate the Catalog's existing dynamic expressions. The repository's AST/SafeGetValue compatibility loader was reused for read-only inspection.
- The first content-addressed Catalog transform failed before writing because PowerShell 5 decoded non-ASCII literals in a no-BOM temporary script with the system code page. Required changes were moved to UTF-8 Base64 values.
- The second transform still failed before writing because the temporary Catalog dropped the original UTF-8 BOM, causing the parser to reinterpret the entire 548 KB one-line data file. The atomic writer was changed to preserve BOM; the subsequent transform parsed and moved successfully.
- Initial handler coverage did not include the bottom ready-for-review CAS dispatcher. A full dispatch audit found the gap before commit; dynamic per-definition aggregation was added.
- Review found that an absent P11-009 dataset directory produced an empty target list and could evade missing-file checks. A directory-level nonempty check now participates in both Workset and Evidence.
- Review also found non-Preflight modes could otherwise be called directly and Security could overwrite true secret/PII counts with a normalized failure bit. Every mode now revalidates the formal execution boundary, and existing measured counters are preserved.

Every retry above followed a new parser, dispatch, or data-shape signal. No production command, formal gate, or unchanged test was repeatedly run.

## STAR result classification

`not_applicable` for behavioral-improvement STAR scoring. This enabler establishes missing execution/governance capability and rejects invalid future task shapes, but no RAG behavior was implemented or compared. No quality, latency, retrieval, citation, deletion, cost, or production outcome is claimed. The hard guardrail result is recorded separately: local/unimplemented P11 actions fail before materialization, predecessor and branch evidence is mandatory, and all test/merge contracts report zero remote or production writes.
