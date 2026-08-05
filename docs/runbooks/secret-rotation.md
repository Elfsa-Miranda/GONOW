# Model-provider secret rotation runbook

The historical client credential is treated as compromised because it was committed and shipped in an extractable client path. This repository contains only redacted fingerprints and rule IDs; never paste the value into an issue, log, command line, evidence file, or replacement configuration.

## Owner actions

1. A provider-account owner revokes every matching credential generation and records the immutable vendor receipt, actor, time, and redacted fingerprint.
2. Billing/security owners review provider use and spend for the full possible exposure interval; record findings without prompt/response/user content.
3. Security confirms no replacement credential exists in Git history, worktree, build artifact, workflow log, or client runtime configuration.
4. The server owner provisions the replacement only through the approved Secret Provider and binds auth, rate limits, spend caps, and audit receipts.
5. Re-run worktree/history/APK scans and attach hashes to the exact candidate head.

## Incident behavior

If a valid client credential is found, keep model features disabled, stop the affected release action, revoke first, and repeat the scans. Do not restore the old direct route as rollback. Production revocation and billing review are still pending external actions in the current local candidate.
