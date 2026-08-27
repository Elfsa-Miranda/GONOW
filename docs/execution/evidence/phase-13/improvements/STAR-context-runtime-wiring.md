# STAR: Context Planner runtime wiring

Claim type: `mechanism_validation`

## Situation

The itinerary Worker built model prompts directly from structured input and every authorized RAG Evidence item. The existing Context Compiler had no production caller, and output Claim authority was therefore derived from retrieval rather than from the bounded model input.

## Task

Introduce a reversible, Behavior-bound Context Planner candidate that is the sole model-input source when enabled, preserves the exact legacy prompt path when disabled, and prevents omitted Evidence from remaining citable.

## Action

- Added typed Context artifacts, budget envelope, policy, request, decision, deterministic digest, and stable failure contracts.
- Made compiler required kinds policy-specific so initial Compose does not require a pre-existing Itinerary.
- Bound candidate activation to an explicit default-off composition switch plus the exact Behavior Manifest `context` component digest.
- Built enabled prompts only from compiled Working Context and derived output Claim authority from the same included Evidence set.
- Added bounded decision metrics and tests for policy mismatch, tokenizer failure, required overflow, duplicate artifacts, omitted Claims, feature-off identity, and raw-content telemetry canaries.

## Result

The focused gate passed 64 tests. In the integration fixture, two of three authorized Evidence items fit a 758-token Working Context budget; the third was absent from the model prompt and could not be cited. Three repeated plans produced the same decision digest, the disabled prompt equaled the legacy prompt builder output, enabled and disabled candidates were equal for the frozen model output, and E0 remained 8/8.

This is a local deterministic mechanism claim. It does not claim online token savings, production reliability, or a complete repository-wide gate. Database-backed tests could not run because the local locked pgvector provisioning prerequisite is absent; Ruff and mypy are also absent from the locked project, and the unrelated P12B price snapshot is stale.
