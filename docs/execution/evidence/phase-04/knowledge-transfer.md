# Phase 4 knowledge transfer

## Responsibilities and dependency choices

`app/runtime` owns typed checkpoint-safe state, context, Candidate, and Behavior resolution.
`app/graphs` owns the one bounded planning path. `app/models` and `app/tools` own certified
model routes and the static typed tool boundary. `app/validation` owns claims, citations,
schema enforcement, and repair stopping. PostgreSQL Behavior release/pointer records remain
the release truth established in Phase 3. No Redis, queue, MCP, second agent, or new production
dependency was introduced.

## Hardest items

1. The Behavior resolver had to bind eleven component digests while preserving old-Run pins
   across a deployment-pointer rollback and generation race.
2. The E0 evaluator had to prove read-only dataset/scoring identity while separating repeatable
   semantic hashes from observed latency, and label all results as offline synthetic.
3. The gate runner required root-cause repairs for an unhydrated BOOT interpreter, a frozen
   Candidate pointer mismatch, legal E0 value domains, and false-positive static scanning.

Each item has a reproduction, reversible repair, and affected regression in its task evidence.

## Operations must know

Keep the itinerary Agent flag off unless a qualified Behavior release is deployed. Flag-store
failure preserves legacy itinerary; legacy chat/import/Auth/fallback never enter Agent routing.
Never mutate a release or an existing Run pin. Roll a deployment pointer back with generation
CAS, then verify only new Runs resolve the previous digest. Unknown tool/schema/evidence,
budget exhaustion, or no-progress fails the affected action closed. Do not log prompt,
response, reasoning, secret, PII, or raw tool payload bodies.

## Estimate comparison

The plan estimated each implementation card independently in person-days. Local automated
execution completed the mechanical candidate and regression evidence in one continuous run,
but this is not comparable to owner review, production integration, traffic observation, or
operational readiness. Those external activities remain unknown and are not claimed as saved
time or completed work.

## Handoff verification

The local handoff reruns typed state/Graph/context, model/tool, evidence/Candidate, Behavior
pin, legacy bypass, and E0 journeys with no skips or xfails. The receipt records the exact
test count and hashes. Because the implementer performs this local run,
`reviewer_is_implementer=true` and independent Eval/Security/Product handoff remains
`pending_external`; local success is not formal acceptance.
