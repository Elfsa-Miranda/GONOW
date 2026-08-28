# Phase 12 A/B/D planning-review disposition

## Result

The review correctly identified the main gap: the three dormant packages had strong prose architecture
but did not yet freeze a machine-checkable activation contract or behavior-measurement plan. The
hardening adopts that diagnosis while preserving the approved meanings of stable CT IDs, the single
Phase 12 `TASK-P12-089`, and the formal XOR boundary.

No candidate is selected by this review. P12D remains a credible first-choice hypothesis because its
fault boundaries are mechanically testable, but `selected_write_entry=none` and the Release C XOR
record remain unchanged until real trigger evidence exists.

## Recommendation-by-recommendation decision

| Review recommendation | Decision | Reason and resulting contract |
|---|---|---|
| Add CT-001/002/011 to P12B | Refined, not copied | CT-001/002 are stable Run-creation contracts and CT-011 is parallel Multi-Agent branch budget semantics. They are not renamed. P12B replays inherited Release B CTs and defines namespaced `P12B-CR-*` reservation/concurrency cases. |
| Add CT-001/002/005/006 to P12D | Refined, not copied | Those stable IDs cover Run and Tool boundaries. P12D keeps them as inherited regressions and defines `P12D-DC-*` command/outbox/crash cases. |
| Add P12B/P12D 089 tasks | Rejected as separate formal tasks | AGENTS.md §14 requires one 089 per Phase, and `execplan.md` already has `TASK-P12-089`. All three candidate DAGs now hand off explicitly to that task; no candidate-specific 089 is invented. |
| Add machine-readable file allowlists and required changes | Accepted with fail-closed dormant semantics | Each package has a proposed execution contract. TASK 010 has exact evidence-only paths; 020-060 have an explicit empty allowlist and `must_bind_before_activation`. Formal work cannot start until an approved execplan/Catalog revision supplies literal paths. |
| Add STAR pre-registration | Accepted and strengthened | Each package freezes metric roles, formulas, numerator/denominator, direction, bindings, statistics, missing/outlier rules, redlines, decision rule and no-claim boundary. Dormant unknowns remain explicit pending bindings rather than fabricated values. |
| Make duplicate writes P12D primary | Reclassified | Duplicate formal write count is a hard redline. P12D must select one root-cause primary from a closed profile after one write entry is named and before candidate results are unblinded. |
| Make P12B quality-floor violation diagnostic | Reclassified | Quality floor is a zero-tolerance redline. Retry/fallback cost amplification is the causal diagnostic; quality-qualified success is the non-inferiority guard. |
| Use a 1 pp P12B quality margin | Retained only as Initial Hypothesis ceiling | A universal margin could be underpowered or unsafe by stratum. TASK-P12B-010 must justify and owner-freeze the actual margin before measurement, with every critical stratum passing. |
| Add trigger evidence schema | Accepted | `phase12-trigger-evidence-v1` requires dataset SHA, denominator, exclusions, estimator, uncertainty, threshold source, package-specific fields and a positive/negative decision. No fake live trigger file is created while dormant. |
| Add Release B entry regression | Accepted | Every selected 010 must bind the exact accepted Release B manifest and replay mandatory implemented CT/gates, kill/replay, cross-tenant, flag-off digest, Phase 4 E0 and legacy journeys with no skip/xfail. |
| Add P12A injection counterexamples | Accepted and expanded | Direct, indirect RAG when applicable, multilingual and encoded/obfuscated cases are required; `retrieved_injection_executed_action_count=0` is a hard redline. |
| Add ADR trigger references and threat hooks | Accepted | Plans and ADRs cite AGENTS.md §16.1 items and require package threat deltas to bind the Phase 12 review before security-boundary work. |

## STAR design rationale

The primary, diagnostic and guardrail have different jobs and cannot be interchanged:

- A primary must quantify the end value attributable to the candidate under a comparable baseline.
- A diagnostic must explain the causal mechanism, not merely repeat a pass/fail safety boundary.
- A guardrail prevents the candidate from improving the primary by degrading another required outcome.
- A redline is an exact fail-closed safety/integrity boundary and is never averaged or traded off.

P12A therefore measures paired task-success net gain, not merely recall. P12B counts all failed,
retried and fallback cost in cost-per-success and treats zero successful tasks as undefined/fail closed.
P12D refuses to preselect an outcome before a write entry exists and forbids a composite that could
hide duplicate, unauthorized or divergent writes.

Measurement is paired or stratified, threshold/power/exclusions are frozen before unblinding,
candidate-caused missing runs are failures, and synthetic fault injection is labelled mechanics-only.
When comparability or evidence is missing, the only valid Phase 12 STAR state is
`not_applicable + reason=measurement_pending:<exact_missing_evidence>`.

## Scope and rollback

This hardening changes only planning, schema, validator and evidence documents. It creates no runtime,
public contract, migration, provider, allocation, specialist branch or production write. Reverting the
hardening commit restores the previous dormant plans without data or runtime rollback.
