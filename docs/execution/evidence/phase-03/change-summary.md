# Phase 3 change summary

Before Phase 3, the repository had an Agent process skeleton but no reproducible Runtime database, Run/Event truth, Behavior release registry, outbox receipts, RLS policy set or restore rehearsal. Phase 3 adds those contracts in PostgreSQL while keeping the Agent path disconnected from Flutter and production.

Observable local differences:

- Alembic rebuilds `agent_runtime` and `agent_behavior` through `p03_007_runtime_rls`.
- Run creation is idempotent by tenant/principal/scope/key and request hash. State and Behavior pointer updates use database CAS.
- Event sequence is allocated under a Run row lock; terminal Runs reject new events.
- Job, Lease and checkpoint metadata define later durable-recovery fences but do not run jobs yet.
- Behavior revisions/certifications/releases are immutable and content-addressed; deployment history retains older releases.
- Event-linked outbox delivery has a unique receipt, bounded retry and payload-free dead letter.
- Ten Runtime tables enforce tenant RLS and least-privilege grants.
- A custom-format snapshot/restore rehearsal proves existing-data preservation and reruns CT-007 without claiming production RPO/RTO.

Disablement remains simple: do not deploy or route traffic to Agent API/Worker. On local failure, use the migration and restore runbooks; never relax RLS, grants, CAS, sequence or fencing constraints.
