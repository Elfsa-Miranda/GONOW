# ADR-P10-002: Repair the executable Agent runtime composition

- Status: `provisional_implemented_pending_p10_certification`
- Decision date: 2026-08-02
- Decision owner: repository owner directive authorizing automated repair and completion
- Implementer: Codex
- Scope: additive Run-start/Candidate-read API, API/Worker composition roots, durable resume capabilities, and Flutter Agent entry
- Trigger: `BLK-P10-009-runtime-http-assembly-gap`
- Acceptance: personal automated gates on one exact candidate; no claim of independent human review

## Context

The Release B certification probe proved that the repository contained many typed runtime components but no executable composition. `create_app()` exposed only fail-closed routes, the Worker only waited for shutdown, no PostgreSQL resume-capability adapter existed, OpenAPI and Dart had no Run-start operation, and the Flutter Agent callback had no caller. Existing “end-to-end” tests used in-memory fakes and therefore could not detect these gaps.

This is a public API, process-boundary, and persistence repair. It therefore requires an ADR even though it restores the already approved target architecture rather than adding a new product capability.

## Decision

Implement a single explicit composition root for each approved process:

- `agent-api` authenticates requests, derives tenant/principal context, applies lifecycle gates, pins an immutable Behavior Package, creates/replays a Thread/Run/Job transaction, emits safe durable events, and serves contract/SSE/resume/cancel and owner-scoped Candidate-read endpoints. It never invokes a model or Tool.
- `agent-worker` claims a PostgreSQL Job, holds a fencing token, executes the bounded single-agent itinerary path through certified model adapters, persists only a typed Candidate/evidence references, emits events, and converges the Run to one legal terminal state. It never writes a formal itinerary.
- Flutter adds a typed Run-start method and a real Agent planning entry. The existing route remains the default: flag disabled, kill switch active, generation mismatch, missing configuration, or any dependency failure routes to legacy.

`POST /v1/runs` is additive. Its request is structured and bounded; it carries a client-generated thread UUID, idempotency key, versioned itinerary request, and no provider credential. The API computes the canonical request digest, stores a task-owned durable Job input under tenant RLS, and enqueues exactly one Run/Job. Replay with the same key and digest returns the same Run; the same key with a different digest fails closed.

Durable resume-capability storage persists only a token digest. Every capability is bound to tenant, principal, Run, interrupt, command hash/version, expiry, and one CAS consumption time. Cleartext is returned once and never logged. A consumed capability can advance only its exact owner-scoped `waiting_input` Run, and transactionally creates one follow-up Job plus a durable `resuming` event; stale, active-job, or binding conflicts fail closed.

The API composition requires an HTTPS issuer, an exact JWKS host allowlist, the pinned PostgreSQL driver, and a byte-hashed Behavior manifest whose digest must match a qualified database deployment. Startup warms JWKS and proves database/clock reachability before readiness. The API and Worker use explicit least-privilege database roles for every transaction.

Candidate adoption remains unavailable until it can go only through the existing typed `ItineraryAdoptHandler` and Domain Command repository. The production adapter for formal itinerary/activity tables remains fail-closed until an exact schema/RLS/CAS inventory is supplied or a separately approved repository-owned formal schema migration is adopted. Task-owned synthetic tables may prove the command locally but are never production evidence.

The repair is additive. No existing table is destructively changed, no old client path is removed, and no production allocation is enabled. New tables receive forced RLS, least-privilege grants, indexes, retention/deletion metadata where applicable, migration/restore tests, and forward-fix rollback semantics.

## Options considered

| Option | Safety/data | Compatibility | Cost/operations | Decision |
|---|---|---|---|---|
| Keep isolated components and certify contracts only | Cannot prove HTTP, Worker, restart, or tenant behavior; would create a false Release claim | No code change | Lowest immediate work, highest release risk | Rejected |
| Assume an untracked/private backend supplies composition | Identity, code, schema, and evidence are unknown | Impossible to reproduce | Operationally opaque | Rejected |
| Mount routes but keep fake Worker/UI | Improves reachability but not a usable or recoverable product | Partial | Leaves canary impossible | Rejected |
| Add explicit API/Worker/Flutter composition with PostgreSQL truth | Enforces auth, RLS, idempotency, fencing, audit, and restart behavior | Additive; flag-off preserves old path | More engineering, mechanically certifiable | Selected |

## Security and privacy

- Credentials remain server-side secret-provider values and are never accepted in request bodies.
- Request bodies reject unknown fields and size/count violations before persistence.
- Tenant and principal come only from verified identity, never client body fields.
- Job inputs and resume capabilities are tenant scoped with forced RLS; Worker/API roles get only the operations they require.
- Events, logs, checkpoint state, and evidence exclude prompt/response/reasoning/credential bodies.
- The API process cannot import/invoke model or Tool adapters; the Worker role cannot write formal domain tables.
- Idempotency and capability conflicts use stable non-oracular errors.

## Data and compatibility

The migration is additive and forward-fix only. Existing OpenAPI operations and Dart method signatures remain stable. Older clients ignore the new Run-start operation. New clients remain flag-off compatible with old service/legacy planning. New data is retained during rollback so old paths can continue reading existing business data; runtime cleanup follows the declared retention/deletion command rather than ad-hoc deletion.

## Performance and cost

Run-start performs one bounded transaction and no external provider call. Worker concurrency, attempts, model tokens, tools, deadline, and cost are capped by the Behavior Package and certification manifest. Backpressure returns a stable retryable response; it does not create partial Run/Job rows. P10 measures API p95 confidence bounds, provider receipts, cost per adopted success, resource slopes, and backlog recovery before allocation.

## Rollback

Keep allocation at zero and the Flutter kill switch active. Revert the additive code commits non-force; leave additive tables/data in place until an approved forward cleanup migration, because dropping them could destroy recoverable Runs. Restore the previous process entrypoints and verify contract/legacy paths. Evidence and failed Run records remain append-only.

## Acceptance evidence

Acceptance requires one clean candidate with:

- route-table-to-OpenAPI equality;
- HTTP authentication/tenant negative matrix;
- task-owned PostgreSQL migration, RLS, idempotent Run/Job, capability replay/expiry, fencing, checkpoint, event, cancellation, and restore tests;
- API + Worker process restart and kill-point tests;
- generated Dart digest and real HTTP journey;
- default flag-off and all legacy journeys green;
- P10 C1–C5 plus owner-only canary, zero redlines, and automatic attestation.
