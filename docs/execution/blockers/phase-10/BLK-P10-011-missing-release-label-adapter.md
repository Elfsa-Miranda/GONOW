# BLK-P10-011: required release labels had no controlled provisioning boundary

- Severity: P1 release-control gap
- Status: repaired locally; remote Apply requires separate explicit authorization
- Affected actions: repository-label prerequisite for `TASK-P10-011` and `TASK-REL-C-001`
- External changes during repair: zero

## Reproduction and root cause

The Release B/Release C PR contract requires `automated-merge-authorized`, `release-b`, `release-c`, and `single-capability` before a PR may be created. A read-only GitHub query on 2026-08-04 found all four absent. The PR adapter correctly failed closed, but no tracked executable could create the prerequisite labels with state CAS, bounded receipts, or a rollback limited to labels created by that action. This was a repository-control implementation gap, not an application/runtime defect.

## Reversible repair

`docs/execution/commands/Invoke-GitHubReleaseLabels.ps1` implements `Verify`, `Plan`, `Apply`, `RollbackPlan`, and `Rollback` against the official GitHub labels REST endpoints. Read-only modes need no token for this public repository. Mutating modes require a process-scoped token, an opaque authorization reference, an actor reference, and the exact current-state SHA-256. The adapter normalizes only the four release labels, includes the immutable GitHub label ID to prevent delete/recreate ABA, hashes rather than records existing descriptions, rejects case collisions, creates only missing names, and never overwrites an existing exact-name label or its owner-chosen metadata.

The create definitions use deterministic colors/descriptions only when a label is absent. The initial choice is reversible and has no product/runtime meaning. Apply writes an atomic prepared receipt before the first mutation and updates the created-label state hash after every successful POST. A partial failure therefore remains diagnosable and reversible. Rollback accepts completed or failed Apply receipts, refuses any per-label drift, and deletes only receipt-created labels whose current state hash still matches; pre-existing labels are never deleted.

## Read-only live result

The real `Plan` performed four GET requests and zero mutations. It reported current state SHA-256 `1d825c917575e0e4ecc6473ab9ae2200440220e631073c4b78d0687a270f7ac3`, desired definition SHA-256 `17a73e06ce7b96d3959d3630dfd1ba6ab78e637fc45dd8fa53734039da039191`, all four labels missing, zero case collisions, and next action `authorized_create_missing_labels_with_expected_current_state_sha256`. No Apply was attempted. API contract reference: `https://docs.github.com/en/rest/issues/labels?apiVersion=2026-03-10`.

## Regression and STAR boundary

The fake-isolated regression covers read-only Plan, global state CAS, label-ID ABA protection, case-collision refusal, create-only-missing behavior, preservation of existing metadata, compliant no-op Apply, token/reference/metadata redaction, receipt-scoped rollback, per-label rollback CAS, and a partial third-create failure retaining an exact reversible receipt. Its bearer sentinel is assembled only at runtime so tracked-source scanning does not contain a credential-shaped literal. It runs from the complete TaskGate suite and `agent-required` workflow. This is governance capability evidence, not a behavior-improvement claim; `behavior_improvement_claim=not_applicable`.
