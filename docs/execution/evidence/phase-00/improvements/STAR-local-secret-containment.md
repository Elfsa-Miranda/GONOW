# Situation

The baseline client contained an extractable provider credential and provider-direct ordinary-chat path; the repository had no secret-scan workflow.

# Task

Contain the exposure locally without inventing vendor revocation evidence or restoring the key through rollback.

# Action

The candidate replaced provider constants with empty tombstones, routed ordinary chat through a default-disabled fixed gateway, added worktree/history/APK scans, and pinned a secret-scan workflow. Evidence stores only paths, rule IDs, counts, and redacted fingerprints.

# Result

The tracked-worktree valid finding count changed from one known baseline exposure to zero after containment; the post-containment APK known-fingerprint count is zero. Commands and artifact hashes are recorded under P00-003/P00-004. Vendor use, cost, and revocation remain unknown/pending and are not claimed as improvements.
