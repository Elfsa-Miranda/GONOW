# TASK-P03-006 runner enabler

The Catalog declares P03-006 modes but supplies no task-specific executable
adapter. `Invoke-TaskGate.ps1` therefore adds a reversible, task-scoped adapter
that runs the five real PostgreSQL tests and mechanically proves:

- a rolled-back Event/Outbox transaction leaves zero rows;
- `(consumer_name,event_id)` produces one immutable receipt effect;
- retry exhaustion and unknown outcomes enter an audited metadata-only DLQ;
- repository code exposes no arbitrary SQL executor;
- cross-tenant Event/Outbox mismatch is rejected by PostgreSQL;
- downgrade preserves Runtime Event truth and upgrade rebuilds all delivery tables.

The adapter writes only P03-006 evidence/status and does not change Catalog,
connect an external consumer, publish a message, or touch production.
