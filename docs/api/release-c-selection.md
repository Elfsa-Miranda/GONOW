# Release C selection interface boundary

## Public API status

This Phase 12 archive changes no OpenAPI, Dart, Event, State, Candidate, SSE, Domain Command, or
database schema. It adds no endpoint and reserves no public error code. Existing clients and the
single-Agent runtime therefore remain byte-for-byte governed by the prior contracts.

runtime_change_count: 0
public_contract_change_count: 0
schema_change_count: 0
implementation_commit_count: 0
production_write_count: 0
design_ready_count: 3

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
identity, or XOR reservation. `selected_count=0` in this provisional archive is not a formal
`selection=none` receipt. `design_ready_count=3` means only that A/B/D plans and local evidence pass
their design gates; it creates no API, selection, allocation, or implementation authority.

## Future internal ports, if selected

These are architecture constraints for a later selected package; they are not implemented types:

- 12A exposes an authorized typed Memory read port and a separate explicit-confirmation Domain
  Command. Raw history and hidden model profiles are not inputs.
- 12B exposes a deterministic route decision with policy digest, reason, certified route, price
  snapshot, budget reservation, and fallback. Free-form model text cannot select a route.
- 12D exposes one typed command containing principal context, approval, expected version,
  idempotency key, and trace reference, returning a stable receipt or stable failure.
- 12C exposes nothing in this archive because Multi-Agent is deferred.

Unknown version, identity, consent, route certification, authorization, or receipt outcome fails
closed. Any future public or database contract change requires its own ADR, generated-client update,
compatibility matrix, migration/rollback evidence, and formal selection.

## Compatibility and rollback

With every Phase 12 flag off, behavior must equal the accepted Release B package. Reverting the
archive changes documentation only. A later selected package must provide an independent
flag/route/alias and a Release B equivalence replay before traffic; rollback disables only that
selection and preserves durable evidence and compatible data.
