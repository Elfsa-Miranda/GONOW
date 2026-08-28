# P11-089 convergence runner enabler repair receipt

- Recorded: 2026-08-02 (Asia/Shanghai)
- Classification: Phase 10 local-provisional repair/enabler for future conditional Phase 11 convergence
- Candidate branch: `codex/phase-10-release-b-gates`
- Candidate base before this repair: `8dfa734639fcab52056e5b4468e24a29ca5d449a`
- Scope: `TASK-P11-089` Catalog, runner, fail-closed dispatch, and contract tests only
- Explicit non-scope: no Release C path selection, RAG implementation, Phase 11 branch/worktree, Phase 11 status/evidence materialization, independent handoff receipt, owner approval, merge, push, production write, or acceptance
- Formal state: pending Release B acceptance/stability evidence, REL-C-000 `path=phase11`, P11-000 through P11-010 acceptance, governance receipt, and independent owners

## Reproduction

The conditional runner inventory contained 24 Release C task cards. After the P11 atomic family enabler, `TASK-P11-089` still failed closed as `conditional_task_runner_unimplemented`. The card also retained a generic work contract that did not enumerate the RAG documentation/contracts, premerge manifest, STAR/N/A record, ten predecessor evidence triples, or the exact convergence modes.

A complete P11-089 comparison against the frozen execplan found one systemic convergence gap:

- the Catalog did not bind the literal documentation, OpenAPI, knowledge schema, threat review, transfer, STAR, premerge, Harness Catalog, and task-board targets;
- the read set proved only the direct P11-010 dependency instead of the status, artifact, and gate objects for every P11-001 through P11-010 implementation task;
- no dedicated branch/worktree or formal-manifest boundary was enforced for every mode;
- no specialized documentation, security, evidence, rollback, handoff, Harness Catalog, or status-board handler existed;
- an independent handoff receipt and the committed P11-006 control 23 S/I/D fragment therefore could not be verified without either remaining permanently unimplemented or falling through generic behavior.

The initial public probe correctly demonstrated the fail-closed state. Phase 11 evidence and status counts were both zero before the probe.

## Root cause and impact surface

The original Catalog generator flattened conditional close-task prose into a generic card, while the runner registry intentionally rejected tasks with no specialized implementation. That protected the repository from unsafe execution but left no executable convergence contract after the ten atomic RAG tasks.

The affected surface is future Phase 11 close preparation only: accepted-predecessor aggregation, exact documentation/contract write boundaries, threat-model review validation, STAR classification, evidence hashing, rollback documentation, independent handoff validation, control 23 aggregation, task-board aggregation, and ready-for-review CAS. Existing Release B product code, Flutter behavior, database state, remote refs, production systems, and the immutable 34-control Harness Catalog are unchanged.

## Reversible repair

- Restored the exact execplan P11-089 required-change text and card SHA-256 `24f12ea3c8e96247ae2aef1403c179b9460f54adcb2a4203be218d7d4376a59e`.
- Bound 15 exact file/repository targets and the classified `docs/execution/evidence/phase-11/improvements/` STAR directory.
- Bound 34 immutable read inputs: three guidance/Catalog files, the Phase 11 runtime manifest, and status/artifact/gate triples for all ten implementation tasks.
- Declared the premerge manifest and all specialized evidence/status outputs.
- Registered exactly ten P11-089 modes: Documentation, Evidence, HandoffVerification, HarnessCatalogAggregate, Preflight, RollbackVerify, Security, StatusBoardAggregate, WorkPreflight, and WorksetVerify.
- Reused the accepted-predecessor aggregate with an explicit ten-task definition, so a missing, unaccepted, hash-drifted, non-ancestor, or failed predecessor blocks convergence.
- Reused the formal Phase 11 branch/worktree boundary and exact P11-089 path allowlist for every mode.
- Added fail-closed scans for undeclared writes, runtime implementation changes, missing documentation/contracts, secret/PII patterns, dangerous commands, malformed JSON, missing command-ledger evidence, and incomplete rollback markers.
- Required a pre-existing independent handoff receipt bound to the candidate HEAD. The runner reads and validates that external receipt but never fabricates or overwrites it.
- Required the committed P11-006 Harness fragment to contain control 23 `extend` evidence with nonempty S/I/D case classes, zero test failures, and Catalog hashes equal to the frozen Catalog. P11-089 records no Catalog transition.
- Added a pre-materialization formal-mode guard and a dedicated dynamic ready-for-review mode aggregate.
- Kept the repair locally reversible as one enabler commit; reverting it restores the prior runner/Catalog/tests without touching a Phase 11 branch, task record, database, remote ref, or production system.

Catalog SHA-256:

