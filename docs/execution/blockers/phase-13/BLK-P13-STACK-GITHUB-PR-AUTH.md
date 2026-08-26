# BLK-P13-STACK-GITHUB-PR-AUTH

Status: remote publication deferred by user on 2026-08-27

## Reproduction

- `gh auth status` reports no authenticated GitHub host.
- `gh stack` is not installed.
- Authenticated Git transport previously pushed feature branches successfully.

## Error / impact

The four local review branches and commits remain recoverable in the local repository. This environment cannot create Draft PR objects, set their stacked base branches, or mark them Ready. The user explicitly requested no further remote pushes, so the rewritten local PR3/PR4 tips intentionally diverge from their older remote branch tips. No PR URL or remote synchronization claim is made.

## Attempts and outcomes

- Checked `gh auth status`: unauthenticated.
- Checked stack support: extension unavailable.
- Used standard Git branches as allowed by the objective.
- Earlier in the run, pushed all four branch tips once before the user changed the instruction.
- Stopped all remote writes after the user requested local-only commit history.
- Wrote complete PR bodies under ignored `.codex-local/pr-bodies/`.

## Safe workaround

Use the local branches and local PR bodies. If the user later reauthorizes remote publication, an authenticated actor must first push the current local tips, then create four PRs with bases exactly:

1. `main` ← `feat/context-planner-v2-01-runtime-wiring`
2. PR1 branch ← `feat/context-planner-v2-02-stage-runtime`
3. PR2 branch ← `feat/context-planner-v2-03-overflow-recovery`
4. PR3 branch ← `feat/context-planner-v2-04-eval-release`

## Resolution criteria

Remote publication is no longer a completion criterion for the current local-only request. If later reauthorized, four GitHub PR URLs must exist with those bases/heads. The CI/toolchain gate is resolved; live-provider evidence remains required for release enablement.

## Delivered resolution

Local branch and commit history delivered. Remote synchronization and PR creation are intentionally deferred. No PR existence or Ready claim is made.

## Truth audit

No credentials were read, printed, copied, or fabricated. Branch push success is not represented as PR creation.
