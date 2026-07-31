# GoNow Agent Service

This directory is the server-side runtime boundary introduced in Phase 2. It
contains one codebase with two independently controlled process entrypoints:

- `python -m app.api.main` starts the FastAPI process.
- `python -m app.worker.main` starts the Worker process.
- Add `--check` to either command to execute startup and shutdown without
  opening a network listener or waiting for a job.

Phase 2 does not contain model calls, graph execution, tools, domain writes, or
Flutter traffic. Later phases add those capabilities behind their own gates.

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
