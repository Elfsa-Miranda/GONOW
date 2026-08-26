# STAR: stage-aware itinerary runtime

Claim type: `mechanism_validation`

## Situation

The repository contained a tested six-stage graph and budget limiter, but the production itinerary Worker bypassed them. The available durable State type also required UUID identities that the claimed Job does not carry, so directly instantiating it would have fabricated tenant or Behavior release identity.

## Task

Make the fixed INTAKE → PLAN → EVIDENCE → COMPOSE → VALIDATE → COMPLETE order the real default-off Worker candidate, centralize stage Context policies, charge actual model use, and preserve the existing Job-level recovery truth.

## Action

- Added a canonical content-addressed Task Contract and deterministic JSON Plan Intent.
- Reused the fixed graph, atomic multi-budget limiter, `BudgetSnapshot`, and `StateReference` through a reference-only in-process stage snapshot with stage-owned deltas.
- Added explicit stage Context policies whose complete budget/artifact contract changes the Behavior-bound policy digest.
- Kept authorized RAG retrieval outside Tool-call accounting and retained exactly one logical model invocation in COMPOSE.
- Moved staged business/Claim validation after entry to VALIDATE and Candidate projection after entry to COMPLETE.
- Added low-cardinality stage metrics and negative boundary tests; documented that durable per-stage resume is not delivered.

## Result

The staged integration matrix passed 8/8. The success trace entered all six stages in order, made one model gateway call, charged the reported 50 input plus 30 output tokens before VALIDATE, and charged zero Tool calls for one authorized provider retrieval. Six stage-specific Context decisions were recorded. Unknown constraint, token/deadline, provider, model, validation, invalid-transition, forbidden-delta, and no-progress cases stopped before their prohibited later side effects. E0 remained 8/8; the non-database unit partition passed 317 tests and the non-database/non-stale contract partition passed 224 tests.

This is a local mechanism claim, not durable per-stage recovery, online latency, or production reliability. The task-local toolchain blockers were subsequently resolved in Phase 13: isolated PostgreSQL/pgvector was provisioned, the wall-clock-sensitive P12B tests were made deterministic without relaxing production freshness checks, and official full CI passed. Ruff/mypy are not repository CI dependencies; the official quality gate uses `tests/ci/test_quality_gate.py`.
