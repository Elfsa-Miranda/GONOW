# BLK-P09-002: lazy Candidate semantics fixture

What was observed: `TASK-P09-005` model and targeted analyzer checks passed, while the accessibility fixture repeatedly failed to locate controls below the initial lazy-list viewport.

Blocked action: Candidate UI evidence cannot be marked `ready_for_review` until the full nine-test fixture passes with the real semantics nodes and no skipped checks.

Safest next step: keep the production `ListView`, materialize each target by a stable non-sensitive widget key, inspect its actual `SemanticsNode`, and rerun only the affected analyzer and Candidate fixture before the complete task gate.

## Status

- Severity: P2; local test evidence only, with no production, secret, cross-tenant, or business-write impact.
- Local status: `resolved_local` at `2026-08-02T00:58:46.3626329+08:00`.
- Formal status: `pending_reviewer_disposition`.
- Owner: Mobile.
- Independent reviewer: Product + Security.
- First observed: `unknown` from the compacted prior run; escalation recorded at `2026-08-02T00:45:35.7724133+08:00`, and exact subsequent command timestamps remain in task evidence.

## Reproduction and exclusions

- Run 1: seven offscreen assertions failed because lazily built children did not exist in the initial viewport.
- Run 2: eight of nine tests passed; a semantics-only finder could not serve as the physical pre-materialization scroll target.
- Run 3: the stable key materialized the evidence widget, but a separate global semantics-label finder returned zero matches.
- Run 4: direct node inspection found the required explicit label plus merged descendant text, proving the remaining failure was an overly exact fixture expectation rather than missing accessibility content.
- Run 5: evidence and warning labels passed fragment checks; the existing conflict key resolved the child `CheckboxListTile` semantics boundary and therefore exposed its localized checkbox label instead of the outer live-region warning.
- Run 6: all three semantic-content assertions passed after selecting the wrapper; the locked Flutter framework then rejected the still-active handle before the registered `addTearDown` callback ran.
- Excluded: typed parsing, diff calculation, decision state, audit receipt handling, unapproved business writes, targeted analyzer, and dependency resolution all passed their affected checks.

## Root-cause hypothesis and impact

The fixture conflated physical element materialization with global semantics-tree lookup, exact string equality, and the separate semantics boundary created by `CheckboxListTile`. Flutter's locked `scrollUntilVisible` implementation accepts an element finder and guarantees physical visibility, but it does not make an independent semantics finder the identity of that same node. Wrapping semantics may retain useful descendant text, while a control can expose its own child node. The affected surface is the accessibility proof plus non-sensitive wrapper keys; Candidate data, rendering content, approval state, and business adapters are unchanged.

## Complete reversible repair

1. Keep lazy rendering rather than changing production layout for a test artifact.
2. Add stable, non-sensitive keys to evidence, warning, and conflict wrapper `Semantics` widgets; retain the existing conflict-control key for interaction tests.
3. Scroll by the wrapper key, then assert that the materialized node returned by `WidgetTester.getSemantics` contains the required label while retaining useful descendant text or child-control semantics.
4. Dispose the test-only semantics handle inside `finally`, before Flutter's end-of-test verification.
5. Rerun targeted analyzer and all nine Candidate UI cases once. Continue only on a new diagnostic signal or a complete pass.
6. Run the task-specific Workset, Verify, Security, Evidence, and Rollback gates before status promotion.

## Rollback and recovery

Rollback removes the evidence/warning keys and their test anchors together; the planning feature remains default-off and there is no formal write. Recovery requires targeted analyzer issues `0`, nine tests passed, failures/skips `0`, unapproved business writes `0`, and the task-specific gate suite passing. Reviewer disposition remains pending and does not block other safe local work.

## Local resolution

The minimum reproduction passed, followed by the complete nine-test Candidate fixture, targeted analyzer, WorksetVerify, Verify, Security, Evidence, and RollbackVerify. Final local counts were tests `9/9`, failures/skips `0`, analyzer issues `0`, unapproved business writes `0`, security findings `0`, and unexpected paths/writes `0`. The blocker remains in the phase history for independent review; it is not an `accepted` decision.
