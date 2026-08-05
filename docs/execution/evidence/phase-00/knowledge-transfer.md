# Phase 0 knowledge transfer

## Responsibilities and boundaries

Flutter owns only ordinary-chat presentation and the fixed gateway client. Security owns provider revocation, gateway approval, secret scanning, and activation constraints. Data owns the read-only production schema/RLS/grant inventory. The future Agent team starts a new `agent-service/` in Phase 2; it must not inherit the legacy provider code or this Release A gateway as an Agent runtime.

## Dependency choices

No new runtime dependency was added. The gateway uses the existing HTTP client; the logger uses Dart JSON and Flutter debug output. CI actions are pinned. The compatibility suite uses a disposable VM worktree because the task cannot add the missing `integration_test` SDK dependency; this proves offline contracts, not device UI behavior.

## Hardest items

1. Containing a committed credential without vendor authority: the client exposure was removed locally while revocation/billing stayed explicitly external.
2. Distinguishing real analyzer regressions from three frozen baseline errors: P00-007 compares exact base/candidate sets and blocks only new errors/failures/skips.
3. Preserving diagnostics without leaking content: 78 legacy sinks now discard free-form values and retain fixed feature source events.

## Operations

For model failures, first confirm the gateway is enabled for the intended build, auth exists, and the exact host matches; then inspect only structured status/request identifiers. Disable the feature on uncertainty. For suspected secret exposure, revoke and rescan before any release action. Never restore client-direct provider access.

## Estimate and handoff verification

The plan estimates are planning ranges, not elapsed-time commitments; no personnel-hour claim is inferred from this automated run. Local handoff replay passes the 4 gateway, 3 redaction, and 6 compatibility assertions. A non-implementer replay and production-only evidence remain pending, so the task is blocked rather than accepted.
