# Phase 6 change summary

Before Phase 6, Runtime Events existed in PostgreSQL but there was no complete per-Run writer,
lossless SSE replay/live handoff, typed interruption/resume capability, durable cancellation
boundary, mobile recovery-race fixture, or explicit old-client error compatibility matrix.

Observable local differences:

- per-Run event allocation is transaction locked, commit-before-notify, gap tolerant, and excludes
  heartbeat from business sequence;
- SSE replays after `Last-Event-ID`, then hands off to live notification without event loss;
- slow/duplicate/background connections recover with at-least-once delivery and client dedupe;
- typed interrupts reject unknown versions, automatic approval, and prompt/secret-class fields;
- resume capability is identity/command bound, expiring, one-use, and plaintext-free at rest;
- cancellation persists `CANCELLING`, transitions at a safe boundary, and satisfies CT-010;
- current, legacy, and unknown error profiles preserve six critical HTTP flows without internal
  detail leakage or forced upgrade; and
- Harness control 14 moves to implemented and control 25 receives the Phase 6 event-writer
  regression extension. The first-phase-through-P6 unimplemented Harness count becomes zero.

OpenAPI and SSE contracts now describe the three Phase 6 endpoints and wire schema. All local
implementation tasks are `ready_for_review`; independent review, formal mobile-device execution,
production validation, push/merge, deployment, and `accepted` remain pending.
