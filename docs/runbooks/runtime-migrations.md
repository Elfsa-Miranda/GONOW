# Runtime migration runbook

This runbook applies to the local Phase 3 migration chain from `p03_001_runtime_baseline` through `p03_007_runtime_rls`. It is not authorization to connect to production.

## Before applying a migration

1. Identify the exact database, current revision, application candidate OID and tool versions. Refuse unknown or production identities without owner authorization.
2. Stop new API/Worker writes for a restore or risky forward fix. Acquire the approved PostgreSQL advisory-lock identity and prove a second connection cannot acquire it.
3. Create and hash a protected snapshot. Capture a metadata-only logical inventory and existing-data fixture; never put prompt, response, secret, PII or business payload bodies in evidence.
4. Provision the fixed least-privilege roles before `p03_007_runtime_rls`. Verify none has superuser or `BYPASSRLS`.

## Apply and verify

From the repository root, set `GONOW_DATABASE_URL` and `GONOW_ALEMBIC_VERSION_SCHEMA` only for an approved isolated target, then run Alembic with the repository environment. Verify:

- the revision equals the intended head;
- existing logical row hash/count is unchanged;
- state, sequence, idempotency, CAS and fencing constraints reject stale/illegal writes;
- ten Runtime policies are present and FORCE RLS is true for all ten tables;
- PUBLIC grants and bypass-capable application roles are zero;
- two tenant contexts see only their own rows;
- outbox delivery receipt uniqueness and metadata-only DLQ remain intact.

The local comprehensive command is:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\agent-service\scripts\ci.ps1 -Stage All
```

## Downgrade and forward fix

Early additive revisions have isolated downgrade tests, but `p03_007_runtime_rls` is deliberately forward-fix only. Its downgrade raises and keeps RLS/grants intact. Do not weaken authorization merely to restore an older application. Preserve the old Behavior releases and Runtime data, deploy a reviewed compatible reader or forward migration, and record the affected regression.

## Failure response

Stop only the affected writer path unless there is active secret/PII exposure, cross-tenant access, production data loss or an irreversible action. Capture the first failure, minimal reproduction, inputs/environment and recent diff. Repair the root cause once, run the smallest affected check, then the affected regression set. Do not repeat a restore or migration without a new distinguishing signal.

## First look

Inspect, in order: database identity; Alembic revision; migration lock holder; PostgreSQL server/client major versions; tenant context; RLS/policy/grant catalog; state/version/fence values; snapshot and logical hashes; and the exact gate report. RPO and RTO are unknown until measured and approved in the production environment.
