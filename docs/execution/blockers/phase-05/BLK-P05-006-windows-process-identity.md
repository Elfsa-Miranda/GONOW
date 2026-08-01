# BLK-P05-006 Windows process identity

The local failure-injection harness initially could not prove that it killed the intended process. A subsequent raw process-ID repair could terminate an unrelated local process after Windows reused that ID, which stopped the isolated test PostgreSQL instance and blocked the full CI run. The safe resolution is to launch the disposable probe with the real base interpreter and operate only through the process handle returned by that launch.

- ID: `BLK-P05-006-windows-process-identity`
- Phase / TASK: Phase 5 / `TASK-P05-006`
- status: `resolved`
- severity: `P2`; the defect affected only disposable local test processes, but it could terminate an unrelated local process and therefore could not be left in the harness.
- owner / reviewer: QA / SRE+Security
- first_seen / last_updated / timezone: `2026-08-01T12:58+08:00` / `2026-08-01T13:11+08:00` / `Asia/Shanghai`

## Expected and actual result

- Expected: each approved injection point reports the same PID as the spawned probe, kills only that probe, restarts it, leaves no orphan process, and does not affect PostgreSQL.
- Actual: the first probe reported a PID different from the virtual-environment launcher. The first raw-PID repair then propagated a Windows control signal to the test host. A later reopen-by-PID repair passed the focused harness but the full CI found `127.0.0.1:55432` refusing connections; the PostgreSQL log records a fast shutdown at `2026-08-01T13:01:17+08:00`.

## Impact

- Security: no secret, personal data, cross-tenant access, production action, or external write occurred. The unsafe target-selection mechanism was confined to local test processes and was removed before commit.
- Data: PostgreSQL recorded a clean fast shutdown and restart; no data-loss evidence was observed. The isolated server was restored on the same data directory and `pg_isready` passed.
- User: no user or production traffic was involved.
- Progress: one focused test, one test-host run, and one full CI run failed. Work stopped at the affected action until process identity was repaired.
- Rollback: all harness changes were uncommitted. The isolated database was restarted with its existing data directory; no schema or data rollback was required.

## Minimal reproduction

From `D:\GO_NOW-phase-05-worktree` before the final repair:

```powershell
.\agent-service\.venv\Scripts\python.exe -m pytest -q agent-service\tests\replay\harness --maxfail=1
```

The first implementation failed with `worker barrier identity is invalid`. A diagnostic launch showed the launcher handle PID and the probe's `os.getpid()` were different. Reopening and acting on the recorded PID after process exit created a reuse race; the next full CI invocation failed with `ConnectionRefusedError` on port `55432`.

## Redacted evidence and hashes

- Failed full-CI JUnit: `D:\GO_NOW-phase-05-ci-p05-006\unit.xml`, SHA-256 `b76e427ee1c0c9b660e888ca949db3cb5a4fa6d1ec81b0937ba40d4c4e021627`.
- Failed full-CI summary: `D:\GO_NOW-phase-05-ci-p05-006\ci-summary.json`, SHA-256 `2a80dc94e91dbf048a65878f47929254c02a45aa7b67646c9a4269558bdba139`.
- Repaired matrix report: `docs/execution/evidence/phase-05/P05-006/failure-injection-report.json`, SHA-256 at closure `ccf31cbcd5a96025351338eade6230e6af28f6580b7da01b5dd6d17683638a94` (later gate runs may replace this generated report and bind its final hash).
- Database shutdown/restart evidence: `D:\GO_NOW-toolchain\postgres-17.10-isolated\postgres.log`; only the timestamp and lifecycle conclusion are referenced because the log is an external test artifact.

## Known facts and remaining uncertainty

- The virtual-environment `sys.executable` was `D:\GO_NOW-phase-05-worktree\agent-service\.venv\Scripts\python.exe`, while `sys._base_executable` was `D:\Anaconda\python.exe`.
- A diagnostic run observed different launcher and probe PIDs.
- Windows raw PID liveness checks and reopen-by-PID cleanup were removed.
- The repaired harness requires the base interpreter to preserve `Popen.pid == os.getpid()` and fails closed if it does not.
- After the repair, the focused suite passed `4/4`; the matrix passed all seven points; PostgreSQL PID stayed `15744` before and after and `pg_isready` returned success.
- Remaining uncertainty: other Python distributions may expose a different base interpreter path. The explicit identity assertion converts that case into a bounded test failure without targeting another process.

## Affected invariant

The failure-injection framework must kill only its own disposable test process, must not expose an arbitrary PID kill interface, and must leave `orphan_process_count=0` and `dirty_fixture_count=0`. The raw-PID approach violated the target-identity part of this invariant even though it was local-only.

