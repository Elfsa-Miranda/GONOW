# BLK-P13-STACK-GITHUB-PR-AUTH

Status: resolved on 2026-08-27

## Reproduction

- `gh auth status` reports no authenticated GitHub host.
- `gh stack` is not installed.
- Authenticated Git transport previously pushed feature branches successfully.

## Error / impact

The environment initially could not create Draft PR objects because GitHub CLI was unauthenticated and the connector lacked write access. The user later reauthorized remote publication, completed GitHub CLI device authentication, and the four local branches were synchronized before PR creation.

## Attempts and outcomes

- Checked `gh auth status`: unauthenticated.
- Checked stack support: extension unavailable.
- Used standard Git branches as allowed by the objective.
- Earlier in the run, pushed all four branch tips once before the user changed the instruction.
- Stopped all remote writes after the user requested local-only commit history.
- Resumed remote writes only after the user explicitly requested that all branches be pushed and the PRs be created.
- Created four Draft PRs with the exact stacked base/head pairs and verified their remote metadata.
- Wrote complete PR bodies under ignored `.codex-local/pr-bodies/`.

## Safe workaround

The delivered Draft PR stack uses these exact bases:

1. `main` ← `feat/context-planner-v2-01-runtime-wiring`
2. PR1 branch ← `feat/context-planner-v2-02-stage-runtime`
3. PR2 branch ← `feat/context-planner-v2-03-overflow-recovery`
4. PR3 branch ← `feat/context-planner-v2-04-eval-release`

## Resolution criteria

Four GitHub PR URLs exist with those bases/heads. This criterion is met. The CI/toolchain gate is resolved; live-provider evidence remains required for release enablement and Ready status.

## Delivered resolution

Delivered Draft PRs: [PR #2](https://github.com/Elfsa-Miranda/GO_NOW/pull/2), [PR #3](https://github.com/Elfsa-Miranda/GO_NOW/pull/3), [PR #4](https://github.com/Elfsa-Miranda/GO_NOW/pull/4), and [PR #5](https://github.com/Elfsa-Miranda/GO_NOW/pull/5). No Ready claim is made while live-provider evidence is absent.

## Truth audit

No credential material was read, copied, or fabricated. Each PR URL and stacked base/head pair was verified after creation.
