# P12A-D-000 dormant work-package runner enabler

- Classification: `phase-10/repairs`
- Scope: safe local shared runner, Catalog, and contract-test enabler for P12A-000 through P12D-000
- Baseline HEAD: `787b77847bf48dffc7fe627d2b0e708656ac4e0a`
- Execution mode: `local_provisional`
- Recorded: `2026-08-02` (`Asia/Shanghai`)

## Reproduction

P12-002 is not accepted and no P12 selection record, work-package ADR/task plan, specialist branch, or P12A-D task status exists. None of the four real work-package tasks is currently executable.

One comprehensive contract test was added before implementation. Its first run exited `1` because all four tasks were absent from the conditional registry. The same inventory-only root cause affected every candidate: generic required changes, only three generic read inputs, no accepted P12-002 binding, no dormant-plan validator, no seven-mode specialization, and no exact task-specific security/CT profile.

The audit also found that P12B-000 and P12C-000 Catalog approval policies omitted the Finance reviewer explicitly required by `execplan.md`.

## Root cause and impact surface

The four cards are mutually exclusive alternatives, but they share the same governance transition: an accepted P12-002 selection must authorize exactly one documentation-only work package on the governance branch, with zero implementation commits and no specialist topology. Implementing them separately would duplicate dependency, branch, evidence, rollback, and status logic and invite drift.

The generic runner could not prove the selected capability, accepted P12-002 Git-object hashes, planning-only scope, atomic future task IDs, dedicated `990`/`999` IDs, CT profile, capability-specific guardrails, reviewer set, or absence of runtime/schema/branch writes.

## Reversible repair

- P12A-000, P12B-000, P12C-000, and P12D-000 use one shared runner framework with task-specific immutable definitions. Each is registered only after all seven modes exist.
- Each definition freezes its exact required change, exact Verify detail, execplan card SHA-256, selection name, ADR path, task-plan path, evidence directory, applicable CTs, security profile, and capability guardrail markers.
- The eight read-only dependencies are accepted P12-002 status, artifact index, selection, selection verification, CAS receipt, ref reservation, gate results, and the Phase 12 manifest.
- Dependency validation requires formal accepted status, seven passed P12-002 modes, an ancestor-valid artifact head, a successful conflict-free governance CAS whose new SHA is an ancestor of the accepted head, zero recorded writes outside the governance ref, selection-specific XOR result, zero active allocation, no created specialist ref/worktree, and a drift-free formal Phase 12 manifest.
- The manifest artifact is intentionally validated through P12-002's transitive `git-object:p12-001:` record, matching the actual P12-002 artifact index rather than inventing a local artifact path.
- The exact governance branch/ref/worktree is required, with zero Phase 11/P12 specialist refs and worktrees, no unexpected path, gitlink, nested Git repository, or credential-like untracked file.
- Every task plan must bind task ID, cycle, accepted P12-002 head and artifact hash, selected capability, at least one unique future atomic task ID, the dedicated `990` acceptance ID, the dedicated `999` merge ID, exact applicable CTs, `implementation_commit_count=0`, and `contract_change=false`.
- ADRs require Trigger Evidence, Atomic Tasks, Security and Privacy, Reliability, Acceptance and Merge, and Rollback sections. The task plan and ADR must both contain the task-specific guardrails.
- P12A binds negative consent, state/conflict/poisoning, deletion/export, backup non-resurrection, CT-009/015, and `SEC-PROMPT`.
- P12B binds factors, route reason, region/privacy, replay/non-regression, kill switch, quality/cost/budget ledger, and `SEC-NO-EXTRA`.
- P12C binds shared and branch budgets, `branch_count<=2`, deterministic merge/conflict, fallback, receipt-graph switch, CT-011, and `SEC-PROMPT`.
- P12D binds one write point, principal/approval/CAS/outbox, expand-contract compatibility, replay/restore, and `SEC-NO-EXTRA`.
- B/C now require three independent Eval, Finance, and Security approvals in both `reviewer_roles` and `approval_policy`; A and D retain their complete four- and three-role sets.
- Security rejects prompt/tool-execution patterns, secrets, PII, unexpected paths, and any implementation boundary. Rollback withdraws only the unapproved plan and leaves the selected capability dormant.
- The runner can produce at most `ready_for_review`; it does not create a real work package, modify execplan, accept a task, create a specialist branch/worktree, push, merge, or write production data.

## Difficulties and solutions

### Shared profile without cross-capability leakage

The common mechanics are implemented once, while selection, paths, card hashes, details, CTs, security profiles, and guardrails remain per-task data. Tests compare each definition to a separately frozen fixture so one candidate cannot silently inherit another candidate's branch, CT, or assertion.

