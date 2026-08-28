# Checkpoint persistence contract

## Boundary

This is an internal Worker/database contract, not a public HTTP endpoint. Phase 5 does not change
the Agent OpenAPI or Flutter/Dart contract. `GoNowPostgresCheckpointSaver` conforms to the locked
LangGraph v1 synchronous saver interface while retaining GoNow-owned schema, RLS, and fencing.

## Required write identity

Every write configuration contains `tenant_id`, `run_id`, `job_id`, `lease_holder_id`, positive
`fencing_token`, `audit_receipt_id`, `thread_id`, and checkpoint namespace. A checkpoint ID is a UUID
when present. Identity mismatch, missing tenant scope, an expired lease, or a stale fence fails before
payload persistence.

## Stored envelope

The current envelope is version 2 with exactly `version`, `checkpoint`, `metadata`, and
`new_versions`. Payloads are canonical UTF-8 JSON, at most 1 MiB, with a SHA-256 digest and a
content-addressed `state_ref`. Metadata binds tenant, Run, Job, current fence, state digest, schema
digest, and audit receipt. Pending writes bind checkpoint, task, path, write index, channel, and value
digest.

The saver rejects non-finite numbers, non-string map keys, arbitrary objects, client/connection
objects, credentials, authorization fields, raw bodies, prompts, reasoning, and secret-like values.
There is no pickle fallback or dynamic object reconstruction.

## Read and compatibility semantics

- Version 2 is read directly after reference and digest verification.
- Version 1 is upgraded only by the explicit deterministic fixture to version 2 with empty
  `new_versions`.
- Unknown, malformed, oversized, digest-mismatched, or reference-mismatched envelopes fail closed.
- Listing and lookup remain tenant scoped; another tenant receives no payload.
- Repeating an identical write is idempotent. Conflicting bytes for an existing identity fail with a
  checkpoint conflict instead of overwriting evidence.

## Recovery and failure mapping

`checkpoint.unsafe_state` means validation rejected the payload; remove the forbidden field at its
source. `checkpoint.unsupported_version` requires an approved compatibility change, not guessing.
`checkpoint.corrupt` means preserve the row and restore from verified evidence. `checkpoint.conflict`
means two payloads claimed one identity. `consistency.stale_fence` means the Worker has lost ownership
and must stop writing immediately.

On recovery, load the latest valid checkpoint only after lease/fence validation, then continue from
PostgreSQL. If no valid checkpoint exists, use the durable Run/Job state and configured fallback; do
not infer state from process memory or Redis.
