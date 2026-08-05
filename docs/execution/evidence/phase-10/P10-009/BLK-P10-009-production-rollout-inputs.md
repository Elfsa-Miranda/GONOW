# BLK-P10-009: approved production rollout inputs unavailable

## Reproduction

The P10-009 local preflight and work-preflight pass at commit `5de1f2397e5ec5420041cab2827fab2d9f192100`. The task cannot reproduce its primary production assertion because the local-provisional environment has no approved cohort identifiers, production feature-flag authority, production billing/adoption ledger, independent approvals, or elapsed production observation windows. The per-gate minima of 24/48/72/120/168 hours total only 432 hours; they are necessary but do not satisfy the Release B hard constraint of at least 744 hours (31 days) across five explicit, ordered, non-overlapping windows.

## Root cause and impact surface

This is an external authorization and observation-time dependency, not a local implementation defect. It blocks only production activation of `gonow.agent.itinerary_planning.release_b`, the five production rollout gates, TASK-P10-009 acceptance, and downstream Release B acceptance/integration. It does not invalidate the locally verified rollout plan, stop rules, kill switch, cost denominator, tests, documentation, or other reversible enabler work.

No alternative local fixture can prove production users, production spend, durable adopted successes, or elapsed production windows. Treating zero observations as sufficient would violate the task card and the evidence-honesty constraint.

## Excluded paths

- Synthetic observations were rejected because they cannot satisfy a production observation claim.
- A zero-denominator success was rejected because unknown measurements must remain null or blocked.
- Direct feature-flag activation was rejected because the Agent has no production authority or approved cohort IDs.
- Skipping 1%, 5%, 20%, or 50% was rejected by the frozen cohort contract.

## Complete reversible resolution

1. Supply a valid governance-adoption receipt and independent Product, Privacy, Security, and SRE approvals bound to the exact candidate head.
2. Supply approved pseudonymous cohort IDs and an authorized feature-flag adapter/production identity.
3. Start at 1%, record audit receipts, all five risk slices, adopted-run counts, stop-rule results, and explicit offset-bearing `window_started_at`/`window_ended_at` timestamps.
4. Advance only after each gate meets both sample and individual window requirements; restart the timer on every increase or decrease, prohibit overlap, and extend the current gate until the five measured durations total at least 744 hours.
5. On any stop condition, set allocation to zero, engage the kill switch, retain the old route and all observation evidence.
6. Repeat through 5%, 20%, 50%, and 100%, then rerun P10-009 Verify, Security, Evidence, RollbackVerify, and Preflight.

## Rollback and recovery condition

Current allocation is zero and production activation is false, so rollback is already at the safe state. Recovery requires all five exact external input classes above plus a mechanically bound total of at least 744 non-overlapping hours; partial approvals, the 432-hour sum of per-gate minima, overlapping intervals, or unbound duration claims do not unblock the task.

Owner escalation: ReleaseEng to Security, Product, Privacy, and SRE. Formal status remains pending external; no production write was performed.
