# P12-002 runner contract enabler

- Classification: `phase-10/repairs`
- Scope: safe local runner, Catalog, and contract-test enabler only
- Baseline HEAD: `fd69934eaad16b1f949a078506cb3f9b44671110`
- Execution mode: `local_provisional`
- Recorded: `2026-08-02` (`Asia/Shanghai`)

## Reproduction

P12-001 is not accepted and no Release C governance worktree/ref, P12 decision evidence/status, or specialist branch exists. Real P12-002 execution therefore remains unavailable.

A contract test was added before implementation. Its first run exited `1`: P12-002 retained the generic Catalog sentence, omitted all six accepted P12-001 inputs, had no dedicated XOR/CAS validator, topology validator, or seven-mode implementation, and remained fail-closed in the conditional registry.

The completed implementation produced two additional and distinct diagnostic signals. First, removing the BOM during the one-line Catalog replacement made Windows PowerShell 5 reject the data file. Second, one Base64 character decoded the required-change word `证明` incorrectly. Both failures occurred before any task evidence, status, branch, ref, worktree, remote, or production mutation.

## Root cause and impact surface

P12-002 existed only as task inventory. The generic runner could not prove that the accepted P12-001 decision was the only decision for its cycle, that `none` maps to zero selections and every capability maps to exactly one, that the owner signed a versioned payload, that an expected-SHA CAS updated only the governance ref, or that every Phase 11/12 specialist branch and worktree remained absent.

The shared dependency validator also required a generated artifact's `head_oid` to equal the later accepted commit. Because an evidence artifact is generated before the commit containing it, equality is not generally satisfiable. P12-001 and P12-002 dependency checks now require that artifact head to be a valid Git ancestor of the accepted head while retaining all transitive SHA-256 bindings.

The Catalog failures were representation defects, not task-contract failures: its canonical file is BOM-bearing UTF-8, and the exact required change is transported through Base64 to avoid PowerShell 5 code-page ambiguity.

## Reversible repair

- P12-002 is registered only after all seven handlers exist: `Preflight`, `WorkPreflight`, `WorksetVerify`, `Verify`, `Security`, `RollbackVerify`, and `Evidence`. P12A-000 and the other 18 conditional tasks remain fail-closed.
- Catalog `required_changes[]` now preserves the full card contract byte-for-byte. Its direct write set is limited to `selection.json`, the P12-000 `ref-reservation.json`, the P12-002 CAS receipt, generated P12-002 evidence, and task status.
- The six read-only dependencies are accepted P12-001 status, artifact index, approval, approval verification, gate results, and Phase 12 manifest. The validator reads immutable Git objects from the CAS receipt's `expected_sha` after CAS, or `HEAD` before CAS.
- Dependency validation requires formal P12-001 acceptance, seven passed modes, artifact-to-approval/verification/manifest hashes, ancestor-valid artifact head, zero historical regression drift, and no prior accepted selection record for the cycle.
- The selection payload is versioned and hashes `record_version|cycle|p12_001_head|p12_001_artifact|selection|selected_count|active_allocation|expected_branch_name|expected_branch_ref`. This avoids a self-referential record hash.
- The only mappings are `memory -> codex/phase-12a-memory`, `cost_router -> codex/phase-12b-cost-router`, `multi_agent -> codex/phase-12c-multi-agent`, `domain_command -> codex/phase-12d-domain-command`, and `none -> null`. `none` requires `selected_count=0`; every other value requires `selected_count=1`; all require `active_allocation=0`.
- ReleaseEng/Engineering must sign the exact payload, cycle, accepted P12-001 head, and selection. The P12-001 approval dependency retains the independent Architecture, Security, Product, and Data decisions.
- The CAS receipt requires the approved local Git adapter, exact governance ref, parseable execution time, `actual_sha == expected_sha`, a different valid `new_sha`, success without conflict, and zero `main`, remote, specialist-ref, or production writes.
- Governance topology requires the exact governance branch/worktree/ref and CAS result, zero specialist refs/worktrees, no unexpected path, gitlink, nested Git repository, or credential-like untracked file.
- Security additionally requires zero critical/high CVEs and zero unknown licenses in the bounded change set. Verify emits a structured selection verification; Evidence binds all task artifacts plus the six immutable P12-001 inputs.
- Rollback preserves the immutable selection and CAS receipt, keeps allocation at zero, and creates no specialist ref/worktree. The runner does not execute the CAS itself or fabricate the owner record.

These fixed mappings are a reversible execution-contract assumption derived from the Phase 12 task names. An actual approved plan can change them before formal P12-002 execution through the applicable ADR/governance process. No real selection has been made.

## Difficulties and solutions

### Pre-commit artifact identity

