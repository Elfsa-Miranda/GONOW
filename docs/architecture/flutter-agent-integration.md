# Flutter itinerary Agent integration

Status: local provisional. Production activation, independent review, real-device acceptance,
remote merge, and formal acceptance are `pending_external`.

## Scope and boundaries

Phase 9 connects only itinerary planning to the existing single-Agent API. Ordinary chat stays on
the legacy path. Flutter owns presentation, typed client orchestration, a minimal active-Run
reference, SSE projection, and explicit Candidate approval. The Agent service owns Run/Event facts,
authorization, versioned commands, fencing, and outbox persistence. PostgreSQL remains the fact
source; the client neither runs SQL nor decides tenant identity, role, approval validity, or the
authoritative itinerary version.

The OpenAPI source and generated Dart client are bound to SHA-256
`ba776e2c464ff6faf1866c7e369756368a43b5023642ac6318758e55f857b8ed`. The locked generator produced
four Dart files and a second generation produced zero diff. No Phase 9 API contract change was
needed after generation. The compatibility fixture retains all four old/new app/service pairings.

## Data and control flow

1. `AgentFeatureFlags` evaluates itinerary planning. Kill switch, disabled flag, generation
   mismatch, unavailable route, and ordinary chat all choose legacy with a stable reason code.
2. `AgentRunRepository` sends typed create, interrupt, resume, and cancel commands through the
   generated client and converts failures into public typed results without leaking raw bodies or
   credentials.
3. `ActiveRunStore` persists only schema version, Run ID, last event ID, and local version. A late
   terminal event cannot clear a newer Run reference.
4. `AgentEventStream` replays from the persisted event ID, treats HTTP 410 as terminal history
   expiry, and never converts a disconnect into cancellation intent.
5. `CandidatePreviewPanel` displays itinerary changes, evidence, warnings, and conflicts. Preview
   causes zero business writes; approval remains explicit and conflict acknowledgement is visible.
6. `CandidateAdoptionClient` calls the guarded Domain Command. The service derives authority from
   trusted context, locks the target version, consumes a capability nonce once, and commits the
   itinerary effect, audit/Event, and outbox atomically.

The repository lacks an approved production itinerary-table mapping. Phase 9 therefore proves the
command against isolated schema and records the mapping blocker; it does not guess a production
table or write production data. The measured local read-model decision is `not_applicable`, so no
cache, projection, queue, or second read fact source was added.

## Lifecycle operations

- Enable: in an authorized isolated environment, set `gonow_itinerary_agent_v1` enabled, clear the
  kill switch, supply matching nonzero client/server generations, and confirm the contract digest.
- Disable: set the kill switch or feature flag off; the legacy itinerary path remains available.
- Degrade: route compatibility, generation, availability, or replay failures to legacy and preserve
  server Run/Event facts for diagnosis. Never synthesize a successful adoption receipt.
- First checks: inspect route reason code, generations, contract digest, Run ID, last event ID,
  typed failure kind, and Domain Command/outbox receipt in that order.

## Safety and compatibility invariants

- Model output is a Candidate, never an authoritative write command.
- Preview and unapproved states perform zero business writes.
- Stale version, forged capability, replay conflict, and transaction failure fail closed.
- One accepted Domain Command produces one itinerary effect and one outbox effect; a failed
  transaction produces neither.
- Old app/old service, old app/new service, new app/old service, and new app/new service remain
  representable by source-bound fixtures; no forced upgrade or adapter deletion occurred.
- The feature defaults off with the kill switch on. No production cohort was activated.

## Evidence boundary

Local mechanical evidence covers generated-client contract tests, repository/store/stream/UI/flag
tests, 13 Domain Command tests, a 4/4 compatibility matrix, three safe fallback cases, and 10/10
exact-byte Flutter VM journey tests. These are deterministic local checks, not production traffic,
mobile-device, usability, latency, cost, or adoption evidence.
