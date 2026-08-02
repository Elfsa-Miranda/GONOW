# P12-001 runner contract enabler

- Classification: `phase-10/repairs`
- Scope: safe local runner, Catalog, and contract-test enabler only
- Baseline HEAD: `7f960e042e5d7a1d9afd3fc2b18a73b557b11f56`
- Execution mode: `local_provisional`
- Recorded: `2026-08-02` (`Asia/Shanghai`)

## Reproduction

P12-000 is not accepted and no Release C governance worktree/ref, P12 task evidence/status, selected-capability ADR, or specialist branch exists. The real P12-001 task therefore remains unavailable.

A contract test was added before implementation. Its first run exited `1` because P12-001 retained a generic Catalog sentence, omitted all six accepted P12-000 inputs, had no dedicated seven-mode implementation, and remained fail-closed in the conditional registry.

After the full P12-001 contract was added, the first pure-approval run rejected all intended unsafe fixtures except one: a reviewer using the same `actor_id` as the Architecture owner was accepted. This was a new, distinct signal and exposed a shared P12-000/P12-001 identity-set defect.

## Root cause and impact surface

P12-001 existed only as task inventory. The generic runner could not prove `compare>=2`, threat/data/compatibility/load/cost/rollback coverage, accepted P12-000 input hashes, the selected or `none` outcome, ADR byte identity, a maximum approval age of 14 days, non-future and unexpired decisions, Architecture ownership, independent Security/Product/Data reviewers, or zero implementation/production writes.

The identity defect came from PowerShell collection construction. Concatenating a string owner ID with an array of reviewer IDs caused the reviewer array to be stringified, so `Group-Object` did not see a cross-role duplicate. The same expression existed in the already implemented P12-000 selector and was repaired in both validators as one root-cause unit.

## Reversible repair

- P12-001 is registered only after all seven handlers exist: `Preflight`, `WorkPreflight`, `WorksetVerify`, `Verify`, `Security`, `RollbackVerify`, and `Evidence`. P12-002 and the other 19 conditional tasks remain fail-closed.
- Catalog `required_changes[]` now preserves `compare>=2 -> threat/data -> load -> rollback -> sign` byte-for-byte. The write set is limited to the selected ADR, the P12-000 approval gate, P12-001 evidence, and P12-001 status.
- The six read-only dependencies are accepted P12-000 status, artifact index, analysis, analysis verification, gate results, and Phase 12 manifest. Dependency validation reads them from `HEAD` Git objects, validates their SHA-256/transitive artifact bindings, requires seven passed P12-000 modes, formal accepted status, and zero recorded historical-regression drift.
- Approval evidence permits `12A|12B|12C|12D|none`, requires at least two unique compared alternatives, and requires the selected result to be among them. Every alternative contains nonempty threat, data, compatibility, load, cost, and rollback fields with positive load denominator and `usd_per_successful_task` cost semantics.
- The proposal SHA-256 is recomputed from the ADR SHA-256, cycle, selected result, accepted P12-000 head, artifact SHA-256, and analysis SHA-256. Architecture and three independent Security/Product/Data decisions bind that proposal and ADR.
- All four decisions must be approved no more than 14 days before evaluation, not future-dated, and unexpired. Actor IDs are built as true arrays and must be pairwise distinct.
- Verify recomputes the ADR file SHA-256, binds cycle/head/selection, requires Options/Threat/Data/Compatibility/Load/Cost/Rollback/Approvals sections, validates the P12-000 approval gate, and emits a structured approval verification.
- Security recomputes identity and authorization counters, scans the bounded documents for secret/PII, rejects raw user data and implementation boundaries, and requires the exact governance worktree state.
- Governance branch checks require exact branch/head/path, zero specialist refs, no unexpected dirty paths, no gitlink, no nested Git repository, no credential-like untracked file, and successful Git queries.
- Rollback is documentation-only: reject the ADR candidate, leave the selected capability dormant, preserve accepted P12-000 evidence, and create no specialist branch/worktree.
- The runner can produce at most `ready_for_review`. It does not create the ADR, select a real capability, fabricate approvals, accept a task, create a branch/worktree, push, merge, or write production data.

## Difficulties and solutions

### Dispatcher patch localization

An intermediate patch intended for the final status dispatcher matched the first P12-000 handler inside Security. AST parsing still succeeded, but review immediately showed references to dispatcher-only `$ExitCode` and `$Result` inside the handler. The misplaced block was removed before testing, Security was restored, and the status projection was reinserted with `Add-GateResult`/`Add-CommandRecord` adjacency as a unique anchor.

### Actor-array coercion

