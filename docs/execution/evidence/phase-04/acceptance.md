# Phase 4 acceptance report

Candidate implementation tip: `5f51282ed8760db2619e789bf0389f9795693dee`

Phase base OID: `41194ca7e67ca87fc9cc71ec1c76fcbdbc601818`

Execution mode: `local_provisional`

Local projection: `in_progress`

Formal acceptance: `pending_external`

Phase 5 local work may branch only from the later provisional checkpoint after every P04-990 local mode passes. Phase 4 is not accepted; P04-999, remote push/merge, deployment, traffic activation, and production write remain prohibited.

## Outcome

Phase 4 provides one typed single-planner graph with six bounded business stages, six budget fuses, one provider gateway, a static three-tool registry, deterministic context compilation, evidence-backed typed Candidates, immutable Behavior Package pins, legacy bypass, and an offline E0 parity evaluator. It does not expose a new public planning endpoint, activate multi-agent behavior, or write formal business data.

The frozen 40-case E0 dataset produced 80 adapter results with zero semantic field difference, critical mismatch, threshold failure, unexpected dataset drift, PII canary leak, model call, tool call, or production write. This is synthetic local evidence, not production validation.

Fresh local regression: unit tests `388`; explicit contract tests `93`; failed/not-run/skipped/xfailed all zero.

## Harness and security

The shared catalog maps 34 unique controls and 149 minimum cases; 31 controls are implemented, and every control whose first required phase is P4 or earlier is implemented. Missing tests/fragments, skips, xfails, unauthorized execution, dynamic discovery, MCP activation, secret/PII findings, audit gaps, production writes, pushes, and merges are zero.

Applicable CT-001, CT-002, CT-003, CT-004, CT-007, CT-008, CT-012, and CT-013 pass in the local projection. Behavior pointer CAS has one winner and one conflict; old Runs retain their pinned digest, while rollback changes only subsequent Runs.

## Rollback and repair closure

The isolated behavior rollback drill covered three pinned-run scenarios; local duration seconds: `1`.

Resolved blockers: `BLK-P04-000-e0-validator-and-digest` fixed PowerShell native argument quoting and canonical bundle ordering; `BLK-P04-010-powershell-foreach-pipeline` fixed the repeatedly reproduced compound-foreach pipeline parser failure by materializing loop output before piping. The E0 fixture pointer, locale/currency boundary, scanner self-match, and Catalog negative-fixture assumptions were also repaired at their shared causes, and their affected/full regressions passed.

RPO and RTO remain `unknown_not_claimed`; production same-configuration evidence with real in-flight Runs is pending.

## Formal-only pending boundaries

- Independent Engineering, Security, and Eval approvals bound to the immutable candidate.
- Formal governance adoption and authorized landing merge.
- Production provider/tool sandbox, latency, cost, and traffic evidence.
- Production same-configuration rollback drill with real in-flight Runs and measured RPO/RTO.

These external boundaries do not block safe local implementation, but they prevent accepted status, P04-999, remote push/merge, deployment, traffic activation, and production operations.
