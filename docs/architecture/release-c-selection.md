# Release C selection architecture

archive_mode: local_provisional
formal_selection_status: local_provisional_selected
selection_cycle: p12a-local-provisional-20260805
selected_candidate: 12A
selected_count: 1
formal_none_decision: false
design_ready_count: 1
runtime_change_count: 1
public_contract_change_count: 0
schema_change_count: 1
production_write_count: 0
multi_agent_implementation_count: 0

## Decision boundary

This cycle selects only Phase 12A Structured Memory. The implementation is local provisional and
ends at `ready_for_review`; independent owner approval, remote integration, production deployment,
and Release C acceptance remain pending. P12B, P12C, and P12D are dormant for new work in this
cycle. Their historical evidence is retained but does not authorize allocation or further changes.

The architecture remains one Agent codebase with `agent-api` and `agent-worker` processes. P12A adds
no coordinator, specialist Agent, Redis, queue, dynamic MCP marketplace, model-routing layer, or
public client contract. PostgreSQL remains the intended durable source of truth, while the actual
production schema, grants, RLS, triggers, data, backups, and traffic remain `unknown`.

## XOR candidate map

| Candidate | Present disposition |
|---|---|
| 12A explicit Structured Memory | selected and implemented locally; default off; production allocation zero |
| 12B deterministic Cost Router | historically integrated local provisional; dormant this cycle |
| 12C production Multi-Agent | explicitly dormant; no runtime or allocation |
| 12D one Domain Command migration | historical `ready_for_review`; dormant this cycle |

Selecting another capability requires a new XOR cycle, evidence window, ADR/gates, rollback exercise,
and integration decision.

## Structured Memory contract

### Data and purpose

P12A supports exactly four closed, typed, user-visible values:

- `travel_pace`
- `mobility_requirement`
- `dietary_requirement`
- `transport_preference`

The only allowed purpose is `itinerary.personalization`, and retention is bounded to at most 365
days. Free text, chat transcripts, hidden profiles, inferred traits, prompts, reasoning, secrets,
and unrelated tenant data are not Memory. A model may propose a typed Candidate but cannot create,
update, delete, export, or restore a formal record.

Every record binds tenant, principal, purpose, consent version and expiry, provenance, record version,
retention, and stable deletion identity. Missing or expired consent, purpose mismatch, tenant or
principal ambiguity, and unknown identity deny reads and writes. Tenant membership alone is not
sufficient authority.

### Write and read authority

Formal writes require explicit user confirmation followed by server authorization, compare-and-swap,
idempotency, and an atomic outbox receipt. Seven local PostgreSQL tables use FORCE RLS and tenant plus
principal policies. The Worker role cannot directly mutate formal Memory. The existing Single-Agent
runtime receives only already-authorized typed values through a default-off read port; its kill switch
returns the prior no-Memory behavior without invoking a model or Tool.

### Conflict, poisoning, and lifecycle

- Conflicting values never silently overwrite each other. Both claims and their provenance remain
  user-visible until an authorized resolution succeeds with the expected version.
- Retrieved Memory is untrusted data. It cannot grant permission, change instructions, call a Tool,
  or create another Memory.
- Delete and consent withdrawal produce durable tombstones and fan out to the formal record,
  Candidate, index, cache, export, eval trace, and restore ledger.
- Restore replays the tombstone ledger before materialization. Deletion never rolls back, so a backup
  cannot legitimately resurrect deleted or consent-revoked data.
- Export is scoped to the authenticated principal and allowed purpose, and excludes internal audit,
  prompts, reasoning, secrets, and other tenants.

## Activation, degradation, and rollback

The feature remains default off with production allocation and production writes at zero. Formal
activation requires an owner-approved production schema/RLS/grant inventory, data and privacy review,
deletion/export/restore drills against the real recovery path, monitoring, rollout authority, and an
independent review bound to exact Git object IDs.

Degradation disables proposals and the Single-Agent read port, or activates the kill switch, while
preserving formal records, audit, outbox, and tombstones. Rollback returns to the prior Release B
Single-Agent behavior. It must never remove tombstones, restore revoked consent, or re-enable deleted
data.

## Evidence boundary

The repository proves a local typed lifecycle, authorization decisions, FORCE RLS isolation in an
isolated PostgreSQL fixture, deterministic conflict behavior, deletion/export/restore mechanics,
Single-Agent compatibility, and zero model API calls. It does not prove the production database has
the same schema or policies, that production backups honor tombstones, that real users consented, or
that Memory improves a production outcome. Those facts remain `unknown/pending`.
