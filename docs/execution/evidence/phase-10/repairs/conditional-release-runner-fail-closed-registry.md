# Conditional Release C runner fail-closed registry

- Classification: `phase-10/repairs`
- Baseline commit: `db527336915334aaec2a83469aa833bbc30678fe`
- Scope: Phase 11, Phase 12A-D/governance, and final Release C dispatch safety
- Execution mode: `local_provisional`
- Recorded: `2026-08-02` (`Asia/Shanghai`)

## Reproduction

An inventory of the sealed execplan and TaskGate Catalog found 24 conditional Release C task cards:

- 15 Phase 11 tasks (`P11-000` through `P11-999`)
- 7 Phase 12 governance/work-package tasks (`P12-000`, `P12-001`, `P12-002`, `P12A-D-000`, `P12-089`)
- 2 Release C tasks (`REL-C-000`, `REL-C-001`)

Only `TASK-REL-C-000` had a dedicated TaskGate implementation. The other 23 tasks were eligible to enter generic handlers.

The first contract run failed as expected in `7,717.92 ms` with:

```text
negative: conditional Release C tasks must fail closed before a specialized runner is registered
```

## Root cause and impact

Catalog registration proves that a task and mode are known; it does not prove that the task's primary assertion, security rules, evidence schema, or rollback contract have a specialized executable implementation. The dispatcher previously treated those two states as equivalent.

The impact was systemic: any future Phase 11/12/Release C task without a dedicated implementation could reach generic behavior and create task evidence or status before the missing specialization was detected. This could not safely be repaired by adding 23 placeholder handlers, because placeholders would preserve the same false-confidence problem.

## Reversible repair

- Added a pure conditional-task runner registry covering the `TASK-P11-*`, `TASK-P12*`, and `TASK-REL-C-*` namespaces.
- Registered only the seven implemented REL-C-000 modes.
- Added a dispatcher guard after Catalog task/mode validation but before repository resolution and evidence/status directory materialization.
- Unregistered task/mode pairs now return exit `2` with either `conditional_task_runner_unimplemented` or `conditional_task_mode_unimplemented`.
- Non-conditional tasks remain outside the guard.
- Added a mechanical inventory assertion: conditional task count `24`, registered task count `1`, unimplemented task count `23`.

No future capability is claimed by this registry. Each task must be added only when its specialized runner and affected regression are implemented.

## Verification

| Check | Result |
|---|---:|
| Final TaskGate contract suite | passed, `7,119.11 ms` |
| Actual `TASK-P11-000 / Preflight` probe | exit `2` |
| Actual reason code | `conditional_task_runner_unimplemented:TASK-P11-000:Preflight` |
| P11-000 evidence directory before/after | absent / absent |
| P11-000 status file before/after | absent / absent |
| Conditional task inventory | `24` |
| Specialized tasks | `1` (`TASK-REL-C-000`) |
| Fail-closed unimplemented tasks | `23` |
| PhaseMerge contract suite | passed, `1,080.85 ms` |
| PhaseEntryRegression contract suite | passed, `651.34 ms` |
| IntegrationSmoke contract suite | passed, `843.83 ms` |
| `git diff --check` | passed |

## STAR record

### Situation

The future conditional DAG was fully inventoried in the Catalog, but executable coverage and inventory coverage were not separated.

### Task

Prevent every unimplemented future task from creating misleading local evidence while keeping implemented and non-conditional tasks runnable.

### Action

Introduced one fail-closed registration boundary, placed it before all evidence writes, and tested the complete 24-task namespace plus a real subprocess probe.

### Result

- Behavioral safety: 23 unimplemented tasks now deterministically reject before evidence/status materialization.
- Compatibility guardrail: REL-C-000 remains registered for exactly seven modes; a representative non-conditional task remains unaffected; all adjacent runner suites pass.
- Governance honesty: the change reports missing implementation rather than turning inventory into an implementation claim.

This is a dispatcher-safety improvement, not Phase 11/12 feature delivery or a Release C path decision.

## Current hashes

- `Invoke-TaskGate.ps1`: `ee1b04430b6b21c19e568e5f2aa1b95a80790eb1af494d8deb7bed1ab7b14ec6`
- `Invoke-TaskGate.Tests.ps1`: `6ff628b9380eae45104ad1c69da031165bf6a13be7cae3ea21699af167637756`
