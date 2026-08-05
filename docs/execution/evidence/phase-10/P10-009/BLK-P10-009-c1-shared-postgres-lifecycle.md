# BLK-P10-009 C1 shared PostgreSQL lifecycle

## Summary

The first C1 regression attempt found eight replay subprocesses using an unselected Anaconda environment. After the locked Python path was propagated and the affected replay set passed `10/10`, the second full regression lost the pre-existing PostgreSQL listener on port `55432` during execution. This caused one real failure wave, not 112 independent product defects: all subsequent database tests reported that no connection could be created to `127.0.0.1:55432`.

## Evidence and root cause

- First attempt: Python `837 passed, 8 failed`; every failure ended in `ModuleNotFoundError: alembic` from the base Python replay child. Flutter passed `144/144`.
- Repair: the certification runner now prepends the current service root and selected locked interpreter's `site-packages` to `PYTHONPATH` inherited by process-kill probes. The affected replay/runtime set passed `10/10`.
- Second attempt: the interpreter error was absent. The JUnit result was `721 passed, 13 failed, 112 errors`; the failures/errors after the database outage had the same connection-refused root cause. Flutter again passed `144/144`.
- The listener was a pre-existing Phase 12A PostgreSQL process/data directory rather than a Phase 10-owned service. It was no longer running after the failure, and no PostgreSQL server log owned by this task was available to prove its lifecycle.
- Production writes: `0`; no production endpoint or database was used.

## Repair and recovery condition

The Phase 10-owned PostgreSQL 17.10 cluster at `D:\GO_NOW-c2-postgres-20260805` is now the sole listener on `127.0.0.1:55432`; the former shared cluster remains stopped. The cluster can be moved back to dedicated C2 port `55433` when that shard runs, but only one listener is active at a time.

This blocker closes only when the full Python and Flutter regression completes once on the Phase 10-owned listener with zero failure/error/mandatory skip/xfail/rerun, and the listener remains healthy through report finalization. Historical failure reports are retained in this blocker narrative; the final machine report may be replaced only by the fresh candidate-bound result required by C1.
