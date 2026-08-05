# REL-C-000 runner contract enabler

- Classification: `phase-10/repairs`
- Scope: safe local runner/Catalog/test enabler only
- Baseline HEAD: `e30a3dfb96f6c758e6b048453c036414aca43ee1`
- Execution mode: `local_provisional`
- Recorded: `2026-08-02` (`Asia/Shanghai`)

## Reproduction

The clean Phase 10 worktree had no `D:\GO_NOW-release-c-governance` directory, no `refs/heads/codex/release-c-governance`, and no local or remote `codex/phase-11*` or `codex/phase-12*` specialist ref. No Release C action had started.

The first new contract run failed in `1,225.01 ms` with exit `1`:

```text
negative: REL-C-000 Catalog must preserve the task-card required change verbatim
```

Inspection established the complete failure set before repair:

1. `Get-TaskEvidenceDirectory` sent `TASK-REL-C-000` to the generic singular `docs/execution/evidence/release/` path instead of the card's plural `releases/REL-C-000/` path.
2. All seven registered modes used generic handlers and therefore did not prove Release B acceptance/stability, path XOR, signatures, approval expiry, branch absence, cycle immutability, or CAS binding.
3. `TaskGateCatalog.psd1` retained a generic placeholder instead of the task card's verbatim required change.

## Root cause and impact surface

REL-C-000 was present in the Catalog as an inventory item but had never received a task-specific executable gate projection. The generic runner could therefore produce a syntactically successful result without enforcing the card's core invariant: exactly one of `phase11|phase12|none`, selected once from an accepted and stable Release B baseline with an expected-SHA CAS and no pre-existing specialist branch.

The impact surface included evidence routing, all seven allowed TaskGate modes, status transition logic, work-contract materialization, Release B dependency validation, evidence hashing, security checks, rollback verification, and behavioral tests. The defect did not create a Release C branch, worktree, selection, remote write, production write, or accepted status.

## Reversible repair

- Added a dedicated plural evidence route before the generic Phase/release route.
- Replaced the Catalog placeholder with the exact, sealed task-card required change using an expected-hash atomic transform. The temporary transform script was removed; no temporary file remains in the worktree.
- Added dedicated state evaluators for the seven required modes, Release B dependencies, local/remote branch absence, changed-path allowlisting, and path-selection validation.
- Required formal governance, owner-accepted Release B, remote landing binding, `origin/main` ancestry, 744 non-overlapping rollout hours, unexpired approval evidence, and a zero-finding locked supply report before the governance action can start.
- Required alternatives to be exactly `phase11`, `phase12`, and `none`; exactly one total `selected=true`; a positive denominator, bounded confidence interval, risk list, and evidence hash for every alternative.
- Required distinct Architecture/Product owner signatures plus distinct Data/Engineering/Product/Security approvals, all bound to candidate SHA, cycle, path, evidence digest, and expiry.
- Required `refs/heads/codex/release-c-governance` CAS receipt fields `expected_sha`, `actual_sha`, and `new_sha`, with `expected_sha=actual_sha=accepted_landing_sha`, `new_sha` bound to HEAD/ref, result `updated`, conflict count `0`, and cycle rewrite count `0`.
- Required both local and remote `codex/phase-11*` and `codex/phase-12*` specialist refs to be absent. The governance branch itself remains the only permitted Release C governance ref.
- Kept the task transition limited to `ready_for_review`; the runner contains no accepted self-transition.
- Kept rollback non-destructive: it may identify an uncommitted empty worktree as removable but never removes it or rewrites an immutable cycle record.

## Difficulties and solutions

### Generated one-line Catalog

The Catalog is a single 536 KB serialized line, so a line-oriented patch could not safely target only REL-C-000. A content-addressed transform first verified SHA-256 `622356b355a8cc4fb3a4f5a2bce03bed45bac6a9a3138e42d9852df9b6df6853`, isolated the `TASK-REL-C-000` object boundaries, extracted the normative required change from the sealed execplan card, atomically replaced exactly one value, and produced SHA-256 `49534a35719bd34ce655c82a3320360a5e9ab521d378f721fe7da32617b9435b`.

