# Phase 1 knowledge transfer

## Responsibilities and boundaries

Flutter retains presentation, user edit buffers, manual Candidate import, Auth, local cache, and
compatibility fallback. The future `agent-api` verifies identity and owns the control plane;
`agent-worker` owns bounded model/tool execution; a later Domain Command owns confirmed CAS writes.
Phase 1 authorizes none of those future runtime capabilities.

## Dependency choices

No runtime dependency was added. The contract uses JSON Schema plus an explicit YAML boundary and
the fixtures use the existing Flutter test toolchain. This keeps Phase 1 reversible and avoids
claiming an HTTP/OpenAPI service before Phase 2. The 1.4.0 guidance bytes remain bound to the sealed
BOOT manifest even though the original source path later drifted to a different draft version.

## Hardest items

1. Separating importability from write authorization: even a hard result remains recoverable as a
   visible draft while every formal-write field stays false.
2. Freezing compatibility without extending legacy model code: chat/import/Auth/fallback remain,
   but the only future planning seam is a separate, default-off service boundary.
3. Making architecture completeness countable: all 39 explicit hard-constraint markers map to a
   phase/task and either a numbered CT or an explicit contract-only disposition.

## Operations

Start with `docs/runbooks/legacy-fallback.md`. Confirm the affected domain and the default-off flag,
preserve original input, then run `flutter test test/validation_semantics_test.dart`. A failure must
not restore client-direct provider access or assert a cloud write. Production schema/RLS/grant facts
and independent approval remain external pending boundaries.

## Estimate and handoff verification

Plan estimates are capacity ranges, not elapsed-time or personnel claims. Local replay loads all 8
synthetic fixtures and passes 3/3 tests with no skips. The documentation links the enable, disable,
degraded, and first-check paths. A non-implementer replay is still pending, so this is a
`ready_for_review` candidate rather than accepted work.
