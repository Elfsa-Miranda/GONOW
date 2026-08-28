# P11-990 formal acceptance runner enabler repair receipt

- Recorded: 2026-08-02 (Asia/Shanghai)
- Classification: Phase 10 local-provisional repair/enabler for future conditional Phase 11 formal acceptance
- Candidate branch: `codex/phase-10-release-b-gates`
- Candidate base before this repair: `3ff3e95153820325a7eff8e6f4fcd9e4416a5911`
- Scope: `TASK-P11-990` Catalog, ten-mode runner, dependency-mode correction, fail-closed dispatch, and contract tests only
- Explicit non-scope: no Release C path selection, RAG implementation, Phase 11 branch/worktree, Phase 11 status/evidence materialization, owner signature, production-like rollback execution, acceptance, merge, push, or production write
- Formal state: pending Release B acceptance/stability evidence, REL-C-000 `path=phase11`, governance adoption, P11-000 through P11-089 independent acceptance, production-same-configuration isolated rollback receipt, and five independent approvals

## Reproduction

After P11-089 registration, `TASK-P11-990` remained deliberately fail-closed as `conditional_task_runner_unimplemented`. Its Catalog card exposed ten allowed modes but had no file allowlist, no exact work contract, only the three common guidance inputs, and only the minimum generated status/evidence outputs. It could not prove the card's source/ACL/delete/eval/rollout inputs, mandatory regressions, rollback scenarios, or owner approvals.

The dependency review also found a shared defect: `Get-P11AtomicDependencyState` knew the exact mandatory modes for P11-000 and P11-001…010, but treated the non-atomic P11-089 card as having an empty mode set. A future acceptance task could therefore verify P11-089 status/artifact presence without proving its ten mandatory convergence modes.

The initial public probes established the safe baseline:

- P11-990 local provisional invocation was rejected before task evidence/status creation;
- P11-999 remained unimplemented and rejected its legal `Evidence` mode;
- Phase 11 evidence and status counts remained zero.

## Root cause and impact surface

The Catalog generator flattened acceptance cards to generic metadata, while the conditional registry intentionally rejected unimplemented tasks. Separately, the shared P11 dependency resolver assumed every post-entry prerequisite was atomic. That assumption stopped being true at convergence and acceptance boundaries.

The affected surface is future Phase 11 formal acceptance only: eleven-predecessor evidence aggregation, exact acceptance/index writes, persisted mandatory-gate validation, locked Agent/Flutter regression, Harness completeness, blocker final state, independent production-like rollback receipt, five-role approval receipt, security/audit scans, final artifact hashing, and ready-for-review CAS. Product code, database state, Harness Catalog contents, remote refs, and production systems are unchanged.

## Reversible repair

- Registered exactly ten P11-990 modes: AcceptancePreflight, ApprovalValidation, BuildAcceptance, Documentation, Evidence, Regression, RollbackDrill, RollbackVerify, Security, and Verify.
- Corrected the shared P11 dependency resolver to select P11-089 and P11-990 exact mandatory mode sets instead of an empty atomic definition.
- Required independent accepted status, artifact hash, gate result, Git ancestry, immutable Phase 11 manifest, exact branch/worktree, and unchanged plan/Catalog bindings for P11-001…010 plus P11-089.
- Restored the exact two writable files, 57 read-only inputs, 11 evidence outputs, 13 applicable CT IDs, three security controls, and five independent reviewer roles.
- Bound the task card to the raw execplan section SHA-256 `e58916c8ae97809cde7940a4d4b877da70b1c996cf3e42746888d9f44719ab3d`.
- Added a 34-control/149-minimum-case Harness check with `first_phase_le_p11_unimplemented_count=0`.
- Added blocker enumeration that rejects open P0/P1 items, malformed blocker JSON, or blocker records without a final state.
- Added an isolated regression runner for Agent CI, runner contracts, locked Flutter tests, persisted predecessor gates, and minimum 542 unit, 144 contract, and 82 Flutter tests; failed/not-run/skipped/xfailed must all remain zero.
- Required a pre-existing independent rollback receipt for exactly idle, at least three in-flight Runs, and old-version reads of new data in `production_same_configuration_isolated`; the runner never fabricates that receipt.
- Required a pre-existing five-role approval receipt for Data, Engineering, Privacy, Product, and Security. Candidate HEAD, immutable premerge evidence hash, unique actors, approval age `<=14` days, unexpired validity, zero open conditions, independence, and every required field are fail-closed.
- Added strict field-presence wrappers so missing Boolean/integer fields cannot be silently cast to safe `false/0` values, and a missing premerge artifact cannot bind an empty evidence hash.
- Added acceptance/index generation that always records `accepted=false`; only the external status transition can mark formal acceptance.
- Added eight explicit forced-rejection counters and final artifact refresh after acceptance, approval, regression, rollback, and verification evidence exist.
- Added a pre-materialization formal-mode guard and exact ten-mode ready-for-review aggregate.
- Kept the repair reversible as one local enabler commit; reverting it restores the prior runner/Catalog/tests without touching a Phase 11 task record, branch, database, remote ref, or production system.

