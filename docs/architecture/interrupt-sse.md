# Phase 6 interrupt and SSE architecture

## Scope and status

Phase 6 adds a local provisional transport and control-plane candidate to the existing API/Worker
split. PostgreSQL is the fact source for Run Events, typed interrupts, resume capability digests,
and cancellation state. The worktree is not a production deployment, remote merge, or formal
acceptance. Heartbeats, connection state, and client retry timers are not business facts.

## Event and replay chain

1. A transaction locks one Run row, allocates its next business `seq`, inserts the Event and audit
   receipt, commits, and only then notifies listeners. Failed writes may leave gaps; they cannot
   make a higher sequence visible before a lower committed sequence.
2. `GET /v1/runs/{run_id}/events` authorizes tenant ownership, parses `Last-Event-ID`, replays all
   committed Events after the cursor, and then hands off to live notification without a replay/live
   loss window.
3. SSE `id` equals the decimal business sequence. Heartbeat is a comment frame and has no `id`,
   event type, payload, persistence, or side effect. Slow consumers are disconnected at a bounded
   buffer and resume through their last persisted cursor.
4. Duplicate connections may receive the same Event, so mobile applies a side effect once per
   `(run_id, seq)` and advances its cursor only after local application succeeds.

## Interrupt, resume, and cancellation chain

- Interrupt payloads are a versioned discriminated union: `missing_info`, `risk_confirmation`, or
  `approval`. Unknown major versions and prompt, reasoning, secret, automatic-approval, or extra
  fields fail before persistence.
- A resume capability is opaque to the client. The database stores only its digest and binds it to
  tenant, principal, Run, interrupt, command hash/version, expiry, and one-use consumption state.
  Identity mismatch does not consume it; concurrent valid use has exactly one winner.
- Cancellation is a durable CAS command. It records `CANCELLING` after authorization and audit,
  independent of the HTTP connection. The current Worker observes the intent at a safe boundary
  and performs the only legal terminal move to `CANCELLED`; late success cannot reverse it.

## Compatibility boundary

The default error body remains `error-envelope.v1`. Explicit legacy or unknown profiles safely
project a public message to `legacy-detail.v0` while preserving the HTTP status. No exception,
prompt, secret, or internal detail is reflected, and no client is forced to upgrade. This profile
does not add a new endpoint or a second retry owner.

## Enable, disable, and degrade

Enable only after the Phase 6 schema, API contract, 1/2/4 replay, six-writer concurrency,
resume/cancel races, mobile reconnect fixture, and error compatibility suite all pass against the
exact candidate. Keep routing off until the authorized owner records the decision.

Disable by turning the Agent/SSE flag off and routing to the existing non-Agent flow. Preserve
durable rows and cursors. A database outage fails the Agent path closed. A slow or disconnected
client reconnects; it does not cancel a Run. An unknown interrupt version shows an upgrade path but
cannot be guessed or auto-approved.

## First diagnosis

Check database readiness and tenant/Run identity, then persisted maximum business `seq`, requested
`Last-Event-ID`, replay/live handoff state, client dedupe cursor, interrupt version, capability
expiry/consumption, Run version, and cancellation state. Event loss, duplicate side effects,
cross-tenant visibility, token replay, or a cancelled Run becoming successful keeps routing off and
is release blocking.

## Evidence boundary

Local deterministic suites proved 1/2/4 gap handling, six concurrent writers, zero heartbeat
business IDs, replay/live/background/slow-consumer races, one-use resume, CT-010 cancellation, and
six legacy/current error flows. A Flutter VM exact-byte fixture passed; a formal mobile-device run,
independent review, production traffic, latency, cost, and availability evidence remain pending.
