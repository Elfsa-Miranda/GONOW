# Phase 12 provisional architecture archive knowledge transfer

hardest_item_count: 1

## Responsibilities and dependency choices

Product owns the real evidence-based XOR selection. Architecture owns the selected ADR. Security,
Data, Privacy, Eval, Finance, and Domain owners join only when their candidate is selected. The
runtime remains one Agent codebase, `agent-api`, `agent-worker`, PostgreSQL, and static internal tools.
This archive introduces no dependency, process, data store, public interface, or production role.

## Hardest item

The formal P12-089 convergence gate intentionally rejects simultaneous candidate materialization and
requires an accepted P12-002 XOR reservation. The user also requested completion of all non-Multi-
Agent architecture before that external timing loop closes. The root fix was to archive all dormant
candidate guardrails in the common P12-089 documentation area while leaving P12A/B/C/D ADRs, plans,
statuses, branches, and worktrees absent. This preserves the formal runner's future ability to select
exactly one candidate without treating documentation readiness as a decision.

## Operations must know

There is nothing to enable. `selected_count=0` is an archive fact, not a formal `none` selection.
Keep candidate allocation at zero. Start with the Release B evidence head/hash, REL-C cycle/path,
metric window and denominators, P12-000 selection, P12-001 approval, and P12-002 reservation. Any
mismatch or unselected artifact fails closed. Remote integration, when authorized, targets only
`codex/gonow-agent-landing`; never push Phase work to `main`.

## Estimate comparison

The P12-089 card estimates one to two person-days for a formally selected archive. This repair used a
documentation-only common candidate package because formal inputs do not yet exist. No calendar-time
equivalence is claimed. The measurable result is candidate disposition coverage from 0/4 to 4/4,
with runtime, contract, schema, dependency, production-write, specialist-worktree, and specialist-ref
counts remaining zero.

## Handoff verification

Local self-review checks readability, cross-document markers, JSON parsing, absence of formal
candidate materialization, changed-path scope, and safe rollback. It does not impersonate an
independent reviewer and cannot satisfy formal P12-089. Independent Security+Product+Data review and
the formal XOR journey remain `pending_external`.

## Known risks and recovery

The current risk is governance ambiguity if a reader mistakes architecture coverage for Release C
selection. Machine markers, the runbook, README, status receipt, and gate all distinguish the two.
Recovery is to revert only this archive commit; runtime and data are unaffected. If formal evidence
arrives later, run P12-000/001/002 and materialize only the selected work package rather than editing
this receipt into an approval.
