# Phase 10 repair: Release B 31-day observation contract

Status: `resolved_local`

Scope: `TASK-P10-007`, `TASK-P10-009`, `TASK-P10-010`, `TASK-P10-990`, `TASK-P10-999`, and `TASK-P10-011`

Formal boundary: production activation, elapsed production observation, independent acceptance, merge, push, and Release B PR remain `pending_external`.

## Reproduction

The frozen P10-007 gate minima were 24, 48, 72, 120, and 168 hours. Their sum is 432 hours, while AGENTS.md §§10–11 and execplan.md §§18.4–18.5 require five sequential non-overlapping Release B observation windows totaling at least 31 days, or 744 hours.

Before the repair, P10-009 compared each self-declared `observed_hours` only with its self-declared `required_hours`. It did not bind those values to the P10-007 plan, did not require timestamps, did not detect overlap, and did not enforce a 744-hour total. P10-010, P10-990, P10-999, and P10-011 inherited or trusted that incomplete assertion.

Static contract tests were added first and failed with exit code 1 for both TaskGate and PhaseMerge. Their failure messages identified the absent cross-gate 744-hour/non-overlap contract. No task gate, production rollout, or external mutation was retried during reproduction.

## Root cause and impact surface

The root cause was a modeling error: per-gate minimum windows were treated as if their 432-hour sum were the Release B total observation requirement. The evidence model had durations without an independently checkable temporal interval, and downstream gates bound status claims without revalidating the underlying rollout artifact.

The impact surface was:

- P10-007 could freeze an incomplete rollout plan.
- P10-009 could accept 432 hours, overlapping windows, inflated duration fields, or evidence-defined minimums.
- P10-010 could issue GO without an exact rollout-artifact hash and 31-day revalidation.
- P10-990 and P10-999 could accept or merge the same incomplete evidence.
- P10-011 could open the Release B PR without binding the 31-day observation artifact into its request.

The production allocation remained zero and no production observation existed, so this was a fail-open contract risk rather than an incorrect production acceptance.

## Excluded paths and difficulties

- Raising the five individual hypotheses to arbitrary values was rejected because the hard contract permits low-traffic extension and does not prescribe where the additional 312 hours must occur.
- Summing `observed_hours` alone was rejected because it cannot prove order or non-overlap.
- Trusting timestamps without binding duration was rejected because an interval and declared duration could disagree.
- Trusting P10-009 accepted status downstream was rejected because artifact drift after acceptance would otherwise escape detection.
- Running P10-007 WorksetVerify after changing only one of its two frozen artifacts exposed its two-deliverable provenance contract. The reversible resolution updated both the cohort and stop-rule artifacts in one task-scoped commit, keeping stop rules active throughout any extended window.

## Reversible repair

1. P10-007 now freezes the existing per-gate sample/window minima separately from `minimum_nonoverlap_observation_hours: 744`.
2. Each P10-009 gate must provide offset-bearing `window_started_at` and `window_ended_at` values. The runner recomputes elapsed hours, permits only 0.01-hour tolerance, proves sequence and non-overlap, and requires the measured total to reach 744 hours.
3. The current gate is extended when the total is short; allocation may not increase during that extension and all stop rules remain active.
4. P10-010 revalidates the raw observation and requires its SHA-256 to equal the report's P10-009 artifact binding.
5. P10-990 revalidates the observation and artifact hash; P10-999 repeats the temporal and hash checks before any merge.
6. P10-011 revalidates the observation and binds both rollout-plan and rollout-observation hashes plus the measured total into the PR request.
7. P10-009 and P10-010 blocker records now state that 432 hours is insufficient and list the precise 744-hour recovery condition.

Rollback is a normal revert of commits `430a67b2d99ae305a78f11ef03e5ae85a5aa3a87` through `6c924a5a8640fe64ca4d7be6686600f415b205e3`. No data migration, ref write, external API mutation, production write, or destructive cleanup is involved.

## Affected regression

The executable boundary tests produced these results:

| Check | Result |
|---|---:|
| Exact five-window 744-hour fixture | passed |
| 743-hour fixture | rejected |
| One-hour overlap fixture | rejected |
| TaskGate structural/behavior test | exit 0, 1.257 s |
| PhaseMerge structural/behavior test | exit 0, 1.062 s |
| Phase-entry runner contract test | exit 0, 0.633 s |
| Integration-smoke runner contract test | exit 0, 0.756 s |
| PowerShell parser errors | 0 |
| `git diff --check` exit | 0 |
| Added non-GET HTTPS calls | 0 |
| Added Git push/ref mutation/file deletion commands | 0/0/0 |

The seven P10-007 modes all passed after the repair. `rollout-plan-report.json` records individual minima totaling 432 hours, the distinct hard minimum of 744 hours, non-overlap required, extension action `extend_current_gate`, and stop rules active during extension. TASK-P10-007 remains honestly `ready_for_review` with `reviewer_independent=false`.

Key artifact SHA-256 values:

- `Invoke-TaskGate.ps1`: `150853062913ee4ce048758d94b94cdd042f837336044309831ab235f3c2f6f5`
- `Invoke-PhaseMerge.ps1`: `d56343f281edf6a3f4ee503e81c754bef711a72b2457a014dade0e0427fef95c`
- `rollout-cohorts.yaml`: `30888053fed5ec0c4c9a86e6c717227e9f88aa8463c229300add492b5a0cb008`
- `rollout-stop-rules.yaml`: `873c816128c40dd61b222334789b4ffc3ab43bb889a08c909205304eecfbb8e9`
- `rollout-plan-report.json`: `b68ce290ec3bd08af550f0a281b85bbb6156c593a09fac3724f7b964ad3c72cb`

## STAR

Situation: Release B had a hard 31-day sequential observation requirement, but its executable plan and downstream gates could accept only 18 days of declared durations.

Task: Make the hard requirement mechanically decidable across every acceptance and release boundary without inventing production observations or changing the per-gate hypotheses.

Action: Separated individual and total windows, introduced explicit timestamp/duration binding, enforced non-overlap and 744 hours, kept stop rules active during extension, and propagated raw-artifact revalidation through P10-010/990/999/011.

Result: the baseline admitted a 432-hour representation and had no overlap oracle; the candidate accepts the exact 744-hour fixture and rejects both the 743-hour and overlap fixtures. This is a governance-correctness result, not a claim of production behavior improvement. Security red lines remained zero and formal Release B acceptance remains pending real observations and owners.
