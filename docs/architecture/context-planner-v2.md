# Context Planner V2 runtime boundary

Context Planner V2 is a default-off itinerary Worker candidate. Production composition requires `GONOW_CONTEXT_PLANNER_V2_ENABLED=1` and an exact `GONOW_CONTEXT_PLANNER_V2_POLICY_SHA256` match. The claimed Run's existing Behavior Manifest `context` component must carry the same digest. An enabled mismatch fails before the model call; it never falls back to raw prompt concatenation.

The optional stage runtime additionally requires `GONOW_CONTEXT_STAGE_RUNTIME_V2_ENABLED=1`. It executes one in-process sequence:

```text
INTAKE → PLAN → EVIDENCE → COMPOSE → VALIDATE → COMPLETE
```

- INTAKE validates the authorized structured input and builds a content-addressed Task Contract.
- PLAN derives a deterministic JSON Plan Intent. It does not call a model.
- EVIDENCE invokes the existing authorized knowledge provider. Retrieval is not counted as a Tool Gateway call.
- COMPOSE is the only logical model invocation for a non-segmented request.
- VALIDATE performs typed schema, business-rule, and Claim-availability checks.
- COMPLETE projects the immutable Candidate only after validation succeeds.

Each transition uses the fixed graph guard and atomic multi-budget limiter. The in-process stage snapshot contains only `StateReference` values and monotonic counters; it contains no Prompt, Evidence text, model response, transcript, or reasoning. Provider-reported model tokens are charged before entry to VALIDATE, while a conservative Context-window/output reservation is checked before the model side effect.

This stage sequence is not a durable per-stage checkpoint protocol. A process failure during the sequence is recovered through the existing Job lease/fencing and Job-level recovery boundary. No Phase 13 database migration or new durable event schema is introduced by this runtime.

Rollback is composition-only: leave both switches disabled, or disable the stage-runtime switch to retain the PR1 Compose-level planner path.
