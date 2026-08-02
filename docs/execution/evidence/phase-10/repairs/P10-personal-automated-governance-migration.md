# Phase 10 repair: personal automated governance migration

Status: `runner_enabler_validated`

Scope: `AGENTS.md`, `execplan.md`, `ADR-P10-001`, Phase 10 closeout, and Release A/B/C PR governance

## Reproduction

The active repository plan combined two incompatible assumptions:

1. Release B required a sequential 744-hour enterprise observation and distinct human owner/reviewer approvals.
2. The repository owner explicitly directed this personal project to replace elapsed waiting and repeated signatures with deep automated gates, automatic authorization on pass, and a final owner smoke.

If only the P10 observation card were edited, P10-089 would still require a non-implementer, P10-990 would still require independent owner signatures, P10-999 would still reject automatic merge/push, and Release PR cards would still forbid automated merge. The same candidate could therefore pass the new suite and remain mechanically impossible to accept.

## Root cause and impact surface

The root cause was profile conflation: organizational separation-of-duties rules and runtime safety gates were encoded as one indivisible policy. For a personal project, the first category could not add genuine independence, while the second category remained essential.

The impact surface included:

- governance versioning and adoption receipts;
- task status CAS and acceptance semantics;
- P10 certification, handoff, acceptance, phase merge, remote push, and Release B PR tasks;
- Release A/C PR tasks that still hard-coded `auto_merge=false`;
- documentation/STAR evidence that could otherwise overclaim equivalence to production observation.

## Excluded paths and difficulties

- Deleting the enterprise profile was rejected because it would erase a useful future operating mode and make the change harder to reverse.
- Treating a Codex-generated reviewer label as several humans was rejected as false evidence. The replacement is an independent clean execution context plus domain-specific machine checks.
- Replacing 744 hours only with more unit tests was rejected because unit tests do not cover real PostgreSQL, live provider cost/latency, resource slopes, deployment wiring, or operational rollback.
- Assigning a single “percent equivalent” was rejected because coverage depends on the future event distribution and an unknown denominator. The documents instead map risks to tests and name the residual gaps.
- Allowing a general production credential was rejected. The only live path is a minimum-privilege owner canary with a fixed budget, typed writes, kill switch, and zero allocation on failure.
- Automatic merge without exact OID/tree binding was rejected because a green report could otherwise be reused after candidate drift.

## Reversible repair

1. Preserve the 31-day process as inactive `enterprise` profile and activate `personal_automated` through a major governance revision.
2. Define C1–C5 with deterministic, statistical, real-boundary, fault-injection, lifecycle, soak, and rollback requirements.
3. Move owner smoke after C1–C5 and constrain it to owner identity/data, 10–20 journeys, 30–60 minutes, a fixed budget, and an immediate kill path.
4. Replace handwritten approval with an immutable automated attestation that binds candidate OID and all decisive inputs/results.
5. Permit only non-force, expected-OID push/merge actions after attestation; retain all security/data/irreversibility prohibitions.
6. Align P10-089/990/999 and Release A/B/C cards so the active profile is executable end to end.

Rollback is a normal revert of the governance commit followed by guidance reseal. No application code, migration, production data, secret, permission, or feature allocation is changed by this documentation repair.

## Affected validation

This record does not claim that C1–C5 have already run. The documentation candidate must pass at least:

- Markdown whitespace validation with `git diff --check`;
- version/profile/reference consistency scans;
- absence of active `auto_merge=false` and personal-profile human-signature dependencies in P10/Release cards;
- confirmation that enterprise 744-hour text remains present but explicitly inactive;
- confirmation that force push, arbitrary SQL, cross-tenant access, unknown deletion, unbounded spend, and skipped/xfail gates remain prohibited.

Runner/catalog/schema implementation and execution are subsequent P10 engineering work. Until their structured reports exist, Release B is not accepted.

The first compatibility run after the document change produced one expected fail-closed distinction:

| Existing contract test | Exit | Result |
|---|---:|---|
| `Invoke-TaskGate.Tests.ps1` | 1 | correctly exposed the obsolete hard-coded requirement that P10-007/009/010/990/011 retain at least 744 observed hours |
| `Invoke-PhaseMerge.Tests.ps1` | 0 | existing merge safety contract passed |
| `Invoke-PhaseEntryRegression.Tests.ps1` | 0 | existing clean phase-entry contract passed |
| `Invoke-IntegrationSmoke.Tests.ps1` | 0 | existing exact-merge smoke contract passed |

