# Release C governance and rollback runbook

## Current safe state

`formal_selection_status=pending`, `selected_count=0`, and `formal_none_decision=false`. These values
mean there is no Release C capability to enable. Keep all Phase 12 candidate allocations at zero and
continue the Release B-compatible single-Agent path. P12A/B/D design packages are locally reviewable,
but do not create a formal specialist branch/worktree for any candidate, run migrations, change
routing, or infer approval from design readiness. P12C remains absent.

## First checks

1. Verify the worktree branch and clean status, then bind the candidate to a full Git object ID.
2. Verify Release B stable evidence, its manifest hash, and its accepted landing object ID.
3. Verify the REL-C cycle record selects `path=phase12` and is bound to the same Release B head.
4. Verify the evidence window has explicit numerator, denominator, exclusions, uncertainty, and
   redline counts; an initial hypothesis is not a trigger result.
5. Verify P12-000 chooses exactly one of 12A/12B/12C/12D or formal `none`.
6. Verify P12-001 approval and P12-002 reservation bind the same cycle, head, artifact hashes, and
   selection. Mismatch fails closed.
7. Verify unselected task artifacts, branches, worktrees, allocations, and implementation commits are
   all absent.

## Formal selection procedure

Run the repository-owned TaskGate modes in task-card order from the dedicated clean governance
worktree. Do not edit the generated evidence to make a result pass. If the dependency gate returns a
formal-selection or stable-Release-B reason code, preserve that receipt and continue only unrelated
local work until the immutable inputs exist.

The selected design must compare at least two alternatives and no-change across security, data,
compatibility, cost, and rollback. The design then becomes atomic implementation tasks through an
approved plan change; the design task itself has `implementation_commit_count=0`. A second capability
is never appended to the same cycle.

## Enable, disable, and degrade

There is no enable command for the provisional archive.

| Candidate | Enable only after | Disable / first rollback action | Degraded behavior |
|---|---|---|---|
| 12A Memory | selected ADR, privacy/data approval, CT-009/015, deletion/restore drill | allocation zero; disable reads/proposals; retain tombstones/audit | Release B single Agent without Memory |
| 12B cost router | four-week calibrated evidence, certified routes, quality/cost/fallback gates | bypass router; restore previous policy digest; retain budget ledger | current certified route or existing fail-closed policy |
| 12C Multi-Agent | fresh positive XOR cycle and separately approved package | allocation zero; return to one graph; retain experiment evidence | Release B single Agent |
| 12D Domain Command | one named write point, expand-contract plan, CAS/outbox/receipt tests | route bounded cohort to prior authorized writer; retain receipts | legacy compatible write path |

Global rollback order is: stop new allocation, pin the last known-good behavior/route/alias, preserve
evidence and compatible data, replay the Release B equivalence suite, then diagnose. Never roll back
by deleting audit rows, restoring revoked secrets, resurrecting deleted data, force-pushing, or
writing directly to production.

## Failure handling

Use one root-cause loop: reproduce once from a clean state; determine the failing input, environment,
dependency, and impact surface; apply the smallest reversible fix; run the minimum affected check and
then the affected regression set. A second occurrence or plan change requires a blocker record with
the complete hypothesis, excluded paths, repair, rollback, and recovery condition. Do not repeat an
unchanged gate without a new distinguishing signal.

Formal selection missing blocks only formal selection, acceptance, production allocation, remote
merge, and push. It does not block local documentation, fixtures, static checks, or repair work.

## Merge and remote contract

Phase and repair commits land through a history-preserving integration on
`codex/gonow-agent-landing` after the applicable gate and acceptance contract is met.
Never push a Phase branch directly to `main`, and never use this archive to claim that Release C was accepted.
The remote landing branch must match its expected base before merge; drift requires an explicit sync
task and affected regression, not an ad-hoc conflict resolution during merge.

## Audit retention

Retain the Release B evidence manifest, selection analysis, decision/approval references, XOR
reservation, gate results, threat review, rollback evidence, candidate/merge OIDs, and artifact
hashes. Evidence contains hashes and redacted results only; it must not contain secrets, personal
data, full prompts/responses, or hidden reasoning.
