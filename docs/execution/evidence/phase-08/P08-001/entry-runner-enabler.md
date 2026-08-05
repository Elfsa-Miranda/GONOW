# Phase 8 entry runner enabler

## Reproduction

The first `TASK-P08-001 / Preflight` run in the new Phase 8 worktree executed 200 unit tests. The isolated solver liveness case returned `solver.hard_timeout`; the remaining executed unit tests, all 14 Flutter entry journeys, and the task-gate runner contract passed.

## Root cause and impact

The full CI invocation created the locked virtual environment and then immediately launched the isolated solver subprocess. Its fixed 15-second execution deadline therefore included the first native OR-Tools import in a fresh worktree. This is an entry-environment cold-start defect, not a solver contract change. The impact is limited to fresh Phase worktree entry runs using the isolated solver test.

## Reversible repair

The Phase 8 entry runner now executes the existing locked `Format` stage to provision dependencies, then imports `ortools.sat.python.cp_model` explicitly, and only then starts full CI. Provisioning and warmup have independent mandatory exit codes in `phase-entry-regression.json`. The solver deadline was not enlarged.

Rollback is a single local commit revert. The repair changes no production state, public API, database schema, secret boundary, or remote branch.

## Affected regression

The repaired run passed 12 agent-service gates, 477 unit tests, 116 contract tests, 14 Flutter tests, and the runner contract, with zero failure, skip, xfail, or not-run result. Phase 7 remains `ready_for_review`; Phase 7 formal acceptance remains pending.
