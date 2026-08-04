# Release C selection interface boundary

## Public API status

Phase 12D adds a strict internal Domain Command contract and typed Dart client for exactly itinerary
Basic Info. The route is not mounted in the default API composition, so the published OpenAPI remains
unchanged. No Event, State, Candidate, or SSE public contract changes.

runtime_change_count: 1
public_contract_change_count: 0
schema_change_count: 1
implementation_commit_count: 5
production_write_count: 0
selected_count: 1

## Governance record shape

The following is a documentation model for later repository evidence, not a network API and not a
valid approval by itself:

```json
{
  "schema_version": "1.0",
  "cycle_id": "owner-issued immutable identifier",
  "release_b_head_oid": "full Git object ID",
  "release_b_evidence_sha256": "immutable evidence manifest digest",
  "evidence_window": {
    "started_at": "ISO-8601 with timezone",
    "ended_at": "ISO-8601 with timezone",
    "numerator": "integer",
    "denominator": "integer",
    "exclusions": "versioned rule reference",
    "uncertainty": "calibrated interval or explicit unknown"
  },
  "selection": "12A|12B|12C|12D|none",
  "selected_count": "0 or 1",
  "owner_decision_references": ["immutable owner-controlled references"],
  "production_write_count": 0
}
```

The formal runner must reject missing or mismatched cycle, head, digest, evidence window, owner
identity, or XOR reservation. `selected_count=1` records the user's local 12D choice; it does not
grant production allocation or replace independent owner approval.

## Implemented internal command boundary

The internal route shape is
`POST /v1/itineraries/{itinerary_id}/commands/basic-info`. The request contains only the selected
Basic Info fields, expected version, idempotency key, and trace reference. Principal, tenant, role,
approval, and purpose come from trusted server context and are forbidden in client input. The result
is a closed metadata-only receipt. `GET` receipt lookup by the original idempotency key resolves an
unknown response outcome.

Unknown version, identity, authorization, collision, or receipt outcome fails closed. A stale
command makes zero business, receipt, or outbox side effects. A reused key with different semantic
content is a collision. Same key and same content returns the original receipt. Client transport
ambiguity never falls back to the legacy writer.

The additive `domain_command` schema contains attempts, receipts, and outbox events under FORCE RLS.
It does not guess or create the production `user_itineraries` table. Production schema equivalence
remains unknown and must be inventoried before production authorization.

## Compatibility and rollback

With `gonow_itinerary_basic_info_command_v1` off, the Basic Info provider uses the legacy path. With
the flag on and kill switch inactive, only that write entry uses the command client; all other writes
stay unchanged. Conflict and unknown outcome do not publish local success. Rollback disables new
command routing but preserves command receipts, outbox events, and compatible business data.
