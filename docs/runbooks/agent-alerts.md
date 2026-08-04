# Agent alert response playbooks

Every alert below has an owner, a stable anchor, a synthetic firing fixture in `ops/alerts/agent-slo.yaml`, and the same common response sequence: validate the aggregate query, freeze cohort expansion, identify the first bad Behavior Package or deployment, apply the bounded mitigation, and record recovery evidence before resuming.

## Run success fast burn

Owner: SRE. Fixture: `run_success_fast_burn`.

Confirm terminal-run denominators and deployment labels, activate the Behavior kill switch for the affected cohort, retain durable Runs/Events, and compare the legacy route. Escalate any authorization or cross-tenant symptom to Security as P0.

## Run duration slow burn

Owner: SRE. Fixture: `run_duration_slow_burn`.

Inspect bounded run, tool, context, and recovery aggregates. Stop cohort expansion, disable noncritical metrics if exporter pressure contributes, and revert the last approved threshold or Behavior Package only after preserving evidence.

## Validation failure spike

Owner: Quality. Fixture: `validation_failure_spike`.

Separate hard invalid, warning, and unverified outcomes. Keep Candidate import fallback available, disable the affected package, and replay the frozen validation corpus. Never relabel invalid output as success.

## Recovery failure spike

Owner: SRE. Fixture: `recovery_failure_spike`.

Check lease-expired, worker-restart, dependency-timeout, and cancel classes. Stop new claims if fencing is uncertain, preserve checkpoints, and run the restart/recovery drill before reopening claims.

## Adopted task cost guardrail

Owner: Finance. Fixture: `adopted_task_cost_guardrail`.

Verify provider reconciliation and the successfully-adopted denominator. Freeze promotion, lower the cohort or disable the package, and do not average cost improvements against a safety or privacy regression.

## Drill evidence

A passing local drill parses every alert, resolves every runbook anchor, verifies every fixture is unique and expected to fire, and confirms all SLI targets remain labelled `initial_hypothesis`. Production paging, real traffic, and calibration remain pending external evidence.
