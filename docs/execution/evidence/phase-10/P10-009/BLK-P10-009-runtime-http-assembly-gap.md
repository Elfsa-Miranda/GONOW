# BLK-P10-009 runtime HTTP assembly gap

## Plain-language summary

The compressed certification probe found that the service process starts but exposes no GoNow API route. The Flutter “create” journey also uses an in-memory Run identifier rather than creating a durable Run through HTTP. The safest next action is a flag-off-compatible repair that assembles the already implemented route factories, adds the missing typed Run-start contract, and replaces the fake end-to-end claim with an HTTP/PostgreSQL journey before certification resumes.

## Reproduction

- Candidate: `1c4914cb6a1986fcb4f9d3e6d1a4eaadbecbe3a6`.
- Environment: repository-locked Python `3.13.9`; project dependencies supplied with the locked `uv` and explicit locked interpreter.
- Command shape: import `app.api.main.create_app`, create the app, and enumerate `app.routes`.
- Observed application routes: `/openapi.json`, `/docs`, `/docs/oauth2-redirect`, and `/redoc` only.
- Static corroboration: no tracked `agent-service/app/**` file calls `include_router(...)`.
- Contract corroboration: `contracts/openapi/agent-api.yaml` contains contract, events, resume, and cancel paths but no Run creation path.
- Client corroboration: `AgentRunGateway` and `AgentRunRepository` contain contract, resume, and cancel operations only.
- Test corroboration: `integration_test/itinerary_agent_journey_test.dart` labels a journey `create -> ...`, but it seeds `ActiveRunStore` directly and uses `_JourneyRepository`; no HTTP server, PostgreSQL Run, Worker, or provider is involved.
- Worker corroboration: `app.worker.main.WorkerRuntime` waits for shutdown only; it never claims or executes a durable Job even though claim, lease, checkpoint, reconciler, graph, and Candidate components exist independently.
- Durability corroboration: `ResumeCapabilityStore` is a protocol with test-only memory adapters; no tracked PostgreSQL adapter or migration persists one-use resume capabilities.
- UI corroboration: `ItineraryScreen.onOpenAgentPlanning` has no tracked caller, so the Agent entry is always treated as unavailable even if the flag generations otherwise match.
- Adoption corroboration: the typed Domain Command and Flutter transport exist, but no Agent API adoption route is mounted and the formal itinerary/activity table adapter remains an explicitly unknown production fact.

The first environment attempt used the BOOT interpreter without project dependencies and failed on `uvicorn`. A second attempt allowed `uv` to auto-select Anaconda and failed module resolution. Those are separate provisioning errors, not the product finding. The final reproduction explicitly bound the locked interpreter and project environment and succeeded, producing the route list above.

## Root cause and impact surface

The Phase 2 process skeleton intentionally left public routes unmounted, while later phases added isolated route factories, persistence services, contracts, generated Dart methods, and fake integration tests without adding a composition root. Phase 9 also omitted a typed Run-start operation from OpenAPI and Flutter repository scope. Contract/unit tests validated the pieces independently, so the missing assembly was not observable until a real entrypoint probe.

The same incremental pattern affected the Worker and resume path: durable primitives were implemented and tested in isolation, but no production composition root joined claim → fence → graph/checkpoint → event/Candidate → terminal transition, and no durable capability adapter was supplied. The Flutter flag was wired to an optional callback but no application composition supplied that callback. These are one root cause—missing executable composition and executable end-to-end acceptance—not four unrelated defects.

Affected surfaces:

- production `agent-api` reachability for health, contract, events, resume, and cancel;
- creation and durable enqueueing of a Run;
- Worker claim/execution and terminal convergence;
- one-use resume capability durability across process restart;
- Flutter start/resume/cancel/SSE journey;
- Candidate adoption through a real HTTP/Domain Command/formal-table adapter;
- P10 C2 API latency/live-route measurements;
- P10 C4 recovery/soak against the real API/Worker boundary;
- P10 C5 kill-switch and rollback drill;
- P10-010 owner-only canary.

Unaffected and retained:

- old Flutter planning path;
- default flag-off/kill-switch behavior;
- typed route/service unit contracts;
- existing database migrations and evidence;
- no production write or external allocation occurred during reproduction.

## Reversible repair plan