- Before: `1de6581e8579b5bde28249e52dd37f7f92f6afaf45f6be15b5ab69bcd2844840`
- Candidate: `17dce8a0b2a611107b01e22fcb4ab0766cf35cee92f943d716cb0f5abd996381`
- Task count: `153`
- Registered conditional tasks: `21`
- Remaining intentionally unimplemented close/release tasks: `TASK-P11-990`, `TASK-P11-999`, `TASK-REL-C-001`

Candidate implementation hashes before commit:

- `Invoke-TaskGate.ps1`: `4b3d1e33e57f72618ba3ca0ab141937883f8b65efd1063c9a3582946baa57466`
- `TaskGateCatalog.psd1`: `17dce8a0b2a611107b01e22fcb4ab0766cf35cee92f943d716cb0f5abd996381`
- `Invoke-TaskGate.Tests.ps1`: `d654d841adb9c3af69c151d77190282b9212260c74185731b6ce72debc82a827`

## Affected regression

Final affected regression after the last test-contract correction:

| Check | Result | Duration / signal |
|---|---|---|
| PowerShell AST parse | passed, exit `0` | no parser errors |
| `Invoke-TaskGate.Tests.ps1` | passed, exit `0` | 50.5 s standalone; 51.1 s final suite; 153 cards, 21 registered conditional tasks, exact P11-089 contract, ten-predecessor positive/negative matrix, ten specialized handlers |
| `Invoke-IntegrationSmoke.Tests.ps1` | passed, exit `0` | 0.6 s; `tracked_write_count=0` |
| `Invoke-PhaseEntryRegression.Tests.ps1` | passed, exit `0` | 1.4 s; `implementation_write_count=0` |
| `Invoke-PhaseMerge.Tests.ps1` | passed, exit `0` | 0.7 s; `remote_write_count=0` |
| P11-089 public local-provisional probe | correctly rejected, exit `2` | `p11_formal_predecessor_required:TASK-P11-089:Preflight` |
| P11-990 public unimplemented probe | correctly rejected, exit `2` | legal mode `AcceptancePreflight`; `conditional_task_runner_unimplemented:TASK-P11-990:AcceptancePreflight` |
| Probe materialization audit | passed | Phase 11 evidence `0 → 0`; P11 status `0 → 0` |
| Conditional topology audit | passed | zero P11 branch refs and zero P11 worktree markers |
| Remote identity audit | passed | exact `https://github.com/Elfsa-Miranda/GO_NOW.git` |
| `git diff --check` | passed, exit `0` | no whitespace errors; Git reports only the existing Windows line-ending normalization warning for the test file |

The predecessor matrices, external receipt shapes, and control-fragment checks are runner-contract tests. They do not prove a real RAG implementation, real reviewer approval, retrieval quality, production traffic, or Release C benefit.

## Difficulties and resolutions

- Repository search with the preferred `rg.exe` was denied by the host (`Access is denied`). Read-only PowerShell `Select-String`/`Get-ChildItem` was used as a compatible fallback; no repository state changed.
- `Import-PowerShellDataFile` under Windows PowerShell 5 rejected the Catalog's existing dynamic expressions. The repository's scriptblock/AST-compatible read path was used for inspection, preserving the full one-line UTF-8 Catalog.
- The first new TaskGate test failed because `Get-P11089Definition` was located in the runner AST but not loaded into the test scope. The test now explicitly loads that pure function before exercising the dependency matrix.
- The next two test failures were over-specific test assumptions (`reviewer_independent`, `catalog_mutation_count`, and `case_class_gap_count`) that did not match the runner's equivalent concrete invariants. Assertions were corrected to the actual independent-review fields, pre-existing receipt read, `mutation_applied=false`, empty transitions, and nonempty S/I/D partitions; runner safety behavior was not weakened.
- The first negative-probe wrapper used `$ErrorActionPreference=Stop`, so expected stderr became a parent-shell exception after the correct P11-089 refusal. The wrapper was changed to collect native stderr and exit codes explicitly.
- The first P11-990 probe requested disallowed `Preflight`, yielding `mode_not_allowed_for_task`. Catalog inspection identified `AcceptancePreflight` as a legal mode; that probe then reached and proved the intended unimplemented-task guard with no materialization.

Every retry above followed a new scope, field-shape, or mode-selection signal. No unchanged production command, formal gate, or test was repeatedly run.

## STAR result classification

`not_applicable` for behavioral-improvement STAR scoring. This enabler establishes a missing execution/governance capability and rejects invalid future convergence shapes, but no RAG behavior was implemented or compared. No retrieval quality, citation correctness, deletion SLA, latency, cost, user outcome, or production benefit is claimed.

The hard guardrail result is recorded separately: all ten atomic tasks must be independently accepted and hash/ancestry-bound; local P11-089 and unimplemented P11-990 actions fail before materialization; independent handoff cannot be self-authored; the Harness Catalog remains unchanged; and all integration/merge contract tests report zero tracked, remote, or production writes.