This is not treated as a green document gate or hidden with a threshold change. The affected repair is to introduce profile-aware TaskGate/Catalog/schema handlers for C1–C5 and automatic attestation, retain the 744-hour validator only under `enterprise`, and add negative fixtures proving that neither profile can satisfy the other profile's acceptance path. Only that runner family needs repair; the three passing runner families are not rerun without a relevant code change.

## Remote readiness observation

Two bounded, read-only local `git ls-remote` attempts timed out without returning an authentication rejection. The second attempt disabled terminal prompts and credential interaction, so repeating it would add no new signal. Local `gh` and Git Credential Manager executables are absent. No push, ref update, PR write, or other remote mutation was attempted.

The installed GitHub connector then provided a minimal reversible alternative: read-only repository/profile calls succeeded for canonical repository `Elfsa-Miranda/GO_NOW`, confirmed default branch `main`, exact clone URL `https://github.com/Elfsa-Miranda/GO_NOW.git`, and authenticated `push/admin` permission. Therefore the project owner does not need to paste a GitHub token into chat. Future push may use the connector after automatic acceptance, or local Git may be repaired with a credential helper; either route must preserve expected-OID, non-force, and receipt requirements.

## STAR boundary

Claim type: `governance_conformance`.

Situation: the owner-approved personal release model conflicted with hard-coded enterprise approval and elapsed-time dependencies.

Task: make the personal profile mechanically coherent without weakening runtime security or falsely claiming production observation.

Action: separated governance profiles, mapped observation purposes to C1–C5, bound automatic decisions to exact artifacts, and aligned downstream merge/PR cards.

Result: the candidate has one executable personal acceptance path and one preserved inactive enterprise path. This is a governance-contract correction, not a measured product behavior improvement. Behavioral STAR is `not_applicable` until C1–C5 produce comparable baseline/candidate reports; security redlines remain mandatory zero.

## Runner implementation closure (2026-08-02)

### Reproduction

The first runner implementation exposed three bounded compatibility failures before any formal certification evidence was written:

1. a zero-length PowerShell failure list was pipeline-unrolled to `$null`, so the next failure insertion raised `InvokeMethodOnNull`;
2. Windows PowerShell 5.1 returned the localized/general `CouldNotParseAsPowerShellDataFile` error instead of the previously matched `SafeGetValue` wording;
3. rewriting the one-line Unicode Catalog without its UTF-8 BOM made `Parser.ParseFile` interpret it with the active ANSI code page, while `Parser.ParseInput` over the already-decoded string still passed.

### Root cause and impact surface

The shared root cause was runtime representation drift at three boundaries: empty collection output, PowerShell-version error wording, and file encoding. The affected surface was the C1–C5 aggregator, Catalog loader, Catalog CAS updater, TaskGate contract test, and automatic task-status acceptance path. No application runtime, database, production ref, feature allocation, credential, or external object was affected.

### Reversible repair

- materialize a typed failure list before appending gate failures;
- use the PS5 compatibility loader only after independently checking a single root-hashtable AST, rather than trusting exception text;
- keep the Catalog's canonical UTF-8 BOM and make the updater idempotent with pre-write AST, 153-task/24-mode semantic checks, and an expected-hash CAS;
- add explicit `governance_profile`, `acceptance_method`, and `attestation_sha256` status fields while preserving `reviewer_independent=false` for machine acceptance;
- preserve the 744-hour enterprise validator and route only the active personal profile through C1–C5.

### Affected regression

| Check | Result | Boundary proven |
|---|---:|---|
| `Invoke-PersonalReleaseCertification.Tests.ps1` | pass | one positive and eight negative fixtures; C1–C5 order; 4-hour minimum; redline and cross-profile rejection |
| `Invoke-TaskGate.Tests.ps1` | pass in 72.1s | 153 tasks, 24 modes, personal automatic acceptance contract, preserved enterprise 744-hour validator, existing P11/P12 fixtures |
| Catalog updater second invocation | idempotent pass | zero changed task IDs and stable Catalog SHA |
| `git diff --check` | pass | no whitespace error |

These results prove the runner contract and failure discrimination only. They do not prove that real C1–C5 reports exist, that the 4-hour soak ran, that live provider/PostgreSQL boundaries passed, or that Release B is accepted.
