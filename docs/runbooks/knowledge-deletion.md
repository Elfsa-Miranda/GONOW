# Knowledge deletion and restore runbook

Deletion is fail-closed and tombstone-led. The six surfaces are source, chunk, vector, cache, evaluation corpus, and backup/restore replay.

## Enable

Enable ingestion or RAG reads only when every source class has a deletion rule, durable tombstone, completion receipt, and finite fanout SLA. New reads deny immediately once the tombstone is durable.

## Disable

Disable the source and set RAG allocation to zero if any surface receipt is missing. Preserve the tombstone; do not turn a partial fanout into an apparent success.

## Degrade

When a surface is unavailable, keep the source unreadable and retry bounded propagation from the durable request. Cache and index loss may rebuild only from non-tombstoned current versions.

## Restore

Replay tombstones before source, version, chunk, vector, cache, or evaluation restoration. Database triggers reject source reactivation and version restoration for a tombstoned source. A backup can be technically restored while the deleted content remains logically and physically suppressed.

## First checks

Check request ID and tenant, tombstone digest, per-surface receipt count, retry lease/fencing token, source status, current version pointer, restored-row count, and `restore_verification_failures`. `contract_change: internal knowledge schema only`; Candidate deletion behavior remains deny-first.
