# STAR: deterministic native dependency warmup at phase entry

## Situation

The first Phase 8 entry run in a fresh worktree reached the inherited Phase 7 regression suite, but
the cold Windows/Python process did not finish importing the exact-locked native OR-Tools package
within the generic probe window. No Phase 8 functional diff existed, so the failure isolated an
environment-sensitive entry dependency rather than a research implementation defect.

## Task

Make a fresh phase entry deterministic while preserving the existing dependency version, solver
isolation contract, timeouts, and full regression scope.

## Action

The runner retained locked environment provisioning and added one explicit bounded import warmup
before launching full CI. The repair changed no solver runtime behavior or product threshold. It
was verified first with the cold import probe and then with the complete phase-entry suites.

## Result

The repaired entry completed 12 CI checks, 477 unit tests, 116 contract tests, and 14 Flutter tests
with zero failure. The runner contract also reported zero failure. The change is local, reversible,
and limited to test orchestration; production evidence remains pending.