### PowerShell fixture array construction

The first post-implementation test joined eight generated paths into one space-separated string because `directory + filename` expressions were placed directly inside one array expression. The fixture now maps filenames explicitly and appends status separately. Catalog contents were already correct.

### Transitive manifest binding

Review found that P12-002 records the Phase 12 manifest as an immutable P12-001 Git-object input. The initial downstream validator looked for a direct local path and would have blocked every real work package. The validator and static regression now require the actual transitive path.

### BOM-preserving four-segment Catalog CAS

The Catalog transform required old SHA-256 `86010c29e243b49d5cc333deab5114bb93c27602731a5bef8b47b24d0bf675ad`, preserved the UTF-8 BOM, parsed the complete result, and atomically replaced the file with an explicit verified backup. The backup and temporary script were removed. Normalizing the four intended task segments proves every non-target Catalog byte is unchanged.

## Affected regression

| Check | Result | Measured evidence |
|---|---:|---:|
| Initial shared registry/Catalog contract | failed as expected | exit `1`; four registrations absent |
| Generated-path fixture | failed as expected | one joined fixture string isolated; implementation paths already correct |
| Final TaskGate contract suite | passed | exit `0`; about 27 seconds |
| IntegrationSmoke contract suite | passed | exit `0`; tracked writes `0` |
| PhaseEntry contract suite | passed | exit `0`; implementation writes `0` |
| PhaseMerge contract suite | passed | exit `0`; remote writes `0` |
| Catalog isolation | passed | all non-P12A-D segments exact; each task outputs `10`, directories `1`, files `2`, inputs `11`, changes `1` |
| Missing accepted P12-002 dependency probes | fail-closed without write | each task missing inputs `8`, dependency failures `1`, production writes `0` |
| Real P12-089 CLI probe | rejected before materialization | exit `2`; probe/status/evidence absent before and after |
| Conditional runner inventory | passed | 24 total; 9 specialized; 15 fail-closed |
| `git diff --check` | passed | exit `0` |

Four complete synthetic work packages pass. For each candidate, mismatched XOR selection, `implementation_commit_count=1`, and a missing capability guardrail fail, for 12 malformed cases rejected in total. The synthetic P12C case is not a project Multi-Agent decision and contains no production value claim.

## STAR record

### Situation

Four mutually exclusive Phase 12 candidates had task cards but no executable planning gate, and two reviewer sets were weaker than the plan.

### Task

Make every possible selected path mechanically ready for a later, evidence-driven decision without choosing a winner, implementing a capability, or creating specialist topology.

### Action

Implemented one shared seven-mode framework with four frozen profiles, eight accepted-selection inputs, exact governance topology, zero-implementation planning semantics, future atomic/acceptance/merge IDs, task-specific CT/security guardrails, corrected reviewer policies, Catalog CAS, rollback, and positive/negative fixtures.

### Result

- Capability existence: dormant work-package gate coverage improved from `0/28` to `28/28` modes across four candidates; registry coverage improved from `5/24` to `9/24`, with `15/24` tasks still fail-closed.
- Behavioral improvement: four valid synthetic profiles pass and 12 malformed profiles fail; each missing-dependency probe reports exactly eight missing immutable inputs without writing.
- Governance result: no candidate ADR/task plan/status was created, no actual capability was selected, no plan or specialist branch was created, and no remote, acceptance, merge, or production action occurred.
- Guardrails: all four runner suites, exact Catalog isolation, transitive artifact binding, reviewer completeness, missing-input behavior, real next-task fail-closed behavior, and diff checking pass.

These results demonstrate runner-contract readiness only. They do not demonstrate calibrated trigger data, a selected Memory/cost-router/Multi-Agent/Domain-Command path, an approved work package, capability value, Release C readiness, or production behavior.

## Current hashes

- `Invoke-TaskGate.ps1`: `e27120fa39de96b6dc7484d8871575c00ef8a98f8144203db2b60c6cd4b72b01`
- `TaskGateCatalog.psd1`: `49b1b04f487bf0a0b04c0e264d81257a09d3e6bac80a5e713506e8cd7691349e`
- `Invoke-TaskGate.Tests.ps1`: `44e5011dc5730f126567988d96e62a2dd1296a9c7ea66cf151f78fa26f5d8845`

## Pending external boundary

P12A-D-000 remain `not_started`. Exactly one can execute only after formal P12-002 acceptance selects its matching capability and supplies the eight hash-bound inputs on the clean governance ref/worktree. Missing these inputs blocks only the selected planning task; other safe repair/enabler work remains eligible.
