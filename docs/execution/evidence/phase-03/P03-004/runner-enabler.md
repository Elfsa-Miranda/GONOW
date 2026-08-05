# TASK-P03-004 runner enabler

- Recorded at: `2026-08-01T06:00:56+08:00`
- Execution mode: `local_provisional`
- Known condition: the sealed runner requires a task adapter for each exact assertion; the already-diagnosed generic placeholder failure was not re-run.
- Reversible repair: register only P03-004's literal files and CT-012/013, Harness 11, security, workset, evidence, and rollback assertions. The Catalog and public contracts remain byte-identical.
- Independence: release immutability, qualified certification, and audit history are database triggers; generation CAS is a single PostgreSQL conditional update. Runner results are evidence, not the runtime enforcement mechanism.
- Rollback: revert this adapter when an equivalent approved adapter supersedes it; pointer rollback itself must CAS to an immutable prior release.
- External effects: none. No Behavior was published, no remote push or production write occurred, and no task was marked `accepted`.