## Attempt timeline

1. Time: `2026-08-01T12:58+08:00`.
   - I thought this would fix it: using the PID returned by `subprocess.Popen` would identify the probe.
   - Why first: it is the standard handle-backed, lowest-complexity process API.
   - Action: ran the focused pytest suite.
   - Exit/result: exit `1`; `worker barrier identity is invalid`.
   - New fact: this Windows virtual-environment launcher did not preserve the probe PID.
   - Rollback: not required; the failed run removed its fixture and stopped its process handle.
   - Upgrade trigger: stable reproduction was not a spelling/path error, so `L0 → L1`.
2. Time: `2026-08-01T13:00+08:00`.
   - I thought this would fix it: checking and terminating the PID recorded by the probe would follow the real worker.
   - Why first: it directly tested the newly observed identity mismatch.
   - Action: added a raw-PID liveness check and reran the focused suite.
   - Exit/result: host exit `0xc000013a`.
   - New fact: `os.kill(pid, 0)` is not a safe read-only Windows liveness probe in a shared console.
   - Rollback: yes; that implementation was immediately replaced and never committed.
   - Upgrade trigger: the same step failed a second time, so the issue was formally escalated and the original raw-PID plan was abandoned (`L1 → L2`).
3. Time: `2026-08-01T13:01+08:00`.
   - I thought this would fix it: Win32 handle calls opened on the recorded PID would avoid console-signal propagation.
   - Why first: it changed only the Windows liveness/termination primitive and produced a distinct signal.
   - Action: used `OpenProcess`, `WaitForSingleObject`, and `TerminateProcess`; focused tests passed.
   - Exit/result: focused tests exit `0`, but the later full CI exited `1` with port `55432` refusing connections; the PostgreSQL log tied shutdown to this interval.
   - New fact: reopening a raw PID after the child exits permits PID reuse and can target an unrelated process.
   - Rollback: yes; all reopen-by-PID code was removed before commit, and the isolated database was restarted.
   - Upgrade trigger: a mandatory gate failed and the scheme needed replacement (`L2 → L3` comparison).
4. Time: `2026-08-01T13:09+08:00`.
   - I thought this would fix it: launch the probe with `sys._base_executable`, require exact handle/probe identity, and use only the retained `Popen` handle.
   - Why first: it eliminates the identity ambiguity instead of adding another PID lookup.
   - Action: removed raw PID operations, added exact identity failure, restored PostgreSQL, and ran the focused suite plus all seven injection points while comparing the PostgreSQL PID before/after.
   - Exit/result: exit `0`; focused tests `4 passed`; seven structured points passed; PostgreSQL PID `15744 → 15744`; readiness passed.
   - New fact: the base interpreter preserves one process identity in this environment and provides a handle-safe kill boundary.
   - Rollback: not needed; this is the selected reversible test-only implementation.
   - Upgrade trigger: none; the root cause and affected regression were closed.

## Final solution and alternatives

The selected solution uses the real base interpreter for disposable probes, requires the probe-reported PID to equal the retained `Popen` PID, kills and waits only through that handle, and rejects any mismatch. It changes no runtime or production boundary, writes no database data, adds no dependency, works on existing Python platforms, and rolls back by removing the test harness.

Rejected alternatives:

- Reopen by raw PID: unsafe because process IDs can be reused after exit.
- Use `taskkill`, `Stop-Process`, or a caller-supplied PID: expands the kill surface and violates the test-only boundary.
- Add a native job-object dependency: safer than raw PID but unnecessary cost and portability surface when exact base-interpreter identity is available.
- Do nothing: leaves the harness unable to prove target identity and could interrupt unrelated local work.

## Verification and closure

- Fix commit/PR: pending local candidate commit; no push or PR is authorized.
- Affected regression: focused harness `4 passed`, matrix point count `7`, `kill_confirmed=true`, `orphan_process_count=0`, `dirty_fixture_count=0`, PostgreSQL readiness exit `0`, unchanged PostgreSQL PID.
- Full regression: pending rerun after this blocker record is committed; its final report/hash will be referenced by Phase 5 acceptance evidence.
- Final state / close time: `resolved` by local Engineering implementation at `2026-08-01T13:11+08:00`; independent SRE+Security acceptance remains pending.
- Remaining risk: alternate Python distributions may fail the explicit identity assertion. Owner QA; due before Phase 5 formal acceptance; prevention is to keep the assertion and never add raw PID fallback.
- Documentation follow-up: Phase 5 acceptance and retrospective must list this blocker and its final status. Owner Reliability; due at `TASK-P05-990`.
