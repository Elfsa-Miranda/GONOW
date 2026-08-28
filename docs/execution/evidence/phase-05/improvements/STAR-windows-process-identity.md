# STAR: safe Windows process identity for failure injection

## Situation

The first Phase 5 failure-injection harness launched a virtual-environment Python shim. On Windows,
the launcher PID could differ from the durable child PID. A raw numeric liveness/kill check therefore
did not prove ownership; after exit, PID reuse could select an unrelated local process. During the
minimal reproduction this temporarily stopped the isolated test PostgreSQL instance. It was restored
without data loss, and the blocker preserves the complete diagnosis.

## Task

Make all seven planned Worker termination points reproducible while proving that the harness can
terminate only the disposable child it created, leaves no process or fixture orphan, and cannot rely
on a recycled PID.

## Action

The harness now launches `sys._base_executable`, retains the returned process handle, requires the
spawn PID to equal the child-reported PID, and performs terminate/wait through that handle. It rejects
identity mismatch before any kill. Unit coverage reproduces launcher mismatch and validates exact
identity, cleanup, and restart. The integration matrix then kills and restarts a disposable process at
each approved boundary.

Reproduction and affected regression commands, from the repository root in the isolated toolchain:

```powershell
.\agent-service\.venv\Scripts\python.exe -m pytest -q .\agent-service\tests\replay\harness\test_process_harness.py
powershell -NoProfile -ExecutionPolicy Bypass -File .\agent-service\scripts\run_failure_injection.ps1
```

## Result

Before repair, stable launcher/child identity was not proven and one recycled-PID incident occurred
in the isolated environment. After repair, 7/7 approved injection points reached their barrier,
confirmed the intended kill and restart, and produced `orphan_process_count=0`,
`dirty_fixture_count=0`, and `pii_canary_leak_count=0`. The subsequent complete CI and PostgreSQL
recovery suite passed with the isolated database process identity unchanged.

Evidence SHA-256:

- `agent-service/tests/replay/harness/process_harness.py`: `4f7fec5465dcb98e0db66938b3282bb6b44c62f5598bf63dd623ed1da79199f9`
- `agent-service/tests/replay/harness/test_process_harness.py`: `9fd4cb291ebc6df4d4e8edafee9f82250fea6c60a9a6f1e6343bf1de4d4eedc3`
- `docs/execution/evidence/phase-05/P05-006/failure-injection-report.json`: `ab6764b21abdbb6f7fb9fc08fb55e7e723c26b4398d5cd46ff8b117255657287`
- `docs/execution/blockers/phase-05/BLK-P05-006-windows-process-identity.md`: `aa2d10fe7fd3f0bf623ac18e093ffb4973c177fc5ae4e99cbd409dd83885cfc4`

This is a local safety/reproducibility improvement, not a production availability or performance
claim.
