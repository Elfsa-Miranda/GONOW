# SSE and interrupted Run recovery runbook

## Authorization and first action

This runbook authorizes only local isolated work or an explicitly approved target. During an
incident, first disable new Agent/SSE routing while preserving Run, Event, interrupt, capability,
and cancellation rows. Disconnecting a client is not cancellation. This document does not grant
production write, process termination, deployment, merge, or acceptance authority.

## Start and health check

1. Confirm environment, tenant, API identity, and PostgreSQL readiness without copying credentials.
2. Confirm the migration head and API/Worker role boundaries. Start API and Worker separately.
3. Create an isolated Run and append business Events. Require monotonically increasing per-Run
   sequence, commit-before-notify, an audit receipt, and no sequence on heartbeat.
4. Connect with no cursor, record the last applied SSE `id`, reconnect with `Last-Event-ID`, and
   require replay from `N+1` followed by lossless live handoff.
5. Exercise a typed interrupt, one-use resume, and durable cancellation before enabling routing.

Run the Phase 6 contract and recovery set from the repository root through the task gate; inspect
the structured JSON/JUnit evidence rather than only exit code.

## Recover a disconnected or backgrounded client

1. Read the locally persisted `(run_id, last_event_id)` only after the previous Event side effect
   was applied.
2. Open the owner-scoped SSE endpoint with that `Last-Event-ID`. Treat gaps as valid and do not
   infer missing Events from arithmetic.
3. Deduplicate by `(run_id, seq)`. Receiving an Event twice must not repeat a UI/domain side effect.
4. Ignore heartbeat comments for cursor and business state. Unknown minor Events are retained by
   raw type and ignored; an unknown major interrupt is not interpreted.
5. If the consumer buffer is exceeded, accept the disconnect, persist the last applied cursor, and
   reconnect. Do not increase an unbounded in-memory queue.

## Resume and cancellation recovery

- Resume: verify tenant/principal/Run/interrupt/command binding and expiry. A mismatch must not burn
  the capability; replay after a successful consume must fail. Never log or persist plaintext.
- Cancel: read Run version and send the CAS command. `CANCELLING` means durable intent, not terminal
  completion. Wait for a safe-boundary `CANCELLED` Event. A dropped HTTP/SSE connection cannot be
  used as evidence of cancellation.
- Race: if resume and cancel compete, accept only the transactionally legal result and recover from
  PostgreSQL. Never turn a timeout into approval or a late success into cancellation reversal.

## Failure triage

- Replay stops: compare cursor, committed maximum sequence, tenant filter, and notification handoff.
- Duplicate UI effect: inspect cursor advancement order and `(run_id, seq)` dedupe; do not hide it by
  skipping the Event.
- Heartbeat advances state: keep routing off; heartbeat must be a comment-only transport frame.
- Resume rejected: classify identity mismatch, expiry, command mismatch, or already consumed.
- Cancel remains pending: inspect Run version, Worker fence, safe-boundary observation, and audit.
- Any prompt/secret field, token plaintext, cross-tenant row, sequence reuse, or terminal reversal:
  preserve evidence and escalate to Security+Data immediately.

## Disable and rollback

Turn Agent/SSE routing off and use the existing non-Agent path. Keep database rows. Route the old
endpoint/profile for compatible clients. Revert only Phase 6 transport/control code after the exact
candidate rollback suite passes; do not reset history, delete Events, reuse a capability, or rewrite
Run terminal state.
