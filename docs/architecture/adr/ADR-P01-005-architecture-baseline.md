# ADR-P01-005: Freeze the v1.6.1 architecture traceability baseline

- status: proposed
- created_at: 2026-08-01T02:15:00+08:00
- decided_at: pending independent Engineering and Security review
- decision_owner: Architecture
- author: codex-local-implementation
- independent_reviewers: Engineering (pending), Security (pending)
- applies_to: Phase 1 traceability and all later local provisional work
- agents_version: 1.4.0
- architecture_version: v1.6.1
- decision_head_oid: bound by TASK-P01-005 evidence at gate execution
- git_object_format: sha1
- evidence_manifest_sha256: bound by `artifact-hashes.json`
- supersedes: none
- superseded_by: none

## Plain-language summary

GoNow needs one unambiguous route from the approved target architecture to implementation tasks and tests. This proposed baseline adopts the mapping in `traceability-v1.6.1-task-map.md` without changing v1.6.1 or AGENTS.md. It keeps current repository facts separate from future contracts so later tasks cannot claim a planned service already exists.

## Context and decision question

The pinned baseline is a Flutter application and does not prove the target Agent runtime exists. AGENTS.md 1.4.0 defines 39 explicit hard-constraint marker occurrences, phase boundaries, and CT-001 through CT-015; execplan.md 1.4.0 schedules their implementation. The question is whether this exact mapping is complete enough to control local provisional implementation while formal owner adoption remains pending.

This ADR does not trigger an architecture change under AGENTS §16.1: it adds no dependency, process, table, API, data use, Release capability, or relaxed invariant.

## Decision drivers and non-negotiable constraints

- Preserve v1.6.1 as the target architecture.
- Keep Current Fact, Target Contract, Initial Hypothesis, and Hard Constraint distinct.
- Map every explicit hard-constraint marker to a Phase/TASK and a numbered CT or an explicit `contract-only` disposition.
- Do not treat local provisional evidence as formal acceptance.
- Do not authorize push, merge, production write, irreversible external action, or Release acceptance.

## Options

| Option | Safety / privacy | Data / deletion | Compatibility / migration | Cost / maintenance | Release / observation | Rollback | Evidence and unknowns |
|---|---|---|---|---|---|---|---|
| A. Versioned complete mapping (selected candidate) | Makes zero-risk gates discoverable | Maps RLS/deletion owners and CTs | Maps legacy retirement gates | One maintained table | Maps rollout and Release gates | Revert this documentation-only candidate | Formal independent review pending |
| B. Per-phase informal notes | Easy to drift or omit constraints | Deletion mapping can fragment | Cross-phase compatibility is unclear | Repeated work | No single completeness proof | Revert notes | Completeness unknown |
| Keep current state | No new runtime risk | No change | Later implementers must reinterpret documents | Highest coordination cost | Hidden omissions likely | No change | No complete mapping artifact |

## Selected option and rationale

Option A is the local provisional candidate because it produces a countable inventory: 39 source markers, 39 unique rows, and zero unmapped rows. It explicitly labels every capability as target, invariant, conditional target, or already evidenced local gate. This is a traceability decision only; independent reviewers must still bind approval to the candidate head before the ADR can become accepted.

## Rejected options

Option B fails to provide a stable completeness check and would repeat interpretation work in every phase. Keeping the current state would leave Phase 2 without a mechanically reviewable handoff and could allow target features to be misreported as current facts. Either option may be reconsidered only through a superseding ADR and corresponding AGENTS/execplan revision when required.

## Consequences and implementation plan

Phase 1 publishes the traceability table. Phase 2 builds the separate service skeleton only along the approved stack and two-process boundary. Later phases must update the mapping through a versioned ADR if a public boundary or hard constraint changes; they must not silently edit this historical proposal into a different decision.

Positive consequence: task and CT ownership is explicit. Negative consequence: the table must be checked when governance versions change. Residual unknown: formal Engineering and Security review has not occurred.

## Verification, observable end state, and rollback

The P01-005 gate must prove 39 unique HC rows, no missing task/CT disposition, no `UNMAPPED` table placeholder, and explicit Current Fact / Target Contract sections. Secret/PII findings, runtime-boundary changes, database changes, and production writes must all be zero. Rollback is a documentation revert; it does not delete legacy code or change runtime behavior.

## Approval

Pending. Local implementation may reach `ready_for_review`; this ADR remains `proposed`. It must not be represented as accepted until independent Engineering and Security actors approve the same complete candidate head OID through the governance process.
