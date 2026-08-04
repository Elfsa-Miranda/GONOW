# STAR: XOR-safe Phase 12 architecture archive

## Situation

The Phase 11 provisional checkpoint had zero of four Phase 12 candidate dispositions documented.
The formal P12-089 gate correctly required accepted Release B and P12-002 XOR evidence, so directly
creating P12A/B/C/D work-package files would either fail or falsely imply multiple selections.

Baseline: candidate disposition coverage `0/4`; formal work-package artifacts `0`; specialist
branches/worktrees `0`; runtime/contract/production-write changes `0`.

## Task

Complete the non-runtime architecture and P12-089 archive requested by the user without weakening
the XOR contract, inventing owner evidence, building Multi-Agent, or changing the running system.

## Action

The repair stores Memory, deterministic cost routing, one Domain Command migration, and explicit
Multi-Agent deferral in common P12-089 documentation rather than formal candidate task paths. It adds
activation/rollback boundaries, threat review, knowledge transfer, honest provisional status, and a
machine gate that rejects formal candidate artifacts, specialist refs/worktrees, implementation
paths, contract changes, secret-like values, and production writes.

Root-cause closure: reproduce the formal dependency/XOR failure; identify that simultaneous formal
candidate materialization is the affected surface; use a reversible common archive; rerun archive,
scope, security, JSON, and prior checkpoint regressions. The formal selection action remains locally
blocked, while safe architecture and evidence work continues.

## Result

Primary governance result: candidate disposition coverage `0/4 -> 4/4`. Diagnostic results:
formal work-package artifacts `0 -> 0`, specialist refs/worktrees `0 -> 0`, and Multi-Agent
implementation count `0 -> 0`. Guardrails: runtime, public contract, schema, dependency, production
write, secret-like finding, and unsafe-command counts remain zero.

The result does not claim a user-visible behavior improvement. Formal P12 selection, independent
review, remote integration, and Release C acceptance remain pending.

## Reproduction and evidence

- Baseline inventory: `git ls-tree -r --name-only 5c3031da4b0df7d1e97af47630e141726502894b -- docs/execution/evidence/phase-12 docs/architecture/release-c-selection.md docs/runbooks/release-c-governance.md docs/api/release-c-selection.md` returns no Phase 12 archive files.
- Candidate gate: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File docs/execution/commands/Verify-Phase12ArchitectureArchive.ps1 -BaseOid 5c3031da4b0df7d1e97af47630e141726502894b`.
- Affected regression: repository diff check plus Phase 11 CI/Python/contract snapshot references in
  the provisional status receipt; no runtime file changed in this repair.
- Artifact hashes are recorded in `docs/execution/evidence/phase-12/P12-089/artifact-hashes.json`.
