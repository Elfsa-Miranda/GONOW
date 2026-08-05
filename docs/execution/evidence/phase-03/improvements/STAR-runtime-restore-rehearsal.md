# STAR: Runtime restore rehearsal

## Situation

The Phase 3 baseline had no machine-replayable proof that existing Runtime data survived an authorization migration and a logical restore. A successful empty migration alone could not distinguish schema creation from recoverability.

## Task

Create one reversible local journey that binds a protected snapshot to existing-data upgrade, forward-fix behavior, restore integrity, migration locking and CT-007 without touching production or claiming RPO/RTO.

## Action

`agent-service/scripts/test_backup_restore.ps1` validates the exact task-owned database, locked Python version and PostgreSQL 17 tool set. `agent-service/tests/integration/test_migration_restore.py` seeds two tenants, hashes eight logical records, creates a custom-format snapshot, upgrades through FORCE RLS, proves the downgrade is rejected, restores fresh schemas, reapplies migrations and reruns the tenant/grant matrix.

Reproduction command:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\agent-service\scripts\test_backup_restore.ps1
```

## Result

- Before: no repository restore command or existing-data restore hash evidence at Phase 3 base `aff2517da3143d539b0d639f9fa3bde6ec192181`.
- After: empty/existing upgrade failures `0`, restore mismatch `0`, CT-007 `passed`, one blocked competing lock holder and one forward-fix rejection at dependency checkpoint `21dd57498410227fe8588c94a4a5514efbc2cb87`.
- Wrapper SHA-256: `de9bf5cedc1985fac49f5a1d451f0b8efee2898fc10ca646a1bbc66e6382daec`.
- Integration test SHA-256: `fcc47de8f7e00f08f2df8295e1db41ea33a86a6a4a6f6c7a4534f2b28fb08631`.
- Bound report SHA-256: `dc5b78f123e628284c3fa05cc7e5c2ce118e3d6e1914cf31b328e09573ec5f8e`.
