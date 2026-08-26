# BLK-P13-STACK-GITHUB-PR-AUTH

Status: open external blocker

## Reproduction

- `gh auth status` reports no authenticated GitHub host.
- `gh stack` is not installed.
- Authenticated Git transport can push feature branches successfully.

## Error / impact

The four review branches can be published, but this environment cannot create Draft PR objects, set their stacked base branches, or mark them Ready. No PR URL may be claimed until a GitHub-authenticated actor performs those actions.

## Attempts and outcomes

- Checked `gh auth status`: unauthenticated.
- Checked stack support: extension unavailable.
- Used standard Git branches as allowed by the objective.
- Pushed PR1, PR2, and PR3 successfully; PR4 is pushed after its final audit.
- Wrote complete PR bodies under ignored `.codex-local/pr-bodies/`.

## Safe workaround

Use the pushed branches and local PR bodies. An authenticated actor must create four PRs with bases exactly:

1. `main` ← `feat/context-planner-v2-01-runtime-wiring`
2. PR1 branch ← `feat/context-planner-v2-02-stage-runtime`
3. PR2 branch ← `feat/context-planner-v2-03-overflow-recovery`
4. PR3 branch ← `feat/context-planner-v2-04-eval-release`

## Resolution criteria

Four GitHub PR URLs exist with those bases/heads. Ready state additionally requires the external gate blocker below to be resolved.

## Delivered resolution

Pending external GitHub authentication. No PR existence or Ready claim is made.

## Truth audit

No credentials were read, printed, copied, or fabricated. Branch push success is not represented as PR creation.
