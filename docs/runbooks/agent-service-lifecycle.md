# Agent service lifecycle runbook

## Scope

This runbook covers the Phase 2 API/Worker skeleton only. It does not authorize
model execution, job claims, database writes, deployment, or production traffic.

## Build and check

From the repository root:

```powershell
& .\agent-service\scripts\build.ps1
& .\agent-service\.venv\Scripts\python.exe -m app.api.main --check
& .\agent-service\.venv\Scripts\python.exe -m app.worker.main --check
& .\agent-service\scripts\ci.ps1
```

All commands must exit zero. `--check` opens no listener and claims no job. The
CI wrapper must report zero mandatory skips, xfails, lock drift, high/critical
vulnerabilities, unknown direct licenses, and secret findings.

## Start and stop

For an isolated local API check, run `python -m app.api.main --check`. A real
listener is not required by the Phase 2 acceptance path. The Worker check is
`python -m app.worker.main --check`. Stop either process with its normal process
signal; shutdown changes admission to draining and waits only for the configured
bounded grace interval.

During drain, reject new Runs and high-risk writes. Preserve drain and cancel.
Do not convert a shutdown timeout into a successful graceful result.

## Readiness and clock safety

Readiness is false when JWKS or database readiness is missing. Clock boundaries
are exact: 1.0 seconds has no warning; 1.01 seconds warns; 5.0 seconds remains
ready with warning; 5.01 seconds is not ready and rejects new Runs/high-risk
writes while allowing drain/cancel.

A deployment must call the CI wrapper's `DeploymentClockSafety` stage and retain
source, stratum, last-sync, offset, and command exit. A missing command, missing
measurement, or absolute offset above five seconds fails closed. The current
workstation's Windows Time service is not running, so formal measured clock
evidence is pending; synthetic boundary tests are not a production substitute.

## Degraded paths and rollback

- JWKS unavailable: readiness false; do not accept authentication.
- Database unavailable: readiness false; do not accept new work.
- Telemetry exporter unavailable: business behavior remains open, buffering is bounded.
- Redaction or high-risk audit unavailable: stop the affected export/action.
- Contract digest mismatch or unknown major: return the stable unsupported/availability code.
- Rollback first action: stop both processes. No Flutter route depends on them in Phase 2.

## First checks

1. Confirm the failing stable reason code without logging request or exception bodies.
2. Run the narrow affected test, then the full `ci.ps1` wrapper.
3. Confirm `uv.lock` has no drift and OpenAPI SHA matches the SchemaRegistry constant.
4. For clock failures, obtain a real synchronized source; never replace missing offset with zero.
5. Escalate production exposure, cross-tenant access, data loss, or irreversible action as P0.
