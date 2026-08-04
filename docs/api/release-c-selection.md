# Release C selection interface boundary

## Public API status

Phase 12A adds an internal Structured Memory domain and a default-off Single-Agent read port. It does
not change published OpenAPI, Event/State/Candidate/SSE, Flutter/Dart, or process-topology contracts.
It adds one local database migration for seven internal tables and FORCE RLS policies; production
database equivalence is not claimed.

runtime_change_count: 1
public_contract_change_count: 0
schema_change_count: 1
production_write_count: 0
selected_count: 1
candidate_allocation: 0

## Closed data contract

| Field | Rule |
|---|---|
| type | one of `travel_pace`, `mobility_requirement`, `dietary_requirement`, `transport_preference` |
| value | closed typed value for that type; no free text or transcript |
| purpose | exactly `itinerary.personalization` |
| subject | authenticated tenant and principal |
| consent | current, purpose-specific, versioned, and unexpired |
| provenance | explicit user source and Candidate/confirmation lineage |
| retention | explicit expiry, no more than 365 days |
| version | compare-and-swap version for mutation and conflict resolution |
| deletion identity | stable identifier bound to tombstone and restore suppression |

Missing, expired, mismatched, or ambiguous authority denies read and write. Model output is only a
Candidate. Formal mutation requires explicit user confirmation, server authorization, CAS,
idempotency, and an atomic outbox record.

## Internal operations

- `propose`: validates a typed Candidate but performs no formal write.
- `confirm`: reauthorizes the user and purpose, verifies consent and CAS, then writes the formal row,
  receipt, and outbox atomically.
- `read`: returns only typed values already authorized for the exact tenant, principal, and purpose.
- `resolve_conflict`: preserves both claims and provenance until an authorized expected-version
  decision succeeds.
- `delete` / `withdraw_consent`: tombstones and suppresses record, Candidate, index, cache, export,
  eval trace, and restore ledger materialization.
- `export`: returns only user-visible Memory for the authenticated subject and allowed purpose.
- `restore`: replays tombstones before materializing backup data.

These are internal domain contracts, not newly published network endpoints. The Worker has no direct
formal-write authority. The Single-Agent read port is default off and contains no coordinator,
specialist, model call, or Tool dispatch.

## Governance record shape

```json
{
  "schema_version": "1.0",
  "cycle_id": "p12a-local-provisional-20260805",
  "selection": "memory",
  "selected_count": 1,
  "selected_task": "TASK-P12A-990",
  "candidate_allocation": 0,
  "formal_acceptance": false,
  "production_write_count": 0
}
```

This record is local evidence, not an approval or public API. Production schema/RLS/grants, backup
tombstone replay, traffic, consent population, and product impact remain `unknown/pending`.
