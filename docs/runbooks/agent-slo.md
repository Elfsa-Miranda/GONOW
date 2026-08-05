# Agent service SLO policy

## Status and evidence boundary

All values in `ops/alerts/agent-slo.yaml` are initial hypotheses, not production baselines or promises. GoNow has no approved 30-day Release B production sample yet. SRE must not relabel an objective as calibrated until at least 30 observation days and 500 successfully adopted runs are available, the denominators are reproducible, and SRE, Product, and Security approve the change.

## SLI and initial-objective map

| SLI | Initial objective | Window | Owner | Required metric |
|---|---:|---:|---|---|
| Successful terminal runs / all terminal runs | 99.0% | 30d | SRE | `gonow_run_completed_total` |
| p95 successful run duration | < 60,000 ms | 30d | SRE | `gonow_run_duration_ms` |
| Non-failing validation results / all validation results | 99.5% | 30d | Quality | `gonow_validation_total` |
| Successful recoveries / all recovery attempts | 99.0% | 30d | SRE | `gonow_recovery_attempts_total` |

No SLI groups by run, thread, tenant, user, request, or behavior digest. Empty denominators produce `unknown`, never success.

## Calibration procedure

1. Freeze the query, numerator, denominator, exclusions, time range, deployment version, and Behavior Package digest.
2. Export aggregate counts only; do not export prompt, response, reasoning, secret, PII, or high-cardinality identifiers.
3. Compare the observed distribution with the initial hypothesis and record confidence bounds and missing slices.
4. Propose any threshold change with the old value, new value, measured sample, cost impact, rollback value, and SRE/Product/Security decisions.
5. Run every alert fixture and a no-fire fixture before activating the new threshold.

## Error-budget policy

Fast burn pages SRE and freezes cohort expansion. Slow burn creates a ticket and blocks the next promotion step. A safety or cross-tenant signal bypasses the ordinary budget and activates the applicable kill switch immediately. Error budget cannot offset a security red line.

## Rollback and drill

The first rollback restores the last approved threshold file. Re-run the five named alert fixtures, verify their runbook anchors, and confirm the no-fire fixture remains silent. If no approved previous threshold exists, keep all thresholds at `initial_hypothesis` and keep promotion disabled.
