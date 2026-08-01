# Validation error and degradation contract

This Phase 7 contract is local provisional. It defines stable machine-readable codes emitted by the
typed validation package; it does not add a public HTTP endpoint or authorize a formal write.

Consumers must branch on `error_code`, never on localized text. Unknown future codes must render a
safe generic message, preserve the candidate for user inspection, and avoid automatic approval.
Private exception detail, payload text, Prompt, secret, PII, and reasoning are not contract fields.

## Constraint codes

| Code | Classification | Consumer action |
|---|---|---|
| `constraint.fact_missing` | unverified | Request or refresh evidence |
| `constraint.time_outside_window` | hard/warning by declared priority | Ask user to edit time or candidate |
| `constraint.commute_unverified` | unverified | Obtain duration and travel mode |
| `constraint.commute_exceeded` | hard/warning | Edit route or declared limit |
| `constraint.opening_hours_unverified` | unverified | Refresh sourced opening-hours evidence |
| `constraint.venue_closed` | hard/warning | Replace venue or time |
| `constraint.budget_unverified` | unverified | Obtain currency and total |
| `constraint.budget_exceeded` | hard/warning | Edit budget or candidate |
| `constraint.preference_unverified` | unverified | Confirm preference match |
| `constraint.preference_unmet` | hard/warning | Edit candidate or preference |

## Evidence codes

`evidence.repository_unavailable`, `evidence.unverified`, `evidence.stale`,
`evidence.conflicted`, and `evidence.payload_invalid` map respectively to a fail-closed Evidence
Gate decision. Only a decision with no reason code and status `verified_current` is current verified
evidence. A successful transport is not sufficient.

## Repair codes

`repair.candidate_items_required`, `repair.duplicate_path`, `repair.path_not_allowed`,
`repair.item_not_found`, and `repair.field_not_found` reject the proposed patch. They are not
retryable without changing the proposal. A round limit or no-progress stop is represented in the
typed repair outcome; unresolved original conflicts remain visible.

## Solver codes

`solver.completed` is optimized success. `solver.disabled`, `solver.not_needed`,
`solver.soft_timeout`, `solver.hard_timeout`, and `solver.child_failed` are typed degradations with
a valid fallback. Shape, duplicate-item, duration, deadline-order, and trigger validation failures
must be fixed by the caller. No solver code authorizes a Domain Command.

## Versioning and rollback

The JSON Schema is `contracts/errors/validation-error.schema.json` version `1.0`. Additive codes
require synchronized docs and consumer unknown-code coverage; removal or semantic reassignment
requires an ADR and compatible version transition. Disable solver use for solver-only rollback;
route around the Phase 7 package for full rollback while preserving evidence and candidates.
