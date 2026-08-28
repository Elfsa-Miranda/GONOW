# Structured Memory local-provisional runbook

The P12A path is a default-off read/proposal capability inside the existing Single-Agent service.
It stores only four user-visible enum preferences for `itinerary.personalization`. It never derives
Memory silently from a transcript, hidden profile, or model inference. A model can propose a
Candidate; the formal record requires explicit user confirmation, current consent, verified
identity, server authorization, CAS, idempotency and outbox.

## Normal and degraded behavior

With the flag off (the default), or with the kill switch active, the read port returns no Memory and
the existing Release B behavior continues. Missing/denied/revoked/expired consent, purpose mismatch,
identity ambiguity, tenant/principal mismatch, conflict, quarantine, expiry or deletion denies
materialization. The port returns typed facts only and cannot call a model, Tool or coordinator.

## Conflict, export and deletion

A competing value moves the slot to `conflicted`; it does not overwrite the prior fact. Both values
and provenance remain user-visible until a separately authorized explicit resolution. Export uses
the same principal/purpose/consent check and includes only active unexpired records.

Deletion and consent withdrawal write a tombstone and fan out to the record, Candidate, index,
cache, export, eval trace and restore ledger. Restore must load consent and tombstones before opening
read aliases. A rollback may disable the feature but must never reactivate a tombstoned generation.

## Local verification and evidence boundary

Run the focused Memory unit/contract/integration/security/eval set without model credentials. At
P12A-990 run the repository's full regression exactly once. The local tests prove contracts and
mechanism behavior only. Production schema/RLS, consent inventory, traffic, long-horizon value,
backup topology and deletion deadlines remain unknown until separately observed and approved.
