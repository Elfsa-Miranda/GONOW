# Phase 7 knowledge transfer

## Responsibilities and dependency choices

DomainEng owns typed constraint and validation behavior; Eval owns fixtures and scoring; Security
and SRE own formal solver-boundary review. Pydantic remains the typed boundary. OR-Tools
`9.15.6755` is exact-locked only for the optional isolated path; Redis, a solver service, and a new
network protocol were deliberately not added.

## Hardest items

Three items required root-cause closure. First, the P07-001 runner lost quoted inline-probe arguments
and, after commit, lost the task write set; base64 transport with the correct argument offset plus a
task-start ancestry union restored 15/15 fixtures and zero unexpected paths without changing schema
semantics. Second, P07-004 initially anchored to an older multi-file commit because
`evidence_gate.py` pre-existed the task; requiring the anchor to descend from the task-start CAS head
restored exact workset accounting without changing Evidence Gate behavior. Third, Windows/Python
3.13 native OR-Tools cold import measured 8.9795798 seconds, exceeding the original normal test
deadline. Queue deadlock and model infeasibility were excluded; one-way typed Pipe IPC was retained,
the bounded normal deadline became 15 seconds, and deterministic hang injection moved before native
import so CT-014 tests the intended hard-kill boundary.

## Operations must know

The solver default is off. Canonical validation, Evidence Gate, and bounded repair remain available
without it. On solver degradation, disable first, then inspect stable reason, deadlines, child
liveness, fallback validity, exact dependency evidence, and behavior digest. Never log payloads.
Repair must never exceed two rounds or turn unresolved conflicts into success.

## Estimate and observed evidence

Task-card estimates were planning inputs, not commitments. The local synthetic result is 9/9
mandatory validation/import cases, 8/8 immutable Phase 1 compatibility cases, 4/4 repair cases, and
3/3 solver isolation cases. Local p95 values were 17 ms, 2 ms, and 598 ms for the recorded slices.
Production quality, latency distribution, infrastructure cost, and adoption are unknown; three cost
fields intentionally remain unknown rather than being imputed.

## Handoff verification

The mechanical handoff replays canonical validation, bounded repair, Evidence Gate, CT-014 solver
kill/fallback, and immutable fixture import in one isolated local suite. A pass establishes only a
local candidate. Product+Eval+SRE independent readability/accuracy review, Security/SRE ADR review,
production-like cold-start/rollback evidence, governance adoption, push, merge, deployment, and
formal acceptance remain pending.
