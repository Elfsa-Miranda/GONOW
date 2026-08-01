# BLK-P05-001 — Phase 5 local entry and E0 checkout identity

- Status: second failure diagnosed; complete repair implemented; affected regression pending
- Scope: `TASK-P05-001` local `Preflight` and Phase 5 runtime manifest creation
- Production impact: none; no production read/write, deployment, remote push, or merge occurred

## Reproduction

From the clean `codex/phase-05-durable-recovery` worktree at provisional Phase 4 checkpoint `db0dd8dd05e2db8460c01fe4eb73812bcc330263`, the first P05-001 `Preflight` exited `3` with `reason_code=dependency_not_ready`. Its detail reported `dependency_failures=1` while also reporting `local_dependency_projection_valid=true`; no Phase 5 runtime manifest was created.

After adding the local-entry handler, the second Preflight reached cumulative regression and reported `prior_phase_regression_failures=6`. JUnit isolated the first failure to `test_frozen_e0_identity_is_unchanged`: four dataset files and the scoring file no longer matched their frozen SHA-256. The fail-fast unit run stopped at 104 tests, so contract and Flutter execution were not evidence of six distinct product defects.

## Root cause, exclusions, and impact surface

`Invoke-TaskGate.ps1` had task-specific Phase entry materialization only through Phase 4. Its generic dependency loop inspected the formal `TASK-P04-999` prerequisite literally and did not implement AGENTS.md §0.4.1's local substitute of `P04-990 ready_for_review + mechanical gates passed + provisional checkpoint OID`.

The new worktree also exposed a pre-existing portability defect in the Phase 4 freeze: `core.autocrlf=true`, while immutable E0 dataset and P04-000 evidence paths had no explicit Git text attribute. Their committed blobs contained LF, but a clean Windows checkout materialized CRLF. Eleven tracked text artifacts differed from their Git blobs only by line endings; the E0 verifier correctly rejected five inputs and the derived scoring digest.

The Phase 4 source status, source gate hash, local-verification projection, checkpoint commit, exact remote, worktree cleanliness, and formal pending boundary are intact. The affected surface is only Phase 5 local entry validation and evidence creation; Phase 5 product code has not been edited.

## Complete reversible repair

- Add a P05-001 Preflight handler that runs the cumulative Agent CI, four frozen Flutter journeys, and runner contract suite before feature edits.
- Resolve `phase_base_oid` from the last commit that changed the prior P04-990 status record, then separately record the current Phase 5 candidate HEAD; require the checkpoint to be an ancestor so an enabler commit cannot silently become the phase base.
- Create the runtime manifest through the existing create-only `Invoke-PhaseEntryRegression.ps1`, binding `TASK-P04-990`, its status hash, gate evidence hash, BOOT-005 mechanical state, and the exact provisional checkpoint OID.
- Require `phase_5_local_entry_projection_valid=true` locally while retaining independent `P04-999` and P04 acceptance requirements for `formal_adopted` mode.
- Declare the frozen E0 dataset tree and P04-000 evidence tree as `text eol=lf`, then mechanically restore current clean-checkout files to their exact committed blob bytes; do not update frozen hashes or weaken the verifier.
- Do not enable production traffic, writes, push, merge, or accepted status.

Rollback is a revert of the isolated gate-runner enabler and this blocker record; the failed P05 evidence can be retained as diagnostic history. No product schema or runtime state exists to roll back.

## Affected regression and recovery condition

Recovery requires P05-001 Preflight to create and then idempotently revalidate the manifest with base/source drift zero; Agent CI failures/not-run/skips/xfails zero with at least 388 unit and 93 contract tests; 14 Flutter journey assertions passing; runner contract exit zero; exact P04-990 status/gate binding; and production/push/merge counts zero. Formal acceptance remains pending external approval.
