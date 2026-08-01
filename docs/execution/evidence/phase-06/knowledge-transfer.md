# Phase 6 knowledge transfer

## Responsibilities and dependency choices

The Event writer owns transaction locking, sequence allocation, persistence, and post-commit
notification. The SSE layer owns bounded replay/live handoff and comment-only heartbeat. Interrupt
parsing owns versioned public payloads; the resume service owns digest, identity, expiry, and one-use
CAS; cancellation owns durable intent and safe terminal transition. PostgreSQL remains the fact
source. No Redis queue, second Agent, connection-owned cancel, or client secret was introduced.

## Hardest items

1. Replay/live handoff had to close the window between the replay query and listener registration
   while keeping delivery at least once and the client side effect exactly once.
2. A local Windows host lacked a usable mobile integration device/toolchain. The repaired harness
   proves exact source bytes and runs the deterministic network controller through Flutter VM while
   keeping formal mobile-device evidence explicitly pending. The STAR record preserves the before
   and after commands and hashes.
3. A published 503 code was accidentally rewritten to `internal.error`; the compatibility matrix
   exposed the mismatch and the focused repair preserves registered public 5xx while still hiding
   unknown exceptions and explicit client-error-to-5xx overrides.

## Operations must know

Disable Agent/SSE routing first. Inspect database/tenant/Run, persisted sequence, client cursor,
replay/live state, interrupt version, resume digest/expiry/consumption, Run version, and cancellation
state. Never use heartbeat as business state, disconnect as cancellation, timeout as approval, or a
late success to reverse `CANCELLED`. Event loss, duplicate effects, cross-tenant data, token replay,
or private detail leakage remains release blocking.

## Estimate comparison

Task estimates are person-day ordering inputs. Local automation produced deterministic database,
API, Flutter-VM, and compatibility evidence in a continuous run, but it is not comparable to
independent review, a physical mobile-device run, production proxy behavior, traffic observation,
latency/cost measurement, or rollout. Those durations and outcomes remain unknown.

## Handoff verification

The local handoff reruns the Phase 6 event writer, SSE replay, interrupt, resume, Harness 14,
cancellation, network races, error compatibility, and published error/OpenAPI regressions with zero
failures, skips, or xfails. The implementer performs it, so `reviewer_is_implementer=true` and formal
Mobile+SRE handoff stays `pending_external`; local success is not formal acceptance.
