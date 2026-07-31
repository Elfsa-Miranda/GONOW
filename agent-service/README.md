# GoNow Agent Service

This directory is the server-side runtime boundary introduced in Phase 2. It
contains one codebase with two independently controlled process entrypoints:

- `python -m app.api.main` starts the FastAPI process.
- `python -m app.worker.main` starts the Worker process.
- Add `--check` to either command to execute startup and shutdown without
  opening a network listener or waiting for a job.

Phase 2 does not contain model calls, graph execution, tools, domain writes, or
Flutter traffic. Later phases add those capabilities behind their own gates.

## Runtime boundaries

The API owns HTTP authentication, tenant context, stable public errors, probes,
and the versioned contract descriptor. The Worker has a separate lifecycle but
cannot claim or execute jobs. Configuration stores only logical secret
references; secret values are resolved at startup and are never retained in the
typed settings model. PostgreSQL, durable jobs, model routing, tools, and domain
writes arrive only in their designated later phases.

Readiness fails closed when JWKS or database readiness is missing or absolute
clock offset exceeds five seconds. An offset over one second emits a warning.
Unsafe clock state rejects new Runs and high-risk writes while preserving drain
and cancel. Probe payloads contain stable reason codes, not dependency URLs or
credentials.

## Locked local build

The repository lock fixes Python to 3.13.9 and uv to 0.10.9. From the repository
root, run:

```powershell
& .\agent-service\scripts\build.ps1
```

The build creates `agent-service/.venv` from `uv.lock`, compiles both process
modules, runs the entrypoint tests, and writes the CycloneDX SBOM required by
`TASK-P02-001`. Any startup exception crosses the process boundary as a nonzero
exit instead of being converted into a successful health signal.

Run every mandatory local CI gate with:

```powershell
& .\agent-service\scripts\ci.ps1
```

The wrapper enforces the lock, format/lint/type rules, all tests, contract
tests, tracked-source secret scanning, `uv audit`, direct-license checks, and
the deployment ClockSafety contract. It has no deploy action and no mandatory
skip switch. To disable the service, do not start either entrypoint; no Flutter
route currently depends on it. For degraded operation and graceful shutdown,
follow `docs/runbooks/agent-service-lifecycle.md`.
