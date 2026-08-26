# BLK-P13-GATES-LOCAL-TOOLCHAIN

Status: open external environment blocker

## Reproduction

- PostgreSQL tests target isolated `127.0.0.1:55432` and fail setup with connection refused.
- The repository pgvector provisioning path cannot build the locked extension because Visual Studio `vswhere.exe` / build prerequisites are unavailable.
- `uv run --frozen ruff ...` and `uv run --frozen mypy ...` fail because neither executable is present in the locked project.
- The unrelated P12B price snapshot is stale.
- No approved live-provider paired run was available.

## Observable results

- Unit run: 322 passed, 9 PostgreSQL setup errors.
- Non-stale contract run before PR4 additions: 226 passed, 22 deselected, 16 PostgreSQL setup errors.
- Targeted security: 11 passed, 93 deselected, 9 PostgreSQL setup errors.
- Frozen Context eval: all offline gates except full CI/live evidence pass; decision is `KEEP_DISABLED`.

## Attempts and outcomes

- Re-ran focused non-database partitions, compileall, E0, Context integration, security selection, and the frozen paired evaluator.
- Inspected the locked project rather than mutating `pyproject.toml` or `uv.lock` to add ad hoc tools.
- Preserved all failed commands and JUnit output in P13-003/P13-004 evidence.

## Safe workaround

Keep every production gate default-off. Run the same commits in the repository's provisioned CI image with PostgreSQL/pgvector, locked lint/type tooling, and an approved live-provider fixture binding.

## Resolution criteria

Repository-wide test, lint, type, E0, security, integration, and frozen Phase 13 commands pass on a supported provisioned environment; the exact frozen paired report includes required live evidence. Any material contract change creates a new manifest identity and full rerun.

## Delivered resolution

The mechanism stack and replayable offline evidence are delivered. Release allocation remains zero and PR Ready state is withheld.

## Truth audit

No failed test was relabeled as passed. No offline timing/token estimate is presented as provider or production performance. No lockfile or database infrastructure was changed to evade the gate.