Catalog SHA-256:

- Before: `17dce8a0b2a611107b01e22fcb4ab0766cf35cee92f943d716cb0f5abd996381`
- Candidate: `9fb4f85d133ce227bfe609b7091ed0dfca1397de89a9a7940f36660f3663add5`
- Task count: `153`
- Registered conditional tasks: `22`
- Remaining intentionally unimplemented tasks: `TASK-P11-999`, `TASK-REL-C-001`

Candidate implementation hashes before commit:

- `Invoke-TaskGate.ps1`: `81cc41f9ed0b5845d88ab284ef8eeaeb35d211e50e6e0f6d6015b0ad68220835`
- `TaskGateCatalog.psd1`: `9fb4f85d133ce227bfe609b7091ed0dfca1397de89a9a7940f36660f3663add5`
- `Invoke-TaskGate.Tests.ps1`: `38fb94e811fb3636875a5f0ad942e9dabfe969536f7b4d0bf7a0cefc32cb4dea`

## Affected regression

| Check | Result | Duration / signal |
|---|---|---|
| PowerShell AST parse | passed, exit `0` | runner and test scripts have zero parser errors |
| `Invoke-TaskGate.Tests.ps1` | passed, exit `0` | 58.6 s focused; 59.1 s final suite; 153 cards, 22 registered conditional tasks, exact P11-990 contract, eleven-predecessor matrix, recursive metric aggregation, ten handlers |
| `Invoke-IntegrationSmoke.Tests.ps1` | passed, exit `0` | 0.7 s; `tracked_write_count=0` |
| `Invoke-PhaseEntryRegression.Tests.ps1` | passed, exit `0` | 1.6 s; `implementation_write_count=0` |
| `Invoke-PhaseMerge.Tests.ps1` | passed, exit `0` | 0.8 s; `remote_write_count=0` |
| P11-990 public local-provisional probe | correctly rejected, exit `2` | `p11_formal_predecessor_required:TASK-P11-990:AcceptancePreflight` |
| P11-999 public unimplemented probe | correctly rejected, exit `2` | `conditional_task_runner_unimplemented:TASK-P11-999:Evidence` |
| Probe materialization audit | passed | Phase 11 evidence `0 → 0`; P11 status `0 → 0` |
| Conditional topology audit | passed | zero P11 branch refs and zero P11 worktree markers |
| Remote identity audit | passed | exact `https://github.com/Elfsa-Miranda/GO_NOW.git` |
| `git diff --check` | passed, exit `0` | no whitespace errors; Git reports only the existing Windows line-ending normalization warning for the test file |

The synthetic dependency matrices and receipt schemas prove runner behavior only. They do not prove RAG quality, an executed production-like rollback drill, real owner approvals, Release C benefit, or formal Phase 11 acceptance.

## Difficulties and resolutions

- The first AST parse produced hundreds of apparent errors after a single non-ASCII Definition string was read under Windows PowerShell's no-BOM parser behavior. The full failure set showed one root line; the value was replaced with an ASCII UTF-8 Base64 literal, after which every cascade error disappeared.
- The first TaskGate test reported the registered-task inventory was wrong because the old inventory probed every task with `Preflight`; P11-990 legitimately uses `AcceptancePreflight`. Inventory logic now requires every mode declared by each task to be registered, while per-mode tests still enforce the exact set.
- Review found that PowerShell casts missing Boolean/integer JSON properties to `false/0`. Strict receipt-shape wrappers now check every required top-level, approval, and rollback-scenario property before allowing the value-level validator to pass.
- Review also found an absent premerge manifest would produce an empty expected evidence hash. The approval wrapper now requires the computed binding to be a nonempty 64-character lowercase SHA-256.
- The Catalog transform used expected-hash CAS, a temporary BOM-preserving file, atomic replace, reparsing, and task-count verification. The temporary transform script was removed and is not part of the candidate.

Each retry followed a new parser, registry, or schema-shape signal. No unchanged production action, formal gate, or test was repeatedly run.

## STAR result classification

`not_applicable` for behavioral-improvement STAR scoring. This enabler adds formal acceptance execution/governance capability but does not implement or compare RAG behavior. No retrieval quality, citation correctness, deletion SLA, latency, cost, user outcome, or production benefit is claimed.

The hard guardrail result is recorded separately: all eleven predecessors and their exact mandatory modes must be independently accepted; local acceptance fails before materialization; rollback and approvals must be independently supplied and HEAD/evidence-bound; missing fields fail closed; the runner never writes `accepted=true`; and all integration/merge contract suites report zero tracked, remote, or production writes.
