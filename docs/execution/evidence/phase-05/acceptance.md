# Phase 5 acceptance report

Candidate implementation tip: `d057a564edd703b12557586c95d4ab7525c48105`

Phase base OID: `db0dd8dd05e2db8460c01fe4eb73812bcc330263`

Execution mode: `local_provisional`

Local projection: `in_progress`

Formal acceptance: `pending_external`

Phase 6 local work may branch only from the later provisional checkpoint after every P05-990 local mode passes. Phase 5 is not accepted; P05-999, remote push/merge, deployment, production write, and production process termination remain prohibited.

## Outcome

Phase 5 provides durable PostgreSQL Job claim, lease heartbeat/reclaim with monotonic fencing, a strict LangGraph-compatible checkpoint saver, a physical invocation ledger, bounded orphan reconciliation, seven real process-termination scenarios, and PostgreSQL-only API/Worker recovery. Redis and external queues remain absent.

Six Jobs had exactly one owner under ten concurrent claimers. All seven stale Workers were denied after restart. CT-005 and CT-006 passed; budget delta, duplicate side effects, orphan process/database records, missing audit receipts, skipped cases, xfails, and production writes are zero.

Fresh local regression: unit tests `426`; explicit contract tests `96`; failed/not-run/skipped/xfailed all zero.

## Harness and security

The shared Catalog has 34 unique controls and 149 minimum cases. Thirty-three controls are implemented, and every control whose first required phase is P5 or earlier is implemented. Control 14 remains contract-only for Phase 6. Missing test paths/fragments, status downgrades, secret/PII findings, audit gaps, pushes, merges, and production writes are zero.

Applicable CT-001 through CT-008 plus CT-012 and CT-013 pass in the local projection. Unknown external outcomes remain durable and are neither refunded nor blindly retried.

## Rollback and repair closure

The isolated recovery rollback drill covered the seven in-flight kill boundaries plus PostgreSQL-only restart; local duration seconds: `23`.

Resolved blockers: the Phase 5 entry projection repaired missing Flutter dependency hydration without lock drift; the checkpoint lock gap added the exact LangGraph dependency and ADR; the Windows process-identity repair replaced unsafe launcher/PID assumptions with retained-handle identity; the scenario fixture repair made every kill boundary create and prove its own state.

The P05-990 rollback gate initially guessed 14 collected tests although its literal suite contains 13. All 13 had passed; the bounded repair tied the threshold to that explicit collection and the affected drill then passed with every behavioral postcondition unchanged.

RPO and RTO remain `unknown_not_claimed`; authorized same-configuration production evidence is pending.

## Formal-only pending boundaries

- Independent Engineering, Security, Data, and SRE review bound to the immutable candidate.
- Formal governance adoption and authorized landing merge.
- Production database/RLS/provider receipt and traffic evidence.
- Production same-configuration recovery and rollback drill with measured RPO/RTO.

These external boundaries do not block safe local implementation, but they prevent accepted status, P05-999, remote push/merge, deployment, and production operations.
