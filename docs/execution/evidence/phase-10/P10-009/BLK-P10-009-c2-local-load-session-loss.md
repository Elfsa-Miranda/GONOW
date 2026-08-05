# BLK-P10-009 C2 local-load session loss

## Plain-language summary

The C2 security matrix passes 100,000 generated boundary attempts, and a three-Run HTTP → PostgreSQL → Worker → Candidate reproduction passes. The mandatory 10,000-Run shard has nevertheless failed twice without producing `c2-postgresql-load.json`. The first observed exception reported `agent_runtime.runs` as absent during the final Worker-role count. Repeating the same large command without a new diagnostic is prohibited; the failure must first be isolated by stage and volume.

## Reproduction and evidence

- Candidate: `9247db288aea71a3478c3b41b411f7b2c2a70f32`.
- Database: task-owned PostgreSQL 17 at `127.0.0.1:55432/gonow_p03_test`; production writes: `0`.
- Frozen load denominator: `10,000` complete local Runs; it has not been reduced.
- The 100,000-attempt `security-matrix.json` completed with zero boundary failure or redline and 100% critical/changed mutation kill rates.
- First 10,000-Run attempt reached the final count path and raised `relation "agent_runtime.runs" does not exist` under the Worker session.
- A clean diagnostic migration then proved 24 migrated tables exist. Under both `gonow_agent_api` and `gonow_agent_worker`, `agent_runtime` schema usage, `agent_runtime.runs` SELECT privilege, `to_regclass('agent_runtime.runs')`, and a qualified count all succeeded.
- A three-Run minimum reproduction completed with `3/3` HTTP starts, `3/3` Worker successes, `3/3` Candidates, and `3/3` terminal Runs.
- The second 10,000-Run attempt again ended without the required load artifact. No production allocation or external write occurred, and the task-owned schemas and fixture roles were cleaned.

## Root-cause hypotheses and excluded paths

Excluded: a missing migration, missing runtime table in a fresh database, missing API/Worker schema usage, missing Worker SELECT grant, a universally broken API composition, or a universally broken Worker transition.

Remaining hypotheses are volume- or lifetime-dependent: a stage-specific connection/session invalidation, an external restart or concurrent task-owned schema cleanup, or an exception swallowed by the per-Run Worker loop before final count. The current harness does not preserve a bounded first-stage exception, so the second attempt did not add enough information to choose among them.

### Root-cause update

The bounded 1,000-Run probe resolved the ambiguity. It accepted three Runs before both `gonow_agent_api` and `gonow_agent_worker` disappeared from the PostgreSQL cluster; the server itself had not restarted. The supposedly task-owned port `55432` was a pre-existing Phase 12A cluster, so another test context could execute the same global fixture-role/schema cleanup while C2 was active. The C2 harness also derived its owner connection from the caller URL but hard-coded its admin connection to port `55432`, which prevented selecting a genuinely isolated cluster.

The harness now derives the admin identity from the same validated loopback endpoint as the owner identity, admits only the existing test port and the dedicated C2 port `55433`, and rejects passwords, query parameters, alternate hosts, users, databases, and ports. A new PostgreSQL 17.10 cluster on `127.0.0.1:55433` has an independent data directory and global-role namespace. Fifteen affected Python contract tests and the PowerShell certification self-test passed. A fresh 1,000-Run staged probe on that cluster completed with 1,000 HTTP starts, 1,000 Worker successes, 1,000 Candidates, 1,000 terminal Runs, and zero RLS leaks.

## Reversible repair plan

1. Run volume-bounded probes that report HTTP-start, Worker, and final-count results separately and stop on the first unexpected exception.
2. Record safe database backend identity and transaction state around the failing stage; never record credentials, request bodies, Candidate bodies, or provider content.
3. If the defect is in the certification harness, add a bounded first-error classification and deterministic stage progress receipt without weakening the 10,000-Run denominator or any C2 threshold.
4. Rerun the smallest affected probe, then exactly one fresh 10,000-Run shard and the C2 aggregator.

Rollback is deletion or one non-force revert of the diagnostic-only harness change. No migration rollback, production data deletion, or threshold change is permitted.

## Recovery condition

This blocker closes only when one fresh, candidate-bound run produces `c2-postgresql-load.json` with exactly 10,000 HTTP starts, Worker successes, Candidates, and terminal Runs; zero start/worker/terminal/RLS failures; and the unchanged API p95 upper bound. The aggregate C2 result must then pass against the already independent DeepSeek v2 live receipts.
