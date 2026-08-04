# P11-000 runner contract enabler

- Classification: `phase-10/repairs`
- Scope: safe local runner, Catalog, PhaseEntry, and contract-test enabler only
- Baseline HEAD: `841b23d`
- Execution mode: `local_provisional`
- Recorded: `2026-08-02` (`Asia/Shanghai`)

## Reproduction

No `D:\GO_NOW-phase-11-rag` worktree, `codex/phase-11-rag` ref, Phase 12 specialist ref, Release C governance ref, P11 task evidence, or P11 task status existed before the repair.

Two tests were added before the implementation and failed independently:

1. The behavioral PhaseEntry fixture created a Release B base commit and a descendant Release C governance-selection commit. The manifest was created, but `formal_phase_base_oid` incorrectly used the governance head and did not preserve `source_head_oid` separately.
2. The TaskGate contract suite exited `1` because `TASK-P11-000` retained a generic Catalog placeholder, omitted the immutable Release B/Release C inputs, had no seven-mode specialization, and remained intentionally unregistered by the conditional-task fail-closed guard.

The complete first failure set was collected before changing production runner code. No product test, remote operation, or task action was retried during reproduction.

## Root cause and impact surface

Phase entry previously assumed that the dependency record head and the phase construction base were the same commit. That assumption is valid for ordinary sequential phases but false for P11: P11 must consume an accepted governance decision at the descendant governance head while creating its branch from the earlier accepted Release B SHA.

P11-000 also existed only as Catalog inventory. Registering it without dedicated handlers would have permitted generic success without proving the strict RAG trigger, data rights, immutable selection, accepted Release B base, branch/worktree isolation, historical regression, or rollback boundary. Leaving it unregistered was safe but made the future task non-executable.

The affected surface was therefore treated as one root-cause unit: PhaseEntry identity, P11 Catalog inputs/work contract, immutable Git-object reads, trigger math, approvals, branch isolation, seven TaskGate modes, status projection, full historical regression, evidence hashing, rollback, and tests.

## Reversible repair

- `Invoke-PhaseEntryRegression.ps1` now records `phase_base_oid`/`formal_phase_base_oid` from the explicit phase base and records `source_head_oid` independently. It also requires the source head to be a valid ancestor of the current selection head.
- `TASK-P11-000` is registered only after all seven modes exist: `Preflight`, `WorkPreflight`, `WorksetVerify`, `Verify`, `Security`, `RollbackVerify`, and `Evidence`. The remaining 22 conditional Release C task cards remain fail-closed.
- Catalog `required_changes[]` now preserves the task-card text exactly. Catalog lists the immutable selection, trigger index, accepted REL-C status, and Release B record as read-only inputs.
- The dynamic external license/privacy/residency/deletion locators are not guessed before owner evidence exists. They are required as `immutable://` locator/SHA-256 pairs inside the Catalog-listed and hash-bound `rag-trigger-evidence.json` index. This is the reversible interpretation of the card's external-evidence requirement; changing the actual locator scheme requires only the future governance input and, if semantics change, an ADR.
- The trigger validator recomputes numerator/denominator rate, requires a positive denominator, exact calibrated threshold `0.20`, rate strictly greater than the threshold, a confidence lower bound also greater than the threshold, a bounded window in `Asia/Shanghai`, no raw user data, signed ADR evidence, Product signature, and distinct unexpired Data/Engineering/Security approvals.
- Dependency validation reads accepted selection/status/gate/trigger/Release B JSON from `refs/heads/codex/release-c-governance` Git objects, validates their SHA-256 bindings, revalidates the REL-C XOR/signature/CAS contract, requires the selected `phase11` alternative evidence hash to equal the trigger Git-object SHA-256, and requires accepted/stable Release B.
- Governance preflight requires the exact governance head, accepted Release B ancestry, no P11/P12 specialist branch, and no unexpected dirty path. Post-creation gates require the exact normalized `D:\GO_NOW-phase-11-rag` worktree, exact accepted Release B HEAD, one local/no remote P11 ref, and zero Phase 12 or sibling specialist refs.
- `Preflight` runs the locked Python suite, prior Flutter journeys, and current runner contract before atomically creating the manifest. Frozen minimums remain 542 unit, 144 contract, and 82 Flutter tests; skipped/xfail/failure/provision drift all fail closed.
- Workset order no longer depends on files produced by later modes. The intended order is preflight → work preflight → branch/reference import → workset → verify → security → rollback verify → evidence. Evidence requires and hashes the rollback receipt.
- The runner can only produce `ready_for_review`; no accepted transition, branch creation, deletion, push, production write, or path choice was added.

## Difficulties and solutions

### Governance head versus construction base

The original manifest field was semantically overloaded. A two-commit behavioral fixture made the defect visible and now proves that the descendant governance source head remains distinct from the accepted Release B construction base.

### One-line Catalog and Windows PowerShell 5

The Catalog is a BOM-bearing, generated one-line PowerShell data file. The first inspection through `Import-PowerShellDataFile` hit the known `SafeGetValue` dynamic-expression limitation, so trusted read-only inspection used the repository's AST/script-block compatibility path.