Exact equality between an artifact's recorded generation head and the later accepted commit would permanently block a valid sequence. The affected P12-000-to-P12-001 and P12-001-to-P12-002 checks now use `git merge-base --is-ancestor`, while status head, gate hash, and artifact content hashes remain exact.

### BOM-preserving Catalog CAS

The first atomic replacement wrote valid UTF-8 bytes without the original BOM. Windows PowerShell 5 then used the system code page and rejected the Catalog. The repair restored `EF-BB-BF`, retained atomic replacement semantics, and validated through the repository's own PowerShell 5 compatibility loader. Prefix/suffix comparison proves only the P12-002 task segment changed.

### Exact multilingual contract

One Base64 character changed `证明` to a different character. The failing exact-string fixture isolated the error; the Catalog and WorkPreflight constant were corrected as one root-cause unit. The final fixture compares the decoded value byte-for-byte.

## Affected regression

| Check | Result | Measured evidence |
|---|---:|---:|
| Initial P12-002 Catalog/runner contract | failed as expected | exit `1`; exact contract and accepted inputs absent |
| BOM-loss validation | failed as expected | PowerShell data-file parse rejected before task execution |
| Exact required-change validation | failed as expected | `证明` mismatch isolated |
| Final TaskGate contract suite | passed | exit `0`; about 24 seconds |
| IntegrationSmoke contract suite | passed | exit `0`; tracked writes `0` |
| PhaseEntry contract suite | passed | exit `0`; implementation writes `0` |
| PhaseMerge contract suite | passed | exit `0`; remote writes `0` |
| P12-002 Catalog isolation | passed | prefix/suffix exact; outputs `11`, directories `1`, files `3`, inputs `9`, changes `1` |
| Missing accepted P12-001 dependency probe | fail-closed without write | missing inputs `6`, dependency failures `1`, production writes `0` |
| Real P12A-000 CLI probe | rejected before materialization | exit `2`; probe/status/evidence absent before and after |
| Conditional runner inventory | passed | 24 total; 5 specialized; 19 fail-closed |
| `git diff --check` | passed | exit `0` |

Synthetic fixtures accept one fully bound `multi_agent` record and one fully bound `none` record. They reject `selected_count=2`, a branch for a different capability, CAS actual/expected mismatch, and any existing specialist branch. Synthetic `multi_agent` is test data, not the project Multi-Agent decision requested for the later data-driven selection.

## STAR record

### Situation

P12-002 had a safe global fail-closed guard but no executable contract for converting an accepted P12-001 decision into one immutable, owner-signed selection and one governance-ref CAS without allocating specialist topology.

### Task

Make that future transition mechanically verifiable without selecting a real capability, fabricating acceptance, running a real CAS, or creating a Phase 11/12 branch or worktree.

### Action

Closed the root cause across accepted P12-001 Git-object dependencies, ancestor-valid artifact identity, XOR selection, versioned payload hashing, exact capability-to-branch mapping, owner binding, expected-SHA CAS receipt, zero-allocation topology, seven modes, BOM-preserving Catalog CAS, rollback, and positive/negative fixtures.

### Result

- Capability existence: P12-002 mode coverage improved from `0/7` to `7/7`; conditional registry coverage improved from `4/24` to `5/24`, while `19/24` tasks remain fail-closed.
- Behavioral improvement: two valid synthetic forms pass and four malformed/unsafe forms fail; missing accepted dependencies fail with six exact missing inputs and no write.
- Governance result: no P12-002 evidence/status was created, no real capability was selected, no CAS was executed, allocation remains nonexistent, and no specialist branch/ref/worktree, remote, acceptance, or production mutation occurred.
- Guardrails: all four runner suites, Catalog isolation, dependency behavior, real P12A fail-closed behavior, and diff checking pass with zero unexpected writes.

These results demonstrate runner-contract readiness only. They do not demonstrate accepted P12-001, a real owner signature, a successful governance CAS, a data-supported Multi-Agent choice, specialist implementation, Release C readiness, or production behavior.

## Current hashes

- `Invoke-TaskGate.ps1`: `8a6b4b410b146c03ba0f657aa5b4c8b38ea9ac9ab5904f74a1d81069cc52b30d`
- `TaskGateCatalog.psd1`: `86010c29e243b49d5cc333deab5114bb93c27602731a5bef8b47b24d0bf675ad`
- `Invoke-TaskGate.Tests.ps1`: `fb1987e9e21658bd36345cd8f12112649f293af509f35d79c2bc19760e051593`

## Pending external boundary

P12-002 remains `not_started`. Actual execution requires formally accepted P12-001 evidence on the exact clean governance ref/worktree, a real owner-signed record, and an authorized expected-SHA CAS. Missing these inputs blocks only P12-002; other safe repair/enabler work remains eligible.
