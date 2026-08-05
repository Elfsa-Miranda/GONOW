# Runtime database backup and restore

This runbook covers the PostgreSQL source-of-truth tables introduced in Phase 3. It is a local rehearsal contract, not permission to access production and not a claim about production recovery point or recovery time.

## Safety boundary

- Stop new Agent API and Worker writes before a real recovery. Preserve the last known database identity, migration revision, application release, and audit receipt.
- Restore into a new isolated database first. Never overwrite a production database merely because a local rehearsal passed.
- Use the exact PostgreSQL major-version tools recorded with the snapshot. Encrypt and access-control durable backup objects outside this repository.
- Treat `p03_007_runtime_rls` and later authorization migrations as forward-fix only. Do not disable FORCE RLS or broaden grants to make a restore pass.
- RPO and RTO remain `unknown` until owners approve production measurements. The local duration in P03-009 is evidence about one isolated fixture only.

## Rehearsed sequence

1. Confirm the target is the task-owned isolated database and that `pg_dump`, `pg_restore`, and `psql` are PostgreSQL 17 tools.
2. Acquire the migration advisory-lock identity and prove a second connection cannot acquire it. Stop if ownership is ambiguous.
3. Hash a metadata-only logical inventory of existing Runtime rows. Do not place business payloads, prompts, model responses, secrets, or PII in the report.
4. Create a custom-format snapshot with owner and grant replay disabled. Record its SHA-256, byte size, database identity, migration revision, and tool version in the protected backup inventory.
5. Upgrade the isolated copy, run Runtime smoke checks, and compare the logical inventory. If a forward-only migration rejects downgrade, keep the stronger constraints and prepare a forward fix.
6. Drop only the isolated rehearsal schemas, restore the snapshot, and re-apply migrations through the target revision.
7. Compare the restored logical hash and row count. A mismatch blocks recovery; never accept a partial restore.
8. Revalidate all ten Runtime RLS policies, FORCE RLS, PUBLIC grant count, role bypass flags, and a two-tenant positive/negative read matrix (CT-007).
9. Keep the restored database isolated until Data, SRE, and Security owners review the evidence. Production cutover, DNS changes, credentials, and destructive cleanup are separate approved actions.

## Local verification

From the repository root:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\agent-service\scripts\test_backup_restore.ps1
```

The command is hard-bound to `127.0.0.1:55432/gonow_p03_test` and writes only redacted evidence under `docs/execution/evidence/phase-03/P03-009/`. A successful report has zero empty-upgrade, existing-data-upgrade, restore-hash, and restore-verification failures; records `ct_007=passed`; and leaves `rpo_status` and `rto_status` as `unknown_not_claimed`.

## Failure and rollback

Stop new Workers, retain the snapshot and failed target, and prefer a reviewed forward fix. Do not reset migration history, delete the only backup, relax RLS/grants, or retry the same restore without a new diagnostic signal. Resume only from a fresh isolated target after recording root cause, impact, repair, and the affected regression set.
