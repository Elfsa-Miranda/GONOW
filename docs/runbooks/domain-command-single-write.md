# Domain Command single-write runbook

## Scope and invariant

This runbook applies only to
`ItineraryProvider.updateItineraryBasicInfo` on `user_itineraries`.
`gonow_itinerary_basic_info_command_v1` is independent from the itinerary
planning flag, defaults disabled, and has a default-active kill switch. No
other itinerary writer is allocated to the command path.

For one intent, exactly one writer may be selected:

- flag disabled, kill switch active, or command route unavailable before an
  attempt: use the retained legacy writer;
- flag enabled, kill switch inactive, and the command client available: use
  the Domain Command writer and never invoke the legacy writer for that
  intent.

Production allocation remains zero in P12D. Enabling a production allocation
requires the applicable governance receipt, reviewed production schema and
RLS evidence, deployment-specific composition, and an independently approved
cutover decision.

## Command outcome handling

- `committed`: validate the closed receipt and exact command/version binding,
  then publish local success state at `actual_version`.
- `conflict`, `denied`, or `rejected`: preserve the previous local success
  state. Do not call the legacy writer.
- known pre-commit transport failure: return the retryable error. Do not call
  the legacy writer.
- timeout, response loss, or any unknown commit outcome: query the receipt
  with the original target and idempotency key. A matching receipt may resolve
  the outcome. A missing or unreadable receipt returns
  `domain_command.outcome_unknown`; it must not trigger a legacy write.

Retries must reuse the original idempotency key. Reusing a key with a different
semantic body is an idempotency collision, not a new write attempt.

## Rollback

1. Set the Domain Command kill switch to active and allocation to zero.
2. Confirm new Basic Info intents select the retained legacy writer exactly
   once.
3. Continue receipt lookup and outbox reconciliation for commands submitted
   before the switch. Do not resubmit them through the legacy writer.
4. Retain the additive command tables, receipts, outbox rows, migration, test
   evidence, and compatible API contract. Rollback is a routing change, not a
   destructive schema downgrade.
5. Investigate any duplicate formal write, unauthorized/cross-tenant write,
   mutation/outbox divergence, unrecoverable committed outcome, or data loss as
   a zero-tolerance redline.

The legacy path cannot be removed until the old-client compatibility window
has expired and cleanup has separate approval and evidence. Synthetic failure
injection and the local 10k/10k profile prove controlled mechanisms only; the
production improvement status remains `measurement_pending`.
