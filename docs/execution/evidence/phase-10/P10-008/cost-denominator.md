# P10-008 cost denominator contract

## Scope

This local-provisional artifact freezes the accounting contract without claiming that production billing, adopted-success observations, or an approved budget exist. The measurement remains `blocked_pending_production_measurement` until those external inputs are available and independently reviewed.

Each observation joins on exactly `behavior_digest`, `route`, and `outcome`. Every route decision must retain its route reason. The two required route slices are `economic` and `capability`; neither slice may infer cost from the other.

## Formula

- Numerator: total cost of all attempted runs, including failed and unadopted runs.
- Denominator: count of successfully adopted tasks.
- Result: `cost_per_adopted_success = total_attempt_cost / adopted_success_count`.
- Undefined case: zero denominator produces null. It must never produce zero, infinity, or an “approved budget” comparison.

An `adopted_success` outcome requires the durable adoption record governed by the release contract. A completed run, a generated candidate, or a local test pass is not an adopted success.

## Budget decision and rollback

The budget decision is either supported by an approved budget and measured observations, or remains blocked. Current status is `blocked_pending_production_measurement`; all monetary values are null and all observation counts are zero.

If future measured cost exceeds the approved threshold, the first reversible response is routing eligible work to the `economic` tier. If that does not restore the guardrail, allocation returns to the old path. Cost records, failed attempts, and denominator records remain retained so rollback cannot improve the metric by deleting evidence.
