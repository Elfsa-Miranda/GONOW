# TASK-P03-003 runner enabler

- Recorded at: `2026-08-01T05:47:25+08:00`
- Execution mode: `local_provisional`
- Known condition: the inherited 1.4.0 runner has no task-specific mechanical adapter after P03-002. That same root cause was already reproduced and closed during P03-002, so it was not re-run here merely to reproduce the same placeholder failures.
- Reversible repair: register only P03-003's literal file set and exact assertions for Job/Lease/Checkpoint tests, supply-chain audit, security scan, evidence hashing, workset validation, and downgrade/forward rebuild. Catalog bytes and product contracts remain unchanged.
- Impact: the adapter affects only local task evidence. Runtime fencing remains enforced independently by PostgreSQL triggers and repository checks.
- Rollback: revert the runner adapter when an equivalent approved generic adapter supersedes it; revert/downgrade the additive P03-003 migration independently if the runtime candidate is rejected.
- External effects: none. No remote push, production connection, production write, deployment, approval, or `accepted` transition occurred.
