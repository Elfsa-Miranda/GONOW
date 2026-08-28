# P12-000 runner contract enabler

- Classification: `phase-10/repairs`
- Scope: safe local runner, Catalog, and contract-test enabler only
- Baseline HEAD: `2e1220d022d4f507becad367f636dbe0990e9613`
- Execution mode: `local_provisional`
- Recorded: `2026-08-02` (`Asia/Shanghai`)

## Reproduction

No `D:\GO_NOW-release-c-governance` or Phase 12 worktree, `codex/release-c-governance` or Phase 12 ref, P12 task evidence, or P12 task status existed before this repair.

The contract test was added before the runner implementation. Its first run exited `1` because `TASK-P12-000` still had the generic Catalog sentence, omitted the immutable Release C selection/trigger/status and Release B inputs, had no dedicated seven-mode handler set, and remained fail-closed in the conditional registry. The complete P12-000 contract surface was added together before the next test cycle.

After Catalog materialization, the single-capability positive fixture produced a second distinct failure: input schema, window, five-option set, and dependency binding all appeared empty at the same time. Detailed check counters established that this was one runtime binding defect rather than four unrelated schema defects.

## Root cause and impact surface

P12-000 existed only as task inventory. A generic runner could not prove the mandatory comparison of `12A`, `12B`, `12C`, `12D`, and `none`; XOR selection; Product ownership; independent Engineering/Security/Data review; input denominators and confidence ranges; costs; risks; rollback; immutable Git-object evidence; or the requirement that every unselected package remain `not_started` with zero branches.

The positive-fixture failure had a PowerShell-specific root cause. `$input` is an automatic variable and variable names are case-insensitive, so the P12 code's `$Input` parameter and locals resolved to the automatic pipeline enumerator. The defect affected input validation, analysis evidence binding, governance dependency loading, and the Preflight, WorkPreflight, WorksetVerify, and Security handlers. It was repaired as one impact surface.

## Reversible repair

- `TASK-P12-000` is registered only after all seven specializations exist: `Preflight`, `WorkPreflight`, `WorksetVerify`, `Verify`, `Security`, `RollbackVerify`, and `Evidence`. The other 21 conditional tasks remain explicitly fail-closed.
- Catalog `required_changes[]` preserves the exact task-card text. Read-only inputs now include the immutable Release C path selection, Phase 12 trigger evidence, accepted REL-C status, and accepted/stable Release B record. The write allowlist is limited to P12-000 analysis/evidence, its phase manifest, and task status.
- Dependency validation reads those records from `refs/heads/codex/release-c-governance` Git objects, revalidates the REL-C XOR/signature/CAS contract, binds the Phase 12 alternative evidence hash to the trigger object's SHA-256, and requires accepted/stable Release B.
- Input validation requires exactly five alternatives, explicit presence of every numeric/schema field, a bounded `Asia/Shanghai` window, positive denominators, valid confidence intervals, explicit risk, `usd_per_successful_task` cost, rollback strategy, hashes, and no raw user data.
- Analysis validation permits exactly one of `12A|12B|12C|12D` or `none`. A capability selection has `selected_count=1`; `none` has `selected_count=0`. Every unselected capability must map to its exact task ID with `status=not_started` and `branch_count=0`.
- Product owner signature and distinct, unexpired Engineering/Security/Data approvals bind the cycle, accepted landing SHA, selected outcome, and evidence SHA-256.
- Governance worktree validation requires the exact clean `D:\GO_NOW-release-c-governance` path and branch, exact governance head, accepted Release B ancestry, no specialist branches, no nested Git repository, no gitlink, and no credential-like untracked file.
- Phase entry reuses the frozen historical regression helper while keeping the accepted Release B construction base distinct from the descendant governance evidence head. The same 542 Agent unit, 144 Agent contract, and 82 Flutter minimums remain fail-closed.
- The automatic-variable collision was removed by using `InputDocument`, `SourceInput`, and `InputState`; `-Input` remains an explicit parameter alias for compatibility.
- The runner can produce at most `ready_for_review`. It does not choose an actual capability, create a branch/worktree, mark acceptance, push, merge, or write production data.

## Difficulties and solutions

### Windows PowerShell large data-file validation

The Catalog is a BOM-bearing, generated one-line PowerShell data file. The first content-addressed transform correctly stopped before replacement because `Import-PowerShellDataFile` hit the known `SafeGetValue` complexity ceiling on the complete task map. The bounded repair used the runner's per-task AST safe-evaluation strategy, retained the old-hash CAS, parsed the complete temporary file, validated P12-000 and the P12-001 suffix, used an explicit same-directory backup for atomic replacement, and removed temporary/backup files after success.

Old Catalog SHA-256 was `6dd2280b2db8f45f754eb910cf19e31fa2b72e6b985671c68b3868e69e554efb`; new SHA-256 is `3c78225bc34b65745b12f3d2971ae56b4557343d4ef376c774ab2499cf2261cb`. Decoded-text comparison proves the prefix before P12-000 and suffix beginning at P12-001 are exact; only the target segment changed.

