# Phase 5 durable recovery architecture

## Scope and status

Phase 5 adds a PostgreSQL-backed recovery path for the existing Agent API/Worker split. It is
a local provisional candidate: no production route, remote merge, deployment, or formal
acceptance is authorized. PostgreSQL remains the Run, Event, Job, Lease, checkpoint, physical
invocation, and budget fact source. Redis, an external queue, and a second Agent are absent.

## Recovery chain

1. A Worker claims one ready Job with `SELECT ... FOR UPDATE SKIP LOCKED`. A retry with the same
   holder replays the live claim; a new claim advances the Job attempt and fencing token once.
2. Lease renewal and expiry use database time and compare tenant, Job, holder, and fencing token.
   Reclaim releases only a proven-expired lease and creates a strictly newer fence.
3. `GoNowPostgresCheckpointSaver` implements the locked LangGraph v1 saver protocol over
   Alembic-owned tables. It stores canonical JSON and content-addressed references, not clients,
   connections, raw Prompt/Tool bodies, reasoning, or pickle payloads.
4. Before a physical Tool call, the invocation ledger reserves a deterministic fingerprint and
   a physical-call budget slot under the current fence. A terminal receipt replays; a reserved or
   ambiguous result routes to reconciliation. Unknown outcome is durable and is never refunded or
   blindly invoked again.
5. The bounded reconciler scans at most 100 records, preserves any live lease owner, repairs only
   stale Job/Run/Lease combinations by CAS, and appends an audit Event for every applied repair.
6. API and replacement Worker reconstruct state from PostgreSQL only. Recovery preserves the Run
   and its audit history; it never deletes the Run to manufacture a clean retry.

## Hard invariants

- Every mutation is tenant scoped and transaction owned.
- A stale or expired holder produces zero checkpoint, invocation, Job, Lease, or Run writes.
- Job claim, lease renewal/reclaim, checkpoint persist, invocation persist, and terminal Run
  transition all bind the current fencing token.
- Physical-call budget is reserved before the handler. A response-lost retry cannot consume a
  second slot or call the handler again unless the ledger proves that execution is safe.
- Checkpoint envelope version 2 is current. The explicit version-1 upgrade is deterministic;
  unknown or malformed versions fail closed.
- Reconciliation is bounded, idempotent for an already repaired row, and audit producing.
- PostgreSQL is the sole durable recovery source. An outage keeps Agent routing off; it does not
  authorize an in-memory or Redis truth source.

## Enable, disable, and degrade

Enable only after migrations are applied in an authorized environment, API/Worker roles pass RLS,
the Worker can claim and renew a test Job, and the structured recovery rehearsal has zero failed,
skipped, or xfailed cases. Start API and Worker as separate processes and leave the Agent feature
flag off until the owner records the decision.

Disable by turning Agent routing off and stopping new Worker claims. Preserve all PostgreSQL rows;
do not restore an old fence or refund an unknown invocation. The supported degradation is the
existing non-Agent itinerary path. PostgreSQL unavailability is a fail-closed Agent outage.

## First diagnosis

Start with database readiness and identity, then inspect Run state/version, Job status/attempt,
the newest Lease holder/fence/expiry, latest checkpoint reference, invocation status, physical
budget, and reconciler audit Event—in that order. If an old Worker can write, a duplicate side
effect appears, or tenant scope is wrong, keep routing off and escalate as a release-blocking
security/data incident.

## Evidence boundary

The isolated suite proved six Jobs had one owner each under ten concurrent claimers, seven real
process-termination scenarios denied all seven old Workers, CT-005 and CT-006 passed, and the
PostgreSQL-only restart had zero budget delta, duplicate side effect, orphan process/database row,
or Redis dependency. These are local deterministic results, not production availability, RPO/RTO,
latency, cost, or real-traffic claims.
