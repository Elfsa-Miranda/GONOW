# P10 owner-canary coordinator enabler

## Reproduction

`TASK-P10-010` freezes `docs/execution/commands/Invoke-PersonalOwnerCanary.ps1` as a tracked, SHA-bound read-only input, but candidate `b12c7b55523396903e5df4b88bca482527fe0c84` contained no file at that path. A name-only readiness audit also showed that all eleven production references remain absent. No environment value was read and no production action was attempted.

## Root cause and impact surface

The TaskGate repair established strict artifact, receipt-ledger, generation-fencing, and automated-attestation validation, while the measured coordinator that must create those source artifacts was still only a planned interface. This blocks the owner-only canary even after P10-009 passes. It does not affect the certified P10-009 candidate, Flutter/API behavior, database schema, C1–C5 measurements, or production state.

## Minimal reversible repair

Added a fail-closed PowerShell coordinator at the frozen path. It:

- accepts only the eleven named process-environment references and never prints their values;
- resolves each command adapter as an absolute `.exe` or `.ps1` leaf, rejects reparse points and shell strings, and binds every sub-adapter by SHA-256;
- passes private runtime references only through UTF-8 JSON stdin and requires exactly one bounded JSON stdout object with empty stderr;
- enforces the fixed lifecycle `baseline zero → owner only → 10–20 journeys across 30–60 minutes → kill switch → old path → final zero`;
- covers all six journey classes, cross-binds independently fetched trace/audit/usage receipts, reconciles cost, and rejects unknown fields;
- derives production/PostgreSQL/live-provider/trace-wiring assertions and every security/reliability zero from typed adapter responses or independent receipts instead of coordinator constants;
- binds all seven sub-adapters by environment-name allowlist and SHA-256 in the report, every external action, every receipt, and every sanitized command row;
- maintains exact continuous generation fencing, a USD `0.25` maximum, zero non-owner allocation/request count, and an emergency kill-switch cleanup attempt if final-zero confirmation fails;
- creates a balanced schedule for every allowed `10–20` journey count so all six mandatory classes remain present even at the minimum count;
- atomically persists each external-action receipt and each trace/audit/usage receipt as it arrives; failed attempts leave a sanitized failure summary and cannot be silently overwritten or retried as a fresh attempt;
- emits the exact report, JSONL receipt ledger, and sanitized command rows consumed by the P10-010 TaskGate. Fake or local execution cannot satisfy the report because the real path requires accepted P10-009 evidence and declares the production boundary in every receipt.

Rollback is a normal revert of this enabler commit. The script performs no action when required references, accepted P10-009 evidence, candidate ancestry, coordinator tracking, or canonical evidence root validation fails.

## Affected regression

`Invoke-PersonalOwnerCanary.Tests.ps1` parses the coordinator, proves all mandatory safety tokens exist, verifies all `10–20` journey schedules cover every class, rejects unknown action/receipt fields, rejects prompt-bearing receipts, exercises single-JSON adapter invocation, verifies complete name-only readiness, verifies one missing adapter fails closed, and asserts secret sentinels never appear in output. The focused suite passes with exit `0`.

The P10-010 consumer validator now independently rejects missing or mismatched runtime-reference hashes, source-adapter identities, trace wiring, live-provider receipts, and granular audit redlines. The coordinator suite and focused P10-010 TaskGate suite passed together in `22.2s`. The instrumented full 153-task TaskGate regression passed once with exit `0` in `344.213s`; an earlier run was terminated only by its `300s` outer timeout and left no child process. The longer successful run is the authoritative regression result and the retained stage markers make future performance diagnosis bounded. `git diff --check` passes. A real production run remains pending the eleven deployment-owned references and cannot be replaced by these local tests.

## STAR classification

Claim type: `capability_presence` plus `governance_conformance`; behavioral improvement is `not_applicable`. The enabler adds the previously missing bounded coordinator and validates fail-closed orchestration, but no production journey, quality, latency, reliability, cost, or user outcome is claimed.
