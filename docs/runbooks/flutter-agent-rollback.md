# Flutter itinerary Agent operations and rollback

This runbook applies to the Phase 9 local-provisional itinerary Agent route. It does not authorize
production activation or production writes.

## Normal state

The safe default is feature disabled, kill switch active, ordinary chat on legacy, and itinerary
planning on legacy. Agent Run/Event and Domain Command facts remain preserved for audit and replay.

## Enable

Use only an authorized isolated environment. Confirm all Phase 9 task gates are mechanically
passing, the contract digest is
`ba776e2c464ff6faf1866c7e369756368a43b5023642ac6318758e55f857b8ed`, and client/server generations
match. Then enable `gonow_itinerary_agent_v1` and clear the kill switch for the intended local
fixture. Do not infer a production cohort from this step.

## Disable

Set the kill switch active or the feature flag disabled. Verify the route reason is
`kill_switch_active` or `flag_disabled`, ordinary chat still reports `ordinary_chat_bypass`, and the
legacy itinerary fixture is unchanged. Do not delete Run, Event, approval, audit, or outbox rows.

## Degrade

On contract digest mismatch, generation mismatch, service unavailable, terminal history expiry, or
an unclassified client failure, keep the user on the legacy route and surface the typed public error.
Do not retry an adoption by inventing a new capability or by treating a disconnect as cancellation.
Preserve the existing Run reference unless a matching terminal event proves it can be cleared.

## First checks

1. Read the route decision and stable reason code.
2. Compare client and server generations and the OpenAPI digest.
3. Confirm the active Run ID and last persisted event ID refer to the same Run.
4. Distinguish disconnect, HTTP 410 history expiry, authorization denial, and explicit cancellation.
5. For adoption, inspect expected version, approval receipt, nonce-consumption result, Event sequence,
   and outbox receipt without recording credential or request-body content.
6. If the failure concerns production table mapping, stop only the adoption action and use the
   documented Phase 9 blocker; other local read/UI/compatibility checks remain ready.

## Rollback verification

Engage the kill switch, rerun the flag-off and four-pair compatibility suites, then rerun the
critical Flutter journey in the exact-byte VM fixture. Expected local result is legacy available,
10/10 Flutter tests passing, zero skip, and zero production writes. Rollback does not erase durable
facts and does not claim a real-device or production drill. Independent handoff and mobile-device
validation remain `pending_external`.
