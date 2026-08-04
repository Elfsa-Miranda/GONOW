# Capability and difficulty record: Phase 12 A/B/D design readiness

Classification: `capability_presence + governance_conformance`, not `behavior_improvement`.
STAR eligibility: `not_applicable` under AGENTS.md §15.3.1.

## Situation

The common Phase 12 archive described candidates A/B/D but intentionally prohibited their task
artifacts. The user then prioritized completing A/B/D while retaining the single-Agent architecture
and deferring formal Release C selection. The risk was either leaving architecture non-executable or
materializing implementation/selection artifacts that would violate XOR and owner boundaries.

## Task

Produce three complete but dormant work packages with measurable design readiness: each needed an ADR,
at least six unique atomic tasks, security/privacy and reliability contracts, acceptance/merge IDs,
status and immutable evidence, plus an automated gate. Preserve `selected_count=0`, keep P12C absent,
and make zero runtime, contract, schema, dependency, allocation, or production-write changes.

## Action

1. Froze package-specific contracts for explicit Memory, deterministic cost routing, and one-write
   Domain Command migration, including negative/rollback and evidence-selection behavior.
2. Decomposed each into six serial, bounded future tasks with explicit inputs, gates, allowed future
   changes, rollback, independent acceptance, and landing merge.
3. Added a gate that validates required artifacts, exact semantic markers, unique task IDs, status and
   formal boundaries, hash/size binding, forbidden P12C/formal materialization, ref/worktree absence,
   implementation diff, secrets, unsafe commands, whitespace, and production-write counts.
4. Closed two gate defects by root cause: PowerShell scalar collapse was fixed with explicit array
   normalization and exact counts; untracked whitespace blindness was fixed with content scanning for
   added/untracked files while `git diff --check` covers tracked modifications.
5. Re-ran the affected package gate after each repair, then ran the combined portfolio gate.

## Result (coverage evidence, not a STAR improvement)

Primary result formula: `complete_design_ready_packages / planned_packages`.

- Baseline: `0 / 3 = 0%` at landing checkpoint `d850640325904c443a180ebb2dbb0462638ac293`.
- Candidate: `3 / 3 = 100%` after P12A, P12B, and P12D package closure.
- Coverage change: `+100 percentage points`; this is design/governance coverage and MUST NOT be
  reported as system behavior improvement.
- Diagnostic: proposed unique atomic tasks increased from `0` to `18`.
- Diagnostic: passed task-scoped package gates increased from `0/3` to `3/3`.
- Guardrails: formal selected `0`; formal candidate implementation `0`; public contract `0`; schema
  and dependency changes `0`; Multi-Agent implementation `0`; production writes `0`; gate skips and
  xfails `0`.

No product-behavior, quality, cost, latency, Memory, or Domain Command improvement is claimed. The
result is local provisional evidence, not independent review, formal acceptance, or Release C approval.
The actual P12A/P12B/P12D STAR records remain `not_applicable + measurement_pending` until their
machine-readable preregistrations are fully bound and comparable results exist.

## Difficulty evidence

The first gate run returned a misleading package count because a single PowerShell object did not
retain array semantics. Minimal reproduction was task-scoped P12A with all artifacts present. Root
cause was conditional-expression enumeration, affecting single-package readiness and atomic-count
assertions. The reversible fix wrapped the definition in a PSCustomObject, normalized with `@(...)`,
and asserted the expected 1-or-3 package count and six tasks per package; the P12A gate then passed.

The P12B pre-commit check then reported terminal blank lines although the earlier gate passed. Root
cause was `git diff --check <base>` excluding untracked files, affecting every newly created package.
The reversible fix removed both terminal blanks and added direct whitespace scanning for added or
untracked files, with `git diff --check` retaining changed-line coverage for tracked files. The
affected P12B gate passed afterward, and P12D was created under the repaired gate without recurrence.

During common-archive reconciliation, PowerShell 5.1 promoted Git's CRLF safe-conversion warning on
generated runtime receipts to a native-command error even though the structured gate result passed.
The fix disables `core.safecrlf` only for verifier-owned read-only Git invocations, including the
central Git helper and `diff --check`; exit codes, changed-line checks, and added/untracked full-file
checks remain enforced.

The Flutter compatibility run also marked seven generated desktop plugin registrants modified even
though their Git-cleaned object hashes exactly matched the index. Refreshing those exact paths left no
cached diff. Because the document gates' implementation patterns had omitted Linux, macOS, and
Windows, both patterns were expanded so a future real desktop implementation diff fails closed.

## Rollback and limitations

Revert the document and gate commits. No database, runtime, traffic, external provider, public
contract, or production object needs rollback. Formal triggers, real evaluation windows, owner
approval, independent review, implementation, cohort evidence, and remote merge remain pending.
