# BLK-P10-010: P10-009 is not accepted

## Reproduction

At candidate head `ab1c198a50cc90f5aae618dc389afe011b762f44`, P10-010 Preflight returns `dependency_not_ready` with `dependency_failures=1`. P10-009 is correctly `blocked`, not `ready_for_review` or `accepted`, because no approved production rollout or complete observation windows exist.

## Root cause and impact surface

P10-010 requires the accepted P10-009 head and artifact hash. The missing prerequisite comes from the external production approval/observation dependency documented in `../P10-009/BLK-P10-009-production-rollout-inputs.md`. It blocks the Release B total-gate dossier, Phase 10 handoff/acceptance/integration, Release B PR, and later phases whose entry requires stable Release B. It does not block local runner contract work, static checks, or other reversible evidence tooling.

## Excluded paths

- Writing a NO-GO dossier was rejected because the task card still requires an accepted P10-009 input and a passing primary assertion.
- Treating the blocked P10-009 record as a local projection was rejected because only `ready_for_review` with passing mechanical gates qualifies.
- Re-running Preflight without a new P10-009 status or evidence hash was rejected because it would add no diagnostic information.

## Resolution, rollback, and recovery

Complete the recovery steps in the P10-009 blocker, obtain its independent review and acceptance, then rerun P10-010 Preflight exactly once against the new immutable P10-009 head and artifact hash. No P10-010 dossier or production action was created, so rollback is deletion of this provisional blocker evidence only. Owner escalation is ReleaseBoard to Engineering, Security, Product, and Data.
