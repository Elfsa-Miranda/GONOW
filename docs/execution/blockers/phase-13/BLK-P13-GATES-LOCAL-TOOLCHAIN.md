# BLK-P13-GATES-LOCAL-TOOLCHAIN

Status: resolved locally on 2026-08-27

## Original reproduction

- PostgreSQL tests target isolated `127.0.0.1:55432` and fail setup with connection refused.
- The repository pgvector provisioning path cannot build the locked extension because Visual Studio `vswhere.exe` / build prerequisites are unavailable.
- Ad hoc `ruff` and `mypy` commands were unavailable; later inspection established that they are not repository CI gates. The official quality gate is `tests/ci/test_quality_gate.py`.
- The unrelated P12B price snapshot is stale.
- No approved live-provider paired run was available.

## Original observable results

- Unit run: 322 passed, 9 PostgreSQL setup errors.
- Non-stale contract run before PR4 additions: 226 passed, 22 deselected, 16 PostgreSQL setup errors.
- Targeted security: 11 passed, 93 deselected, 9 PostgreSQL setup errors.
- Frozen Context eval: all offline gates except full CI/live evidence pass; decision is `KEEP_DISABLED`.

## Resolution and verification

- Installed Visual Studio Build Tools 2022 with the VCTools workload.
- Reused the installed PostgreSQL 17.10 and pgvector 0.8.1 binaries, while provisioning a new isolated cluster at `127.0.0.1:55432`; no existing database was modified.
- Installed the locked Python 3.13.9 runtime and used the locked Dart 3.11.5 executable.
- Fixed one official Type-gate annotation failure in the Phase 13 stack.
- Made the P12B contract tests independent of wall-clock expiry while retaining an explicit stale-snapshot fail-closed test.
- Ran `agent-service/scripts/ci.ps1 -Stage All`: 966 tests passed in the main suite, 267 tests passed in the contract suite, and all lock, format, lint, type, secret, clock, SCA, license, and repository-clean gates passed.
- Re-ran targeted security: 20 passed and 93 deselected, with zero setup errors.

## Remaining external evidence

The toolchain/CI blocker is closed. Keep every production gate default-off until an approved live-provider paired run is available.

## Resolution criteria

Repository-wide test, lint, type, E0, security, integration, and frozen Phase 13 commands pass on a supported provisioned environment. This criterion is met. Live-provider evidence remains a separate release prerequisite. Any material contract change creates a new manifest identity and full rerun.

## Delivered resolution

The mechanism stack, replayable offline evidence, and full local CI evidence are delivered. Release allocation remains zero because live-provider evidence is absent.

## Truth audit

No failed test was relabeled as passed. No offline timing/token estimate is presented as provider or production performance. No lockfile or database infrastructure was changed to evade the gate.
