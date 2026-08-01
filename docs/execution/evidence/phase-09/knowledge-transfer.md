# Phase 9 knowledge transfer

## Responsibilities and dependency choices

Mobile owns typed Flutter orchestration, presentation, minimal active-Run storage, and default-off
routing. Agent Runtime owns Run/Event truth and control APIs. Domain and Data own authoritative
writes, version checks, audit, and outbox semantics. Security owns formal threat review; API,
Product, and SRE own independent handoff. The phase reused OpenAPI, PostgreSQL, SSE, and the existing
legacy route; it added no queue, cache, read-model service, client SQL boundary, or production
Multi-Agent runtime.

## Hardest items

Three root causes required closure. First, the repository-wide analyzer already had 109 diagnostics,
so Phase 9 froze that baseline and required zero new target diagnostics rather than hiding legacy
debt. Second, the Domain Command needed real PostgreSQL RLS and role semantics while the production
itinerary mapping was unknown; the repair used an isolated reversible schema, verified 13 cases, and
kept the production mapping blocker explicit. Third, Flutter `integration_test` selected real device
dispatch in a multi-device environment, then an exact Semantics equality oracle rejected correctly
merged accessible text; the repair used exact-byte VM fixtures and a containment assertion, then
reran the affected 10-test journey. No root cause was split into blind repeated reruns.

## Operation, observation, and recovery

Normal state is flag disabled, kill switch active, ordinary chat bypassed, and legacy itinerary
routing. Enable only in an authorized isolated environment with matching generations and the bound
contract digest. Observe stable route reason, Run ID, last event ID, typed failure, Candidate state,
expected version, and Domain Command/outbox receipt. Degrade by engaging the kill switch and keeping
durable facts. First checks follow route, compatibility, Run cursor, stream state, then adoption
transaction; the runbook contains the exact order.

## Verification and known limits

The local evidence includes generated-client idempotence, repository/store/stream/UI/flag suites,
13 Domain Command tests, 4/4 app/service compatibility pairings, three safe fallback cases, 120/120
synthetic normalized query samples, 40/40 visibility samples, and 10/10 exact-byte Flutter VM journey
tests. Mandatory skips and production writes are zero. SQLite timing is not a PostgreSQL SLA, the VM
fixture is not a physical mobile device, and the isolated command schema is not the unresolved
production itinerary mapping. Independent review and all formal/production actions remain pending.

During closeout, the first 153-row status board claimed success but failed a direct JSON round-trip:
the BOM-less PowerShell 5 load had mojibake at the Release B phase label and the aggregate lacked a
write-after-parse assertion. The reversible repair derives stable phase labels from task IDs,
special-cases the post-Phase-10 Release B task, and makes a 153-row JSON round-trip mandatory. The
affected board, Evidence, and Workset gates then passed; no task status or Catalog control changed.

## Estimate, decision, rollback, and next owner actions

The plan estimated Phase 9 cards for sequencing; no human-hour or delivery claim is inferred. The
measured implementation decision was to retain normalized reads and add no read model. Rollback
activates the kill switch, verifies flag-off and compatibility, preserves durable facts, and reverts
only Phase 9 client integration if required. API/Product/SRE must independently verify readability,
contract sync, the handoff journey, and a real-device run; Security must independently review the
threat model; Domain/Data must resolve the production itinerary mapping before formal adoption.
