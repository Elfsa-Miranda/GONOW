# Release C selection architecture

archive_mode: local_provisional
formal_selection_status: pending
selected_count: 0
formal_none_decision: false
design_ready_count: 3
runtime_change_count: 0
public_contract_change_count: 0
production_write_count: 0
multi_agent_implementation_count: 0

## Decision boundary

This document is a dormant architecture archive, not `TASK-P12-000`, an ADR, an owner approval, or
a Release C selection receipt. The formal Phase 12 sequence remains
`P12-000 -> P12-001 -> P12-002 -> exactly one of {12A,12B,12C,12D} or none -> P12-089`.
Release B stable evidence and an accepted REL-C `path=phase12` record are not materialized here, so
the formal tasks remain `not_started`. `selected_count: 0` describes the present archive state; it
must not be interpreted as the formal `none` decision.

The deployed architecture target therefore remains one Agent codebase with two processes,
`agent-api` and `agent-worker`. PostgreSQL remains the durable source of truth. The existing static
Tool registry remains internal. No Redis, queue, dynamic MCP marketplace, extra coordinator, or
new production boundary is introduced.

## XOR candidate map

| Candidate | Dormant architecture covered | Trigger still required | Present disposition |
|---|---|---|---|
| 12A explicit structured Memory | consent, provenance, conflict, deletion/export, restore guard | calibrated real failure ledger; the `>15%` value remains an initial hypothesis | dormant design ready; no DDL, service, profile, specialist branch, or cohort |
| 12B deterministic cost router | certified-route policy, quality floor, budget ledger, fallback | four comparable weeks of labelled cost/quality evidence; `1.5x` remains an initial hypothesis | dormant design ready; no router, gateway, routing model, specialist branch, or cohort |
| 12C production Multi-Agent | no framework design is opened by this archive | a separately approved positive trigger and full XOR cycle | explicitly deferred; no ADR, task plan, branch, runtime, or allocation |
| 12D one Domain Command migration | principal, approval, CAS, idempotency, outbox, compatibility | one named legacy write point with real load/SLA and risk evidence | dormant design ready; no named write point, write-path, schema, specialist branch, or migration change |

Only one row may move out of dormant design into formal selection in a Release C cycle. A second capability requires a
new release cycle, evidence window, ADR, gate set, rollback exercise, and merge.

## 12A: explicit structured Memory

### Data and authority

Memory is a typed, user-visible domain record, never a hidden transcript cache or model profile.
Every record must bind tenant, principal, purpose, consent state, provenance, created/updated
versions, retention class, and a stable deletion identity. Consent defaults to negative: absence,
expiry, purpose mismatch, or identity ambiguity denies both write and materialization.

The model may propose a Memory Candidate but cannot create or mutate formal Memory. A later
implementation must use explicit confirmation followed by an authorized Domain Command with
compare-and-swap (CAS), idempotency, and outbox receipt. Row-level security must constrain both
reads and writes. The single Agent receives only already-authorized typed Memory through a narrow
read port; it must not infer access from tenant membership alone.

### Conflict, poisoning, and lifecycle

- New facts do not silently overwrite conflicts. The record keeps the competing claims,
  provenance, state, and user-visible resolution.
- Retrieved text is untrusted data. It cannot grant permission, alter system instructions, call a
  Tool, or create another Memory.
- Delete and negative-consent tombstones fan out to primary rows, indexes, caches, exports, and
  derived candidates. Restore replays tombstones before materialization so backups cannot resurrect
  deleted or revoked data.
- Export is purpose-scoped and excludes secrets, hidden prompts, reasoning, and unrelated tenants.

### Activation and rollback

Activation requires a selected 12A ADR, CT-009/CT-015 coverage, privacy/data approval, a deletion
and restore drill, a default-off flag, and a zero-leakage cohort. Rollback sets allocation to zero,
disables Memory reads and proposals, preserves audit/tombstones, and returns to the Release B
single-Agent behavior. It must not re-enable deleted data.

## 12B: deterministic cost router

### Route decision

Routing is a deterministic policy over certified capabilities, task class, region, privacy class,
quality floor, latency budget, current budget ledger, and provider health. It is not another LLM and
does not accept free-form model output as a route. A Run pins the route-policy digest, route reason,
price snapshot, provider/model identifier, and fallback chain so replay and cost attribution remain
possible.

Only routes with current capability certification and allowed data residency may be considered.
Budget is reserved before invocation and reconciled against physical attempts; retries cannot hide
or borrow cost. Quality/safety floors are non-compensable: a cheaper route cannot offset a tenant
leak, forbidden Tool action, contract failure, or material quality regression.

### Degradation and rollback

Unknown labels, stale price evidence, exhausted budget, region mismatch, or missing certification
fall back to the current certified route or fail closed according to the existing Behavior Package.
A kill switch bypasses the router without changing the Candidate contract. Rollback restores the
previous route-policy digest, sets experimental allocation to zero, and retains the decision/budget
ledger for audit. It does not create a central gateway or dynamic provider market.

## 12D: one Domain Command migration

The future work package must name exactly one existing legacy write entry from verified load and SLA
evidence. It cannot bundle itinerary, diary, preference, and collaboration writes into one migration.
The selected command accepts a typed request with authenticated principal, purpose, approval
evidence, expected resource version, idempotency key, and trace reference. In one transaction it
reauthorizes, validates field authority, applies CAS, writes the domain mutation, emits an outbox
event, and stores a stable receipt. A timeout with unknown outcome is resolved by receipt lookup,
never blind replay.

Migration follows expand-contract: add the command and compatibility adapter, shadow/compare without
formal double-write, move a bounded cohort, verify Realtime/read-model compatibility, then retire the
legacy write only after usage reaches zero and rollback is proven. Rollback routes the cohort back to
the legacy authorized path while retaining command receipts and compatible data. This archive makes
no schema or write-path change.

## 12C: Multi-Agent explicitly deferred

Phase 8 produced a credible synthetic `none` result and did not open a production Multi-Agent
candidate. The current user direction is also to finish the high-quality single-Agent architecture
first. Consequently this archive creates no P12C ADR or task plan, no coordinator or specialist
roles, no shared-branch runtime, and no production allocation. Any later consideration must start a
fresh formal XOR cycle and prove a benefit that a single Agent plus deterministic tools, RAG,
Memory, or routing cannot deliver at lower risk.

## Formal activation sequence

1. Bind an accepted Release B head and a stable, immutable evidence window.
2. Calibrate numerator, denominator, exclusions, uncertainty, quality, latency, cost, and redlines.
3. Execute P12-000 and choose exactly one candidate or formal `none`.
4. Obtain the selected ADR and owner decision in P12-001; reserve the XOR slot in P12-002.
5. Materialize only the selected candidate work package, then split implementation into atomic tasks
   with dedicated acceptance and merge tasks. The design card itself never proves implementation.
6. Prove Release B equivalence when the independent flag/route/alias is off, then merge only to
   `codex/gonow-agent-landing`. Direct Phase work on `main` is forbidden.

## Evidence boundary and recovery

The archive claims architecture coverage, not behavior improvement, production validation, owner
approval, or Release acceptance. Its reversible unit is this documentation-only commit. Reverting it
leaves runtime, databases, contracts, flags, traffic, and the Phase 11 checkpoint unchanged.
