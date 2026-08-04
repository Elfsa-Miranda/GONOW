# Phase 12D Domain Command knowledge transfer

hardest_item_count: 1

## Responsibilities and dependency choices

The package keeps one Agent codebase with `agent-api`, `agent-worker`, PostgreSQL, and static internal
tools. Domain Platform owns the command implementation; Architecture, Security, Product, and Data own
the remaining independent review. The user selected only 12D. Memory, routing, and Multi-Agent are
outside this cycle.

## Hardest item

The hardest reliability boundary is a response lost after database commit. The client cannot know
whether a legacy fallback would double-write, so it must query the original idempotency receipt.
The handler, client, concurrency test, and fault matrix all enforce this same rule. A unique-key race
was repaired once by rolling back and converging on the exact tenant-scoped receipt in a fresh
transaction; the affected matrix then passed.

## Operations must know

The internal server route is unmounted by default. The Flutter flag
`gonow_itinerary_basic_info_command_v1` is off by default and its kill switch is active by default.
For an unknown outcome, inspect the original receipt before any retry; never route that intent to the
legacy writer. For stale conflict, verify no local success state changed. First inspect tenant and
principal context, expected version, semantic command digest, idempotency digest, receipt, outbox,
and fence. Other itinerary writes are intentionally unchanged.

## Estimate comparison

The implementation produced five runtime task commits plus independent activation, selection, and
acceptance commits. No calendar-time equivalence is claimed. The measurable behavior result is the
pre-registered controlled stale-conflict rate, with 10,000 intents in each arm and no denominator
exclusions. Candidate elapsed time is diagnostic only and is not a production latency claim.

## Handoff verification

Local self-review checks the selected entry, migration/RLS, atomicity, receipt recovery, route/flag,
controlled inputs and denominators, redlines, regression totals, JSON parsing, changed-path scope,
and rollback. It does not impersonate an independent reviewer. Security+Product+Data verification
and formal acceptance remain `pending_external`.

## Known risks and recovery

The remaining risk is mistaking isolated PostgreSQL results for production facts. Every STAR and
profile therefore sets `production_improvement_claim=false`. Operational rollback turns off the
named flag or activates its kill switch for new intents, preserves additive command data and receipts,
and returns Basic Info to the legacy writer. Database removal is deferred until usage is zero and a
separate contract migration is authorized.
