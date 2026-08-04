# Release C selection architecture

archive_mode: local_provisional
formal_selection_status: local_provisional_selected
selection_cycle: p12b-local-provisional-20260804
selected_candidate: 12B
selected_count: 1
formal_none_decision: false
design_ready_count: 1
runtime_change_count: 0
public_contract_change_count: 0
schema_change_count: 0
production_write_count: 0
multi_agent_implementation_count: 0

## Decision boundary

The user selected 12B as the only candidate for this new local execution cycle. The repository records
that XOR decision and the executable P12B task package; it does not fabricate the independent owner
receipts needed for formal acceptance, remote integration, or production use. The package is
therefore `local_provisional_selected`, and its terminal local state is `ready_for_review` rather
than `accepted`.

The earlier P12D local-provisional implementation remains immutable historical evidence on the
landing branch. It is not selected, modified, or allocated in this cycle. Calling P12D dormant here
means dormant for new work and production allocation; it does not erase its already-proven local
mechanism or its `ready_for_review` records.

The deployed architecture target therefore remains one Agent codebase with two processes,
`agent-api` and `agent-worker`. PostgreSQL remains the durable source of truth. The existing static
Tool registry remains internal. No Redis, queue, dynamic MCP marketplace, extra coordinator, or
new production boundary is introduced.

## XOR candidate map

| Candidate | Dormant architecture covered | Trigger still required | Present disposition |
|---|---|---|---|
| 12A explicit structured Memory | consent, provenance, conflict, deletion/export, restore guard | a future independent XOR cycle | unselected; no implementation or allocation |
| 12B deterministic cost router | certified-route policy, quality floor, budget ledger, fallback | direct user selection for this independent local cycle | selected locally; production allocation remains zero |
| 12C production Multi-Agent | no framework design is opened by this archive | a separately approved positive trigger and full XOR cycle | explicitly deferred; no ADR, task plan, branch, runtime, or allocation |
| 12D one Domain Command migration | principal, approval, CAS, idempotency, outbox, compatibility | prior independent local cycle | historical `ready_for_review`; dormant for this cycle and production allocation remains zero |

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

This cycle activates only the existing itinerary-generation server route. The baseline is the
current fixed Gemini 3.1 Flash-Lite route; the candidate is the fixed DeepSeek V4 Flash non-thinking
JSON route. Both remain inside the existing Worker model boundary. No client credential, central
gateway, routing LLM, new process, dynamic provider market, or public Candidate contract is added.
Production traffic, production quality, provider data-use approval, and a four-week production
window remain `unknown/pending`; local fake/replay and at most the separately budgeted live
calibration cannot prove those facts.

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

## 12D: selected single write entry

Repository evidence selected exactly
`flutter:ItineraryProvider.updateItineraryBasicInfo:user_itineraries`. The tracked legacy ordering
publishes local/cache success before its resource-id remote update and has no expected-version CAS or
durable receipt lookup. No claim is made about production traffic, incidents, schema equivalence, or
RLS outside the repository.

The selected internal command admits only a closed Basic Info payload and server-derived principal,
tenant, role, approval, and purpose. The database package adds dormant command attempt, receipt, and
outbox tables in the `domain_command` schema, with FORCE RLS and no guessed business-table DDL. The
handler reauthorizes and applies the existing business mutation, receipt, and logical outbox event in
one transaction. Stale version, idempotency collision, permission denial, and cross-tenant attempts
have zero formal side effects. A lost response after commit converges through lookup of the original
receipt; it never triggers an automatic legacy fallback.

Flutter routes only Basic Info through the new client when the independent flag is on and its kill
switch is inactive. Other itinerary writers remain on the compatibility path. Turning the flag off
or activating the kill switch sends new intents to the old authorized writer and retains durable
receipts/outbox rows for audit and recovery.

The controlled RealPG profile uses one fixed fixture, seed, workload hash, 10,000 legacy intents, and
10,000 candidate intents. The stale-conflict partial-effect rate changed from 10,000/10k to 0/10k;
all pre-registered redlines were zero. The claim scope is `local_controlled_mechanism`, production
improvement is false, and production measurement remains pending.

## 12C: Multi-Agent explicitly deferred

Phase 8 produced a credible synthetic `none` result and did not open a production Multi-Agent
candidate. The current user direction is also to finish the high-quality single-Agent architecture
first. Consequently this archive creates no P12C ADR or task plan, no coordinator or specialist
roles, no shared-branch runtime, and no production allocation. Any later consideration must start a
fresh formal XOR cycle and prove a benefit that a single Agent plus deterministic tools, RAG,
Memory, or routing cannot deliver at lower risk.

## Remaining formal activation sequence

1. Bind an accepted Release B head and a stable, immutable evidence window.
2. Calibrate numerator, denominator, exclusions, uncertainty, quality, latency, cost, and redlines.
3. Independently review the P12B policy, fixed provider eligibility, controlled comparison, rollback,
   and exact candidate/merge object IDs; do not rewrite local self-review as owner approval.
4. Keep production allocation at zero until formal governance, real schema/RLS inventory, rollout
   authority, monitoring, and rollback ownership are available.
5. Permit only the selected P12B package to proceed. Memory, Multi-Agent, or additional Domain
   Command work requires another XOR cycle.

## Evidence boundary and recovery

The repository may prove capability existence and a controlled local comparison. It does not prove
production improvement, provider production eligibility, owner approval, or Release acceptance. The
reversible runtime unit is the default-off P12B policy and fixed provider adapter; rollback sets
allocation to zero, bypasses cost routing, restores the prior Gemini policy digest, and retains
content-free cost and reservation receipts.