1. Freeze a public API ADR and additive OpenAPI change for typed Run creation; preserve all existing error and schema compatibility.
2. Add one explicit API composition root that mounts health, contract, Run-start, SSE, resume, and cancel routes with injected authentication, rate limit, persistence, capability, event, and audit dependencies.
3. Implement Run-start as an idempotent durable transaction: authenticated tenant/principal context, behavior digest pin, request hash/idempotency key, Run row, Job row, and audit/event linkage. It must not call a model or write a formal itinerary.
4. Add the minimal durable resume-capability adapter and a bounded Worker composition root that claims one fenced Job, executes only the certified itinerary graph/provider/tool boundary, checkpoints, emits safe events/Candidate, and reaches one legal terminal state.
5. Add the typed, owner-scoped Candidate-read route while keeping formal Candidate adoption unavailable unless an exact production schema/RLS/CAS inventory and Domain Command adapter are supplied; use task-owned tables only for local proof.
6. Regenerate the Dart client, extend `AgentRunRepository`, and connect a real itinerary Agent screen/callback while the default flag remains off.
7. Replace the fake “create” claim with an HTTP + task-owned PostgreSQL + Worker integration journey. Retain focused fake tests for weak-network determinism, but label them as fake.
8. Run the affected OpenAPI, auth, RLS, Run/Job, checkpoint, SSE, resume/cancel/adopt, Flutter, legacy-route, and phase-entry regressions before returning to C1–C5.

Rollback is one non-force revert of the repair commits plus allocation `0`; the old path remains the default throughout. No migration rollback or production data deletion is required.

## Recovery condition

This blocker is closed only when the built application route table matches every OpenAPI operation, the HTTP/PostgreSQL journey creates exactly one durable Run and Job under retry, SSE/resume/cancel remain tenant-scoped, Flutter can start and recover that Run, and all affected regressions pass with zero skip/xfail. Until then only P10-009 shards independent of the HTTP/live boundary may proceed.

## 2026-08-02 repair evidence update

The executable-composition portion is now repaired on the Phase 10 candidate, without production allocation:

- OpenAPI `1.1.0` adds typed, idempotent `POST /v1/runs` and owner-scoped `GET /v1/runs/{run_id}/candidate`; generated Dart is bound to spec SHA-256 `bc067228d99196391b9a0cdb9c687fadb5b0c2947418afe8687eca53e78e3fc0`.
- PostgreSQL migration `p10_001_runtime_composition` adds forced-RLS Job inputs, one-use resume capabilities, and Candidates with least-privilege API/Worker/command-service grants.
- The Worker now claims one tenant-scoped Job, enforces fencing, persists Candidate and terminal events atomically, discards Candidate on cancellation, and rejects a reclaimed Worker’s late write.
- Flutter now has a real repository/start/read/cancel surface and an application entry. It remains fail-closed by default and accepts only HTTPS or loopback HTTP configuration.
- Focused Python contract/real-PostgreSQL regression passed `44/44`; affected Flutter contract/repository/stream/config/screen regression passed `58/58`.
- The cross-language certification journey passed in `3.21s`: locked Dart repository/generated client -> loopback HTTP API -> real PostgreSQL -> independent Worker -> strict Candidate parser. Candidate Run and Behavior identities matched.
- The full Python regression initially found four stale P09/Phase-2 assertions after `595` passes. All four shared the same contract-evolution root cause; the assertions now prove old-service fallback, new-service activation, and the exact additive public route surface. The affected set passed `11/11`.
- The repaired candidate then passed the complete Python regression `599/599` in `52.99s`, with zero skip, xfail, or retry.
- The complete Flutter VM regression passed `106` tests with zero failure; four pre-existing live-network tests remained explicitly skipped and are not counted as certification evidence.
- Repository-owned OpenAPI regeneration check passed with zero breaking changes and exact spec SHA-256 `bc067228d99196391b9a0cdb9c687fadb5b0c2947418afe8687eca53e78e3fc0`; Python `compileall` passed for application and test sources.
- A targeted Dart analysis introduced no error or warning. It retained two pre-existing `use_build_context_synchronously` info findings in the unchanged deep-link join handler; they are baseline diagnostics outside this repair's behavior surface.

Remaining recovery items are deliberately not relabelled as passed: formal Candidate adoption still needs the exact business schema/RLS/CAS adapter; real model-route calls/cost receipts need provider configuration and budget; Android device/process-kill coverage needs three target API environments; and the final owner-only canary needs a scoped non-production/production endpoint and owner identity. Those conditions block only the corresponding C2/platform/canary assertions while C1/C3/C4/C5 engineering continues.