### PowerShell automatic `$input`

The first detailed positive result had `alternative_count=0` plus schema, window, set, and dependency mismatches. That correlated failure set led to the automatic-variable collision. Renaming all P12 occurrences in one repair restored both the single-capability and `none` positive paths without relaxing any validator.

The final review then found a separate PowerShell coercion edge: a missing numeric property casts to zero. Required-property checks were added across inputs, alternative metrics, analysis rows, unselected packages, owner signatures, and approvals so a missing field cannot satisfy a legitimate zero-valued contract.

### Fixture pipeline precedence

The first approval fixture piped only the last array expression because of PowerShell operator precedence. Parenthesizing the complete role array produced three reviewer objects. The enhanced failure message retained per-check JSON so any future positive-path rejection exposes the entire counter set.

### Read-only tool substitutions

The environment denied execution of `rg.exe`, so read-only inspection used `Select-String`. A later Catalog field-count probe incorrectly dot-sourced the data file; it was replaced with the same per-task AST reader used by the runner. Neither diagnostic issue changed repository semantics or caused a task rerun.

## Affected regression

| Check | Result | Measured evidence |
|---|---:|---:|
| Initial P12 Catalog/runner contract | failed as expected | exit `1`; exact contract and seven handlers absent |
| First bound analysis fixture | failed with new signal | input schema/window/set/dependency counters exposed the `$input` collision |
| Final TaskGate contract suite | passed | exit `0`; approximately 16 seconds |
| PhaseEntry contract suite | passed | exit `0`; 0 implementation writes |
| PhaseMerge contract suite | passed | exit `0`; 0 remote writes |
| IntegrationSmoke contract suite | passed | exit `0`; 0 tracked writes |
| PowerShell parser | passed | runner and test parse errors `0` |
| P12 Catalog isolation | passed | prefix exact, suffix exact, one changed segment; outputs `12`, read-only inputs `7` |
| Current missing-formal dependency probe | fail-closed without exception | `passed=false`, missing inputs `5`, production writes `0` |
| Real P12-001 CLI probe | rejected before materialization | exit `2`; probe/status absent before and after |
| Conditional runner inventory | passed | 24 total; 3 specialized; 21 fail-closed |
| `git diff --check` | passed | exit `0` |

Behavioral fixtures accept one fully bound `12C` selection and one fully bound `none` outcome. They reject two selected rows, `selected_count=1` for `none`, a started unselected package, an expired independent reviewer, a zero denominator, and missing `numerator`, `selected_count`, or `branch_count` fields that would otherwise coerce to zero. `12C` is only synthetic test data and is not the project's Multi-Agent decision.

## STAR record

### Situation

Phase 12 had a safe global fail-closed guard but no executable P12-000 comparison entry, and the generic Catalog could not preserve its immutable inputs or XOR governance contract.

### Task

Make the future data-driven Phase 12 selection mechanically executable without selecting Multi-Agent or another capability early, creating any branch/worktree, consuming raw user data, requesting approval, pushing, merging, or claiming acceptance.

### Action

Closed the root cause across immutable dependency reads, five-option metric contracts, XOR and `none` semantics, owner/reviewer binding, branch isolation, historical regression, seven gate modes, Catalog CAS, PowerShell automatic-variable safety, and positive/negative tests.

### Result

- Capability existence: P12-000 dedicated mode coverage improved from `0/7` to `7/7`; conditional registry coverage improved from `2/24` to `3/24`, while `21/24` tasks remain fail-closed.
- Behavioral improvement: both valid decision forms now pass isolated validation, and nine unsafe/malformed variants are rejected. The real P12-001 CLI still exits `2` before evidence/status materialization.
- Governance result: no real option was selected, no score or synthetic fixture was presented as production evidence, no Phase 12 branch/ref/worktree was created, and no remote/production mutation occurred.
- Guardrails: all four runner suites, parsing, Catalog isolation, missing-input dependency behavior, diff check, and the real unimplemented-task probe have zero unexpected failure.

These results demonstrate runner-contract readiness only. They do not demonstrate Release B acceptance/stability, a formally selected Phase 12 path, Memory/RAG/Multi-Agent/Domain value, production measurement, owner approval, or Release C readiness.

## Current hashes

- `Invoke-TaskGate.ps1`: `ee4473b600d02b455d39e94c7993577e1d3435e77983b905c598dda47c1d9b69`
- `TaskGateCatalog.psd1`: `3c78225bc34b65745b12f3d2971ae56b4557343d4ef376c774ab2499cf2261cb`
- `Invoke-TaskGate.Tests.ps1`: `b6fd90cc564de919985d8448707efa75d1f12166bb75575aae7654a4c3bcd920`

## Pending external boundary

P12-000 remains `not_started`. Its actual Preflight requires formal REL-C-000 acceptance with path `phase12`, accepted/stable Release B, immutable five-option trigger evidence, the exact clean governance worktree/ref, and current owner/reviewer decisions. Missing these inputs blocks only P12-000; all other safe repair/enabler work remains eligible.