The content-addressed transform verified old SHA-256 `49534a35719bd34ce655c82a3320360a5e9ab521d378f721fe7da32617b9435b`. A first transform attempt found zero matches because Windows PowerShell 5 decoded a no-BOM Chinese literal through the system code page; fixed Base64 UTF-8 reconstruction removed that ambiguity. The transformed temporary file then parsed successfully, but `.NET File.Replace(..., $null)` rejected a null backup path twice. The final bounded alternative used an explicit same-directory backup, validated the replaced Catalog, and removed the backup only after success. New Catalog SHA-256 is `6dd2280b2db8f45f754eb910cf19e31fa2b72e6b985671c68b3868e69e554efb`; no temporary or backup file remains.

### Git for Windows path form

`git rev-parse --show-toplevel` returns `D:/...`, while the task card uses `D:\...`. Direct ordinal comparison would permanently reject the correct worktree. The runner now canonicalizes through `System.IO.Path.GetFullPath` before the exact comparison; the contract test freezes this normalization.

### Gate-order self-lock

The first implementation review showed that Workset required outputs generated only by later Verify/Security/Evidence modes. Those future outputs were removed from the Workset precondition, and the rollback receipt was moved into the final Evidence set. This was corrected before any P11 task run.

## Affected regression

| Check | Result | Measured evidence |
|---|---:|---:|
| Initial PhaseEntry identity fixture | failed as expected | governance head was used as formal phase base |
| Initial TaskGate contract fixture | failed as expected | exit `1`, missing P11 Catalog/runner contract |
| Final TaskGate contract suite | passed | exit `0`, `10,668.94 ms` |
| Final PhaseEntry contract suite | passed | exit `0`, `1,981.65 ms` |
| PhaseMerge contract suite | passed | exit `0`, `1,107.71 ms` |
| IntegrationSmoke contract suite | passed | exit `0`, `858.86 ms` |
| PowerShell parser | passed | 4 changed scripts/tests, 0 parse errors |
| P11 dependency probe with current missing formal inputs | fail-closed without exception | `passed=false`, `dependency_failures=1`, missing inputs `5` |
| Real P11-001 CLI probe | rejected before materialization | exit `2`; evidence/status absent before and after |
| Conditional runner inventory | passed | 24 total; 2 specialized; 22 fail-closed |
| P11/12/Release C local and remote ref probe | passed | 0 refs |
| `D:\GO_NOW-phase-11-rag` and P11 task evidence/status | absent | no task action started |
| `git diff --check` | passed | exit `0` |
| Added non-GET HTTPS mutation / `git push` / `git update-ref` / accepted transition | 0 | added-line scan |
| Added recursive deletion | test fixture cleanup only | validated random directory under system temp |

Behavioral fixtures accept one fully bound trigger and reject: rate equal to 20%, denominator zero, confidence lower bound below 20%, and expired independent approval. Static handler/AST checks additionally require every Phase 12 specialist ref to be rejected and every one of the seven P11-000 modes to be specialized.

## STAR record

### Situation

P11 had a safe global fail-closed guard, but no executable task-specific entry. The generic PhaseEntry manifest also could not represent the required split between Release B base and Release C governance head.

### Task

Make the future P11 entry mechanically executable without selecting RAG, creating a specialist branch/worktree, importing production data, requesting approval, pushing a ref, or claiming acceptance.

### Action

Closed the root cause across identity, immutable dependency reads, strict trigger math, governance/data evidence, branch isolation, full historical regression, seven gates, Catalog CAS, rollback/evidence order, and positive/negative tests.

### Result

- Capability existence: P11-000 dedicated mode coverage improved from `0/7` to `7/7`; PhaseEntry now represents two distinct OIDs; the conditional registry is `2/24` implemented with the remaining `22/24` still fail-closed.
- Behavioral improvement: both baseline failures now pass, and four frozen unsafe trigger fixtures are rejected. The P11-001 real CLI probe still exits `2` without creating evidence or status.
- Governance result: no RAG threshold evidence was supplied or accepted, no Release C path was selected, no P11/P12 branch/ref/worktree was created, and no remote/production mutation occurred.
- Guardrails: all four affected/adjacent suites, AST parsing, Catalog parse, diff check, missing-input dependency probe, and branch/ref scan finished with zero unexpected failure.

These results demonstrate runner-contract readiness only. They do not demonstrate a >20% production knowledge-gap share, RAG quality, data rights, Release B acceptance/stability, Release C selection, Memory value, Multi-Agent value, production rollout, or owner approval.

## Current hashes

- `Invoke-PhaseEntryRegression.ps1`: `42b025aa2a8ff911221b5329d4bda6a1bfe1c9f2babfdcf44d1200e835e515e0`
- `Invoke-TaskGate.ps1`: `5ea349302c9cd60a73ef40083e2959e61e5900b7127e65d06397227e54bbf323`
- `TaskGateCatalog.psd1`: `6dd2280b2db8f45f754eb910cf19e31fa2b72e6b985671c68b3868e69e554efb`
- `Invoke-PhaseEntryRegression.Tests.ps1`: `eea299fc5f964c213af43445509c7d3a0b2ffe2899ddc44c593861d02a399c53`
- `Invoke-TaskGate.Tests.ps1`: `c93f4e5168767bfffd23767cbcf703603d70235d85ca25955cc8a4eb9a657d3b`

## Pending external boundary

P11-000 remains `not_started`. Its actual Preflight remains unavailable until REL-C-000 is formally `accepted` with path `phase11`, Release B is formally accepted/stable, the immutable trigger/data-governance evidence exists, and the required owner/reviewer decisions are current. Missing these inputs blocks only P11-000; all other safe repair/enabler work remains eligible.