### Windows PowerShell 5 source decoding

The first candidate comparison still failed because Windows PowerShell 5 interpreted newly added no-BOM Chinese test literals through the system code page. `ParseFile` exposed the same risk for a Chinese runner detail literal. Exact UTF-8 values are now reconstructed from fixed Base64 constants, while the BOM-bearing Catalog retains the normative Unicode bytes. This changes no product or task semantics.

### XOR negative case

The first behavioral negative fixture selected both `phase11` and `phase12` and was incorrectly accepted because the validator counted only selected rows matching the declared path. The validator now separately requires the total selected-row count to equal one. The same test now passes by rejecting the invalid fixture.

## Affected regression

| Check | Result | Duration / evidence |
|---|---:|---:|
| Initial TaskGate reproduction | failed as expected | `1,225.01 ms` |
| Final TaskGate contract suite | passed | `7,043.45 ms` |
| PhaseMerge contract suite | passed | `1,116.58 ms` |
| PhaseEntryRegression contract suite | passed | `690.28 ms` |
| IntegrationSmoke contract suite | passed | `877.30 ms` |
| PowerShell runner parser | `0` errors | direct AST parse |
| Current missing-input dependency probe | fail-closed | `passed=false`, `dependency_failures=1`, no exception |
| Actual specialist branch probe | passed | `specialist_branch_count=0`, `query_failure_count=0` |
| `git diff --check` | passed | exit `0` |
| Added executable HTTPS non-GET calls | `0` | added-line scan |
| Added executable `git push` / `git update-ref` calls | `0` / `0` | added-line scan; CAS text is validation-only |
| Added file deletion / production writes | `0` / `0` | added-line scan |

Behavioral fixtures now prove acceptance of one fully bound selection and rejection of: two selected sibling paths, expected-SHA CAS conflict, missing positive denominator, expired approval, and an existing specialist branch.

## STAR record

### Situation

The future Release C governance task existed in the execution inventory, but its generic runner path could not mechanically prevent concurrent Phase 11/12 starts or a stale/conflicting path decision.

### Task

Create a safe local enabler that makes the future decision executable and fail-closed without choosing a path, creating a branch/worktree, requesting approval, pushing a ref, or claiming acceptance.

### Action

Implemented one root-cause closure across route, Catalog, dependency state, XOR/CAS validation, seven modes, status projection, security/evidence/rollback contracts, and positive/negative behavioral tests.

### Result

- Capability existence: seven of seven registered REL-C-000 modes now have dedicated handlers; the exact three alternatives, two owner roles, four independent reviewer roles, 744-hour minimum, branch-absence rule, and CAS tuple are mechanically represented.
- Behavioral improvement: the baseline suite failed on the missing executable contract; the candidate suite passes and rejects all five frozen unsafe fixtures.
- Governance result: no governance decision was made. `path-selection.json`, governance worktree/ref, Phase 11/12 branch, remote write, production write, and accepted status all remain absent.
- Guardrails: all three adjacent runner suites stayed green; parser, diff, mutation scans, and actual branch query stayed at zero failures.

These are runner-contract and governance-safety results, not production Release C performance, RAG quality, Memory value, Multi-Agent value, or rollout evidence.

## Current hashes

- `Invoke-TaskGate.ps1`: `3d25dadf882c38444bcdc724f530f666af44ad7f6bdb70e7650edbfb3c465cb7`
- `TaskGateCatalog.psd1`: `49534a35719bd34ce655c82a3320360a5e9ab521d378f721fe7da32617b9435b`
- `Invoke-TaskGate.Tests.ps1`: `1eb208bc25d40f5b470de4df579a34cbf8ca916f189ecb0d8ff6390b5401e6e1`

## Pending external boundary

REL-C-000 itself remains `not_started`. It may run only after P10-011 and Release B are formally accepted, stable observation and approval-expiry fields are present, governance adoption is valid, the accepted landing commit is present in remote `main`, and no specialist branch exists. The later outer choice remains `phase11|phase12|none`; it does not select Multi-Agent. Any Phase 12 capability choice remains the separate P12-002 decision.
