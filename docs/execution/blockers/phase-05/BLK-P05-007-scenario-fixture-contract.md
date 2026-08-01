# BLK-P05-007 scenario fixture contract

The first real kill/replay scenario did not reach its process barrier, and the next repair reached the barrier but created an invalid lease timeline. This blocked the first contract test until both independent fixture assumptions were corrected. The safe next step was to keep all production constraints unchanged and repair only the test process import and lease timestamps.

- ID: `BLK-P05-007-scenario-fixture-contract`
- Phase / TASK: Phase 5 / `TASK-P05-007`
- status: `resolved`
- severity: `P2`; only the isolated local test fixture failed, with no production or external action, but two failures in the same mandatory verification step required a durable record.
- owner / reviewer: Reliability / Security+Data
- first_seen / last_updated / timezone: `2026-08-01T13:21+08:00` / `2026-08-01T13:34+08:00` / `Asia/Shanghai`

## Expected and actual result

- Expected: the scenario child reaches a barrier, is killed, rotates to a newer lease, and the affected boundary converges without duplicate side effects.
- Actual attempt 1: child exit `1` before the barrier with `ModuleNotFoundError: No module named 'tests.replay'`.
- Actual attempt 2: the barrier worked, but PostgreSQL rejected the synthetic expiry update with `ck_leases_expiry_after_acquire` because `expires_at` was earlier than `acquired_at`.
- Final result: all seven scenarios passed in one run with no skip or expected failure.

## Impact

- Security: no secret, personal data, cross-tenant access, arbitrary process target, or production action occurred.
- Data: only task-owned schemas in the isolated PostgreSQL database were created and dropped; database constraints rejected the invalid fixture before commit.
- User: no user traffic or user data was involved.
- Progress: the first P05-007 affected test failed twice before the full seven-scenario suite passed.
- Rollback: both repairs are uncommitted test-only changes and can be removed without schema or runtime rollback.

## Minimal reproduction and evidence

```powershell
.\agent-service\.venv\Scripts\python.exe -m pytest -q agent-service\tests\replay\test_kill_after_reserve.py::test_ct_005_kill_before_physical_call_executes_once_after_recovery --maxfail=1
```

- Redacted diagnostic record: `docs/execution/evidence/phase-05/P05-007/repair-diagnostics.json`.
- Diagnostic SHA-256 at closure: `46da5615b55630d05b4bedeefd6dd11ef1b8a95081f2fddfaaaafa9445ae169c`.
- Candidate kill/replay report: `docs/execution/evidence/phase-05/P05-007/kill-replay-report.json`, SHA-256 `cb8a5a084d4854ddcc06ce354f26da5838a9dc81025305dce56e84a91f3defe1` (post-commit binding may regenerate and rebind it).
- Successful full-CI summary: `D:\GO_NOW-phase-05-ci-p05-007\ci-summary.json`, SHA-256 `2c9cbd08104ea59fdee1e5a52ab1024a5d927eb5fa3a8a5ea900765b8c972d40`.
- Successful main-suite JUnit: `D:\GO_NOW-phase-05-ci-p05-007\unit.xml`, SHA-256 `7071c248507f84c03eb6618e0ea82a6181765cc925a24f084c45894603fff4a0`.
- Successful contract-suite JUnit: `D:\GO_NOW-phase-05-ci-p05-007\contract.xml`, SHA-256 `d3c1e97119980612e6645ed454a136a730edc5d5eedcd8c86fade024c009a964`.

## Known facts, uncertainty, and invariant

- Directly executing `test_kill_after_reserve.py` does not make `tests.replay` an importable package in the child process.
- `sys._base_executable` is sufficient to launch the dependency-enabled child after the file itself adds the service virtual-environment site-packages.
- The lease table requires `expires_at > acquired_at`; moving only `expires_at` into the past is invalid.
- Moving `acquired_at/heartbeat_at` back 120 seconds and `expires_at` back 60 seconds creates a valid expired lease.
- Remaining uncertainty: none for the two reproduced roots. Broader boundary semantics remain subject to the full task gates and CI.
- Affected invariant: test fixtures must preserve production lease ordering and the kill harness must identify a child process without relying on package-import side effects.

## Attempt timeline

1. Time: `2026-08-01T13:21+08:00`.
   - I thought this would fix it: importing the P05-006 harness would reuse its selected base interpreter.
   - Why first: reuse avoided duplicating process-selection logic.
   - Action: ran the first CT-005 scenario.
   - Exit/result: `1`; child failed before barrier because `tests.replay` was not importable.
   - New fact: direct file execution has a different import root from pytest collection.
   - Rollback: yes; the unnecessary package import was removed.
   - Upgrade trigger: stable non-path-spelling failure required `L0 → L1`.
2. Time: `2026-08-01T13:24+08:00`.
   - I thought this would fix it: deriving the same base interpreter directly would let the child reach the barrier.
   - Why first: it removed only the failing dependency and retained exact PID identity.
   - Action: changed interpreter derivation and reran the same test.
   - Exit/result: `1`; barrier passed, then PostgreSQL rejected the invalid expiry order.
   - New fact: the fixture must age acquisition and heartbeat as well as expiry.
   - Rollback: no committed change; the first repair was retained because it solved the child import root.
   - Upgrade trigger: the same verification step failed a second time, requiring a blocker and `L1 → L2`.
3. Time: `2026-08-01T13:27+08:00`.
   - I thought this would fix it: use the established lease timeline from P05-005 (`acquired/heartbeat=-120s`, `expiry=-60s`).
   - Why first: it preserves the database constraint and changes only fixture time.
   - Action: repaired the three timestamps, reran the affected test, then the four-file suite.
   - Exit/result: affected test `1 passed`; full task suite `7 passed`.
   - New fact: process and database fixture contracts now both hold across all declared boundaries.
   - Rollback: not needed; this is the selected test-only repair.
   - Upgrade trigger: none; the affected regression passed with new information.

## Final solution and alternatives

The child now selects the real base interpreter directly and asserts exact process identity. Lease expiry fixtures preserve `acquired_at < expires_at < database_now`. This adds no dependency, changes no runtime code or schema, and keeps rollback to deletion of four test files.

Rejected alternatives:

- Add `tests/__init__.py`: outside the task write set and changes test package semantics globally.
- Weaken or disable the lease check constraint: violates the production contract and is forbidden.
- Sleep until a 300-second lease expires: slow, adds no semantic coverage, and would make the suite operationally impractical.

## Verification and closure

- Fix commit/PR: local candidate `73822229f209d03cb0c13d5bf85030e4b3cdbe6d`; no push or PR is authorized.
- Verification: affected test exit `0`; complete P05-007 direct suite `7 passed in 13.29s`; skip `0`; expected-failure `0`.
- Full regression: main suite `425 passed`; contract suite `96 passed`; dependency audit passed; PostgreSQL PID remained `15744` and readiness passed after the full run.
- Final state / close time: `resolved` by local Engineering implementation at `2026-08-01T13:34+08:00`; independent Security+Data acceptance remains pending.
- Remaining risk: post-commit evidence binding and independent review remain. Owner Reliability; due before Phase 5 formal acceptance.
- Prevention: keep child stderr capture on barrier failure and preserve the lease timeline helper. Owner QA; due before Phase 5 formal acceptance.
