# BLK-P10-010 — Personal owner-canary receipt-ledger contract

- Status: `repair_complete_pending_full_regression`
- Scope: P10-010 personal automated owner-only production canary gate
- Candidate base: `13bb7c6d2929ae610f5243cf47afaa8797a6f2a3`
- Production writes: `0`

## Reproduction

The existing P10-010 source validator accepted 64-character receipt identifiers from
`owner-canary-report.json` without requiring the corresponding structured receipt
material. A syntactically valid report could therefore contain random-looking hashes
that were not recomputable from action, trace, audit, or provider-usage facts.

During the focused negative regression, the new unreferenced-row fixture failed twice
before reaching the validator with:
`The property 'subject_id_sha256' cannot be found on this object.`

## Root cause and impact surface

The production-contract root cause was an incomplete evidence graph: report hashes,
the external-action command ledger, the measured adapter, and the underlying receipts
were not joined by one fail-closed predicate. This affected all personal P10-010 source
modes and could have allowed automated attestation from internally consistent but
non-recomputable evidence.

The repeated test failure had a separate, bounded cause: Windows PowerShell wrapped
the JSON-round-tripped collection used by the extra-row negative fixture, so the copied
value did not expose a directly settable row property. The validator itself was not the
failing component.

The measured-adapter negative test then exposed that `git ls-files --error-unmatch`
surfaces an expected untracked-file result as a terminating native stderr record under
`$ErrorActionPreference='Stop'`. The probe now uses the non-erroring cached path list and
compares it exactly, preserving fail-closed behavior without turning a negative predicate
into a runner crash.

The final static review exposed a separate action-semantic inversion: the allocation-zero
baseline predicate required `old_path_available=false`. That would reject a safe canary
whose fallback was already available and accept a baseline without a proven recovery
path. The same complete evidence-graph review found that journey actions were not
temporally joined to their journey windows, journey receipts were not pinned to journey
completion, extra owner-canary command rows were ignored, and required command fields
were matched as independent substrings rather than one canonical command. Duplicate or
unexpected keys could therefore remain ambiguous. Their impact was limited
to P10-010 external-action, receipt-ledger, and command-ledger validation and fixtures.

## Reversible repair

- Require `owner-canary-receipts.jsonl` in the P10-010 Catalog, source Evidence,
  WorksetVerify, security scan, and final artifact manifest.
- Recompute every receipt row hash and require an exact, unique reference from the
  owner report for external actions, journey traces, journey audits, and provider usage.
- Require the ordered action lifecycle `allocation-zero baseline → owner-only enable →
  one bound execution per journey → kill-switch drill → old-path probe → allocation-zero
  final`, with monotonic timestamps and a continuous expected/observed generation chain.
- Require the allocation-zero baseline to prove `old_path_available=true` before owner
  enablement; the inverse is a mandatory negative regression.
- Join every `journey_execute` action timestamp to its referenced journey window, require
  trace/audit/usage receipts at that journey's completion timestamp, and reject extra as
  well as missing or duplicate owner-canary command rows.
- Recompute one fixed-order canonical command string per action and require exact ordinal
  equality; substring matches, duplicate keys, reordered fields, and extra arguments fail.
- Reconcile usage-receipt cost to the report and fail on malformed, missing, mutated,
  duplicate, or extra rows.
- Bind each row and external-action command to candidate, build, Behavior, owner identity,
  tracked adapter path, adapter SHA-256, timestamp, and action-specific facts.
- Verify the fixed adapter path is a tracked, non-reparse-point file and its bytes match
  the reported digest.
- Freeze the WorkPreflight adapter identity, read-only path, ordered arguments, receipt
  target, CAS key, lifecycle, continuous generation fencing, and rollback as exact sets;
  Catalog drift can no longer pass on capability/target alone.
- Freeze the 11 exact name-only references for endpoint, owner identity, scoped credential
  provider, budget cap, journey execution, flag, audit, kill switch, old path, trace, and
  provider usage in
  the same ordered external-action argument contract. The frozen names are
  `GONOW_AGENT_API_URL`, `GONOW_OWNER_CANARY_IDENTITY_REF`,
  `GONOW_OWNER_CANARY_CREDENTIAL_PROVIDER`, `GONOW_RELEASE_B_BUDGET_CAP_REF`,
  `GONOW_RELEASE_B_JOURNEY_ADAPTER`, `GONOW_RELEASE_B_FLAG_ADAPTER`,
  `GONOW_RELEASE_B_AUDIT_ADAPTER`,
  `GONOW_RELEASE_B_KILL_SWITCH_ADAPTER`, `GONOW_RELEASE_B_OLD_PATH_ADAPTER`,
  `GONOW_RELEASE_B_TRACE_ADAPTER`, and `GONOW_RELEASE_B_PROVIDER_USAGE_ADAPTER`;
  their values are neither read into nor emitted by the readiness artifact.
- Generate `owner-canary-input-inventory.json` in Preflight from environment-name
  presence only. The output contains booleans and missing names, never endpoint,
  identity, budget, adapter reference, or credential values; missing inputs block only
  the canary.
