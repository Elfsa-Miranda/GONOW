# Agent SSE v1 contract

## Endpoint and authorization

`GET /v1/runs/{run_id}/events` requires the existing bearer identity and owner-scoped tenant
authorization. `Last-Event-ID` is optional and, when present, is a positive decimal business
sequence. Invalid cursors fail with HTTP 400 before streaming.

## Frames

Business Event:

```text
id: 42
event: step.started
data: {"schema_version":"run-event.v1","run_id":"00000000-0000-0000-0000-000000000000","seq":42,"event_type":"step.started","payload":{},"occurred_at":"2026-08-01T00:00:00Z"}
```

Heartbeat:

```text
: heartbeat
```

The heartbeat has no `id`, `event`, data payload, persistence, or side effect. Business `id` equals
`seq`; sequence is per Run, strictly increasing for committed Events, unique, and may contain gaps.
Event data conforms to `contracts/events/sse-event.schema.json` and never carries prompt, response,
reasoning, secret, token plaintext, tenant selection, or automatic approval.

## Replay and delivery

The server replays committed Events with `seq > Last-Event-ID`, then hands off to live notification
without a loss window. Delivery is at least once across reconnects. Clients apply a side effect once
per `(run_id, seq)` and advance the stored cursor only after application. A bounded slow consumer is
disconnected and resumes from its cursor.

## Interrupt, resume, and cancel control

Typed interrupt payloads use `contracts/interrupt-v1.schema.json`. Resume uses
`POST /v1/runs/{run_id}/resume` with an opaque one-use capability plus exact interrupt and command
binding. Cancel uses `POST /v1/runs/{run_id}/cancel` with `expected_version` CAS. Disconnect and
timeout do not approve, resume, or cancel a Run.

## Compatibility and errors

The current response profile is `error-envelope.v1`; `legacy-detail.v0` remains available for old
clients, and an unknown requested profile degrades to that public-only shape without a forced
upgrade. HTTP status remains stable. Retry responsibility remains with the layer named by the error
registry; transport, client, Tool, Graph, queue, and Run must not each retry the same fault.
