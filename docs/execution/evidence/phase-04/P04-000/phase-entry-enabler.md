# P04-000 phase-entry projection enabler

## Reproduction

The first P04-000 Preflight ran from a clean Phase 4 worktree at the Phase 3 provisional checkpoint. It returned `dependency_failures=1` while also returning `local_dependency_projection_valid=true` and `formal_dependency_pending=true`. P01-003 and P03-990 were both `ready_for_review`; P03-999 correctly had no accepted status because formal approvals and merge were not available.

## Root cause and impact

The reusable phase-entry helper supports arbitrary phase codes and local projections, but the TaskGate Preflight dispatcher had dedicated manifest paths only through Phase 3. P04-000 fell through to the generic prerequisite loop, which required a literal P03-999 status file and ignored the permitted P03-990 plus checkpoint projection. Only the Phase 4 entry action was affected; prior phase evidence, Runtime code, databases, and external systems were unchanged.

## Reversible repair

P04-000 now has a phase-specific entry path that runs the complete Agent CI, the carried Flutter gateway/validation/redaction/behavior-digest journeys, and the shared runner contract before creating the manifest. The manifest binds the P03-990 status and evidence hash, the P01-003 auxiliary dependency, Catalog and plan hashes, and the clean checkpoint OID. Formal P03-999/P01 approvals remain mandatory for formal mode and remain pending in local mode.

Rollback is a revert of this enabler. It creates only Phase 4 evidence and a create-only manifest; it performs no production write, migration, push, merge, or external action.