- Generate the final certification and automated attestation only after those source
  predicates pass, and carry the adapter and receipt-set hashes into both artifacts.
- Replace the failing extra-row test copy with an explicitly constructed receipt object.

Rollback is a single repair-branch revert; no external allocation, provider, database,
Git remote, or production state was changed.

## Remaining production boundary

A repository-wide tracked-file audit found the typed local control plane in
`agent-service/app/runtime/feature_flags.py`, the authorized generation-fenced controller
in `agent-service/app/runtime/kill_switch.py`, the itinerary API/Domain Command paths, and
the trace/usage primitives. It also proved that the candidate contains no deployment
manifest, persistent production feature-flag adapter, public operator-control route, or
tracked `Invoke-PersonalOwnerCanary.ps1`. The existing control plane is an in-process
object, so its local tests do not prove multi-process production persistence or owner-only
allocation.

Consequently, this repair deliberately validates and freezes the adapter/evidence graph
without creating a no-op adapter or relabelling loopback execution as production. A later
repair/enabler may add a fail-closed coordinator only under an explicit write allowlist;
it must still receive the production endpoint, scoped identity, credential provider,
budget, journey, flag, audit, kill-switch, old-path, trace, and usage adapter references. Until
those external references exist, only P10-010 and its dependent Release acceptance path
remain blocked; the accepted P10-009 candidate and all local evidence remain valid.
The exact external recovery contract is preserved separately in
`BLK-P10-010-production-owner-canary-inputs.md`, including the fail-closed
`owner-canary-journey-adapter/v1` stdin/stdout and independent-receipt protocol; this
avoids carrying obsolete
pre-repair inventory fields into the P10-009 workset.

The frozen-candidate worktree contained three assistant-created, untracked diagnostic
snapshots that P10-009 would correctly treat as out-of-scope. They are retained until C4
finishes, then removed only from that worktree after their identities and replacements
have been recorded here:

- `owner-canary-input-inventory.json` — SHA-256
  `bea2a30b4c8b287f8c5743a37c7fbf50b9b97e0df9d92db585c5ecf04c4dbffd`; superseded by
  the repaired name-only Preflight inventory contract.
- `BLK-P10-010-production-owner-canary-inputs.md` — SHA-256
  `d5d5c43d3d53564e171df1d4adcf177f3b2749dc7ce963e3cf54a8a92014aecf`; superseded by
  the updated production-input blocker on this repair branch.
- `BLK-P10-010-personal-task-gate-contract-drift.md` — SHA-256
  `918816ac827d7c622201d8ac0416f127defacf9b7c78e810155a45f529141273`; superseded by
  this complete reproduction/root-cause/repair/regression record.

All three were confirmed untracked; removing them changes neither the candidate commit
nor any C4 input. The active soak scratch file remains untouched and is expected to be
removed by the soak runner itself.

## Affected regression

- PowerShell parser: runner, Catalog updater, and focused test script — passed after repair.
- Catalog rewrite: `2.2.0`, 24 TaskGate modes, 11 PhaseMerge modes, 153 tasks, and the
  frozen 22-argument P10-010 external action; final SHA-256
  `fdc36b7dabe7519f67bc2dbe3cd2598119417c0006e113352de0370b1186ffe9`.
- Catalog second invocation retained the same SHA-256 and returned
  `idempotent_noop=true` — passed.
- `Invoke-TaskGate.Tests.ps1 -Scope P10-010` — passed after the explicit fixture repair.
- Receipt rows survive JSON/JSONL-equivalent serialization and retain the same canonical
  set hash; tracked, digest-mismatched, and untracked adapter cases are covered.
- Negative coverage includes incomplete action lifecycle, broken generation fencing,
  duplicate journey/action binding, action/receipt timestamp drift, unavailable baseline
  old path, extra command rows, slow kill switch, and audit-count drift.
- Readiness coverage proves complete names pass, missing scoped credential-provider and
  typed journey-adapter references fail independently, an untracked adapter fails, and
  sentinel environment values never
  enter output. The operator-side contract does not require or inspect a model API key;
  provider secrets remain server-side and only sanitized usage receipts cross the boundary.
- Full historical TaskGate regression — pending until the active C4 resource-measurement
  window ends; it is intentionally not run concurrently with the soak.

## Recovery condition

Before merging this repair, rerun the P10-009 current-result modes exactly once at the
immutable candidate after C2/C4 aggregation and after removing obsolete assistant-created
P10-010 temporary diagnostics from that worktree:
`Preflight`, `WorkPreflight`, `WorksetVerify`, `Verify`, `Security`, `Evidence`,
`RollbackVerify`, then `AutomatedAcceptancePreflight`. The ledger replaces prior transient
rows by `check_id`; all eight must be unique and passed. The last mode may perform the
personal-profile status CAS from blocked/in-progress through ready-for-review to accepted,
binding `personal-release-certification.json` and its SHA-256. This must happen while
`HEAD` still equals the certified candidate because P10-009 deliberately requires exact
candidate equality, not ancestry.

Close this blocker after the full TaskGate regression passes and the repair commit is
merged only after that P10-009 automated acceptance has completed.
