# STAR: deterministic Flutter integration entry

## Situation

The Phase 9 critical journey was authored under `integration_test/`. A direct local invocation in a
fresh Windows worktree discovered multiple available device targets and could not select an
authorized real device. That first attempt executed 0/10 journey cases. This was an environment
dispatch limitation, not evidence that the journey passed or failed.

## Task

Create a deterministic, reversible local verification path for the same test bytes without
claiming real-device coverage, then close the remaining accessibility failure and protect the
legacy route. Success was frozen as 10 visible tests, zero failure, zero skip, zero source-copy hash
mismatch, and zero target analyzer issue.

## Action

The runner copies the three test sources byte-for-byte into a task-scoped `.dart_tool` VM fixture,
proves each SHA-256 matches, and invokes the locked Flutter executable in machine-output mode. The
first discriminating VM result exposed one accessibility oracle that required exact equality even
though Flutter correctly merged descendant Semantics text. The assertion was narrowed to require
the stable public label by containment. The affected accessibility subset and then all three files
were rerun. Enable, Disable, Degrade, and First checks remain operational controls, not metric claims.

## Result

Baseline/candidate formula: `passed visible cases / required visible cases`. Baseline direct device
dispatch was `0/10` because no authorized device was selected; candidate exact-byte VM verification
was `10/10`, with `0` failures, `0` skips, `0` analyzer issues, and `0` source-copy hash mismatches.
The improvement is deterministic local verification coverage, not product quality or production
reliability. Guardrails remain: real-device status `pending_external`, legacy flag-off test passing,
contract change false, and production writes zero. Safety redlines cannot be averaged against this
result.

Evidence: `docs/execution/evidence/phase-09/P09-010/flutter-integration-report.json` and
`docs/execution/evidence/phase-09/P09-010/blocker.json`; repair commits
`cb3872e580b66b5109f96958d03b38a380adb454` and
`5ddcb34ce7068cb1091e3524243491072be3c089`.
