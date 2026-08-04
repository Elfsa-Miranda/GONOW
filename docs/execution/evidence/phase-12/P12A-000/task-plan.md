# P12A dormant Memory implementation plan

Task: TASK-P12A-000
Selection candidate: 12A
Portfolio mode: dormant_design_ready
Formal dependency status: pending
Formal selection asserted: false
Cycle: pending_formal_selection
P12-002 head: pending
Implementation commit count: 0
Contract change: false
Production write count: 0
Applicable CT: CT-009,CT-015
Acceptance task: TASK-P12A-990
Merge task: TASK-P12A-999

## Frozen architecture markers

- Negative consent
- Conflict state
- Poisoning boundary
- Deletion and export
- Backup non-resurrection
- Single-Agent read port

## Entry and scope

Entry requires an accepted Release B head, accepted P12-002 selecting 12A, a calibrated real trigger,
and owner-approved data purpose. Until then every task below is dormant and has no implementation
branch. The selected package remains inside the existing Agent codebase and the two-process
`agent-api`/`agent-worker` boundary; no multi-agent coordinator, Redis, queue, dynamic MCP market, or
new production service is permitted.

## Proposed atomic tasks

Atomic task: TASK-P12A-010

- Scope: freeze trigger analysis, licensed/de-identified dataset, denominator/exclusions, consent and
  deletion redlines, and accepted Release B comparison head.
- Allowlist after plan approval: dataset manifests, eval fixtures, analysis receipts, no user rows.
- Gate: trigger interval and every slice reproducible; privacy/license gaps and raw-data findings zero.
- Rollback: discard the candidate selection, retain immutable aggregate evidence.

Atomic task: TASK-P12A-020

- Scope: design and migrate typed Memory records, purpose, provenance, retention, Negative consent,
  row-level security, grants, tombstone identity, outbox, and expand-contract rollback.
- Gate: clean migration/restore, cross-tenant/consent denies, schema diff, grant diff, backup
  non-resurrection plan, production write count zero during certification.
- Rollback: keep new columns/tables dormant; do not contract until old code and exports are safe.

Atomic task: TASK-P12A-030

- Scope: Memory Candidate, explicit confirmation, principal/approval reauthorization, CAS,
  idempotency, transactional outbox, and stable Domain Command receipt.
- Gate: forged/replayed/stale/unknown-outcome vectors; model and Worker have no direct formal write.
- Rollback: disable proposal/adopt route, preserve candidates and receipts.

Atomic task: TASK-P12A-040

- Scope: Conflict state, competing-claim provenance, deterministic resolution, poisoning quarantine,
  instruction-as-data handling, and stable materialization policy.
- Gate: retrieved injection executed action count zero; permutation/replay deterministic; conflicts
  never silently overwrite active facts.
- Rollback: quarantine uncertain records and bypass Memory reads.

Atomic task: TASK-P12A-050

- Scope: Deletion and export fanout across primary rows, indexes, caches, candidates, eval derivatives,
  exports, and backups; restore applies tombstones and consent before aliases open.
- Gate: all surfaces unreadable after deletion, export authorization exact, Backup non-resurrection,
  repair idempotent, CT-015 passed without skip/xfail.
- Rollback: deletion never rolls back; repair propagation from the durable tombstone.

Atomic task: TASK-P12A-060

- Scope: principal-aware Single-Agent read port, feature flag/generation, observability, quality and
  latency budgets, CT-009/015, bounded cohort, kill switch, runbook, and Release B equivalence replay.
- Gate: flag-off digest equivalence; tenant/consent/deletion leakage zero; quality/cost/latency meet
  approved values; no Multi-Agent implementation.
- Rollback: allocation zero and Release B Behavior Package; retain audit and compatible data.

## Dependency and merge DAG

`010 -> 020 -> 030 -> 040 -> 050 -> 060 -> P12A-089 -> P12A-990 -> P12A-999`.
Implementation tasks require a plan change that freezes exact file allowlists, commands, datasets,
thresholds, owner identities, and merge IDs. A design-ready receipt is not a substitute for that
change. P12A cannot run in the same Release C cycle as P12B, P12C, or P12D.

## Acceptance evidence

The future package must preserve commands, exit codes, JUnit, migration/restore queries, security
canaries, dataset/price hashes, trace/run/package digests, deletion/export receipts, rollback timings,
STAR metrics, independent reviews, candidate/merge OIDs, and artifact hashes. It must report unknown
or unmeasured values as pending, never as pass.
