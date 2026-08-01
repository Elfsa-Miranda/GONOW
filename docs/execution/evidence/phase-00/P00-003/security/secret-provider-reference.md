# TASK-P00-003 Secret Provider Reference

Status: `pending_owner_and_vendor_receipts`

No credential value, reversible encoding, provider token, endpoint secret, or PII is stored in this document.

The approved replacement reference must be:

- created by the Security/vendor owner, not by the implementation Agent;
- server-only and unavailable to Flutter builds, client logs, CI artifacts, and browser/mobile traffic;
- least privilege, explicitly spend-capped, and stored in the approved SecretProvider;
- identified in evidence only by an immutable receipt SHA-256 and a non-secret reference ID;
- verified through controlled old-ref negative and new-ref positive probes whose outputs contain status codes only.

Required evidence remains missing: vendor authorization, old-ref revocation receipt, usage/billing audit receipt, server-only replacement receipt, spend-cap receipt, SecretProvider receipt, and activation timestamps.

Rollback must never restore the exposed credential.