The P12-001 independence fixture revealed that `string + object[]` was not a safe actor-set constructor. Both P12 validators now concatenate `@(<owner>) + @(<reviewers>)`. P12-000 gained the same cross-role collision negative test, so the repair is protected across both consumers.

### One-line Catalog CAS

The BOM-bearing Catalog was transformed only after SHA-256 `3c78225bc34b65745b12f3d2971ae56b4557343d4ef376c774ab2499cf2261cb` matched. The temporary file used full AST parsing and per-task safe evaluation, validated P12-001 plus the P12-002 boundary, then used same-directory atomic replacement with an explicit backup. New SHA-256 is `0ff75cc490fdf9a0e1170c35a8fb59c94347a799551f1ef61ae08ab18b7729c0`; no temporary/backup remains. Prefix and suffix comparison proves only the P12-001 segment changed.

## Affected regression

| Check | Result | Measured evidence |
|---|---:|---:|
| Initial P12-001 Catalog/runner contract | failed as expected | exit `1`; exact contract and accepted inputs absent |
| First identity-collision fixture | failed as expected | duplicate owner/reviewer was incorrectly accepted |
| Final TaskGate contract suite | passed | exit `0`; approximately 20 seconds |
| PhaseEntry contract suite | passed | exit `0`; implementation writes `0` |
| PhaseMerge contract suite | passed | exit `0`; remote writes `0` |
| IntegrationSmoke contract suite | passed | exit `0`; tracked writes `0` |
| PowerShell parser | passed | parse errors `0` |
| P12-001 Catalog isolation | passed | prefix/suffix exact; directory `1`, files `2`, outputs `11`, inputs `9` |
| Missing accepted P12-000 dependency probe | fail-closed without exception | missing inputs `6`, dependency failures `1`, production writes `0` |
| Real P12-002 CLI probe | rejected before materialization | exit `2`; probe/status absent before and after |
| Conditional runner inventory | passed | 24 total; 4 specialized; 20 fail-closed |
| `git diff --check` | passed | exit `0` |

Synthetic fixtures accept one fully bound `12C` proposal and one fully bound `none` proposal. They reject a one-option comparison, missing rollback, approval older than 14 days, future approval, owner/reviewer actor collision, an unbound proposal hash, and raw user data. P12-000 separately rejects the same owner/reviewer collision. Synthetic `12C` is not a project Multi-Agent decision.

## STAR record

### Situation

P12-001 had a safe global fail-closed guard but no executable approval contract, while the next task requires an accepted, independently reviewed, hash-bound single outcome.

### Task

Make future ADR approval mechanically executable without choosing a real capability, authoring an evidence-free ADR, fabricating owner/reviewer decisions, creating specialist topology, or crossing remote/production boundaries.

### Action

Closed the root cause across accepted P12-000 Git-object dependencies, two-or-more option comparison, threat/data/compatibility/load/cost/rollback fields, ADR/proposal hashing, 14-day approval age, reviewer independence, exact governance worktree isolation, seven modes, Catalog CAS, rollback, and positive/negative fixtures.

### Result

- Capability existence: P12-001 mode coverage improved from `0/7` to `7/7`; conditional registry coverage improved from `3/24` to `4/24`, while `20/24` tasks remain fail-closed.
- Behavioral improvement: two valid synthetic decision forms pass and seven malformed/unsafe P12-001 forms fail. The shared actor collision is now rejected by both P12-000 and P12-001.
- Governance result: no ADR or approval artifact was created, no real capability was selected, P12-001 remains `not_started`, and no branch/ref/worktree, remote, acceptance, or production mutation occurred.
- Guardrails: all four runner suites, parsing, Catalog isolation, missing-input dependency behavior, diff check, and the real unimplemented P12-002 probe have zero unexpected failures.

These results demonstrate runner-contract readiness only. They do not demonstrate accepted P12-000, a real selected capability, valid owner/reviewer decisions, ADR approval, Multi-Agent value, specialist implementation, Release C readiness, or production behavior.

## Current hashes

- `Invoke-TaskGate.ps1`: `7295aea23a35d91c931c87563a7c63a6cf9700b479b7e0e2887c5554386f2837`
- `TaskGateCatalog.psd1`: `0ff75cc490fdf9a0e1170c35a8fb59c94347a799551f1ef61ae08ab18b7729c0`
- `Invoke-TaskGate.Tests.ps1`: `7d665ff965898afb71745ed222af38db551d35e45982fef8d8ba0b5b1a86dc08`

## Pending external boundary

P12-001 remains `not_started`. Actual execution requires a formally accepted P12-000 commit, its complete hash-bound evidence, the exact clean governance worktree/ref, a real outcome, an ADR comparing at least two options, and current Architecture/Security/Product/Data decisions. Missing these inputs blocks only P12-001; other safe repair/enabler work remains eligible.
