# Runtime Event persistence contract

Phase 3 defines a database Event record and replay repository. It does not yet expose the Phase 6 SSE transport and must not be presented as a public streaming API.

## Stored envelope

The canonical machine schema is `contracts/events/runtime-event.schema.json`. Every Event has a UUID `event_id`, UUID `run_id`, server-derived `tenant_id`, positive per-Run `seq`, constrained `event_type`, JSON object `payload`, non-empty `audit_receipt_id` and database timestamp `created_at`.

`tenant_id`, `seq`, `audit_receipt_id` and `created_at` are server/database fields. Callers may not override tenant identity or reserve sequence numbers. The payload must already satisfy the event-type-specific contract; this generic envelope does not permit a model response to become business truth.

## Append and replay

- Append occurs in a caller-owned transaction and locks the Run row.
- A terminal or missing Run fails closed. A failed append rolls back both the Event and sequence reservation.
- `(run_id, seq)` is unique and replay orders by `seq`.
- `replay_after(last_event_id, limit)` treats `last_event_id` as the last observed sequence for this repository; valid limits are 1–1000.
- RLS applies to Event and Run reads/writes. Missing tenant context returns no Event rows.

The Phase 6 SSE contract will map transport `Last-Event-ID` and disconnect recovery explicitly. Until then, no client should depend on this repository method as a network protocol.

## Outbox relationship

An outbox message references an existing Event and shares its tenant. Delivery receipts make a consumer effect unique. A dead letter stores reason/retry/audit metadata only; the Event remains the durable payload source. There is no external consumer or production dispatcher in Phase 3.

## Disable, degrade and first look

Phase 3 has no route flag and no Flutter wiring. Keep Agent processes undeployed to disable the path. On append/replay failure, inspect tenant context, Run state/version, `next_event_seq`, the unique sequence constraint, audit receipt, transaction rollback and outbox state. Never synthesize missing events, reuse a sequence manually or bypass RLS.
