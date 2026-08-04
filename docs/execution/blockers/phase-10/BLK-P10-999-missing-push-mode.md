# BLK-P10-999 — PhaseMerge Push mode was not supplied

Status: repaired locally; remote execution remains gated by the exact P10-999 prerequisites.

## Reproduction

- `execplan.md` TASK-P10-999 step 10 requires `Invoke-PhaseMerge.ps1 -Mode Push` and `docs/execution/evidence/phase-10/push.json`.
- Before this repair, `Invoke-PhaseMerge.ps1 -Mode Push` returned `unknown_phase_merge_mode:Push` (exit 2).
- The runner and `TaskGateCatalog.psd1` each registered 11 modes and omitted `Push`; P10-999 and P10-011 therefore could not prove the planned remote refs and receipt.

## Root cause and impact surface

The personal-governance plan revision added the P10-999 remote-push step but did not update the runner, mode registry, catalog task contract, downstream Release B dependency validation, or tests. The omission blocked the Phase 10 phase/landing push and would otherwise have surfaced only after every expensive C1–C5 gate passed.

The plan also requires a receipt created after the immutable `phase_close_oid` is pushed. A Git commit cannot contain its own OID, so committing that post-action receipt into `phase_close_oid` is impossible. The existing close record already resolves the same self-reference constraint with `phase_close_oid_locator='the git commit containing this record'`.

## Reversible repair

- Register a twelfth `Push` mode and allow it only for TASK-P10-999.
- Revalidate the exact local candidate/close OIDs and literal canonical remote URL.
- Snapshot all remote heads, reject known non-fast-forward transitions, and use one atomic, non-force push for only the planned phase and landing refs.
- Re-read every remote head and require exact candidate/close OIDs with zero unexpected ref changes.
- Write identical post-action evidence to the requested `phase-10/push.json` path and the untracked common-Git phase-merge state directory. The tracked close commit is never amended, rebased, or force-updated.
- Make P10-011 consume and hash the exact receipt, binding it into the Release B PR request and automated acceptance attestation.

Assumption: `push.json` is post-close local audit evidence. It is intentionally created after `phase_close_oid` and therefore is not claimed to be contained by that commit.

Impact: the remote phase ref equals `candidate_head_oid`; the remote landing ref equals `phase_close_oid`; `main` and every other remote ref remain unchanged. The landing worktree gains exactly one post-close evidence file after a successful push.

Rollback: before a remote push, revert this repair commit. After a successful push, do not rewrite refs; use a separately gated non-force revert change if later rollback is required, while retaining the push receipt.

## Affected regression

- Isolated bare-remote test proves the two exact ref updates, unchanged `main`, atomic/non-force behavior, idempotent recovery, and tampered-receipt rejection.
- PhaseMerge self-test/AST contract tests cover registration and forbidden destructive commands.
- TaskGate tests cover the 12-mode registry, P10-999 external action, and P10-011 receipt dependency.
- Full TaskGate test suite and workflow lint remain mandatory before integration.
