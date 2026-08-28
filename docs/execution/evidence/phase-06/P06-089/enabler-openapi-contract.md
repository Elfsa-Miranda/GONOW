# P06-089 OpenAPI contract-test enabler

- Reproduction: the existing Phase 2 OpenAPI test required `x-baseline-status=initial` and rejected
  every `/v1/runs` path after the Phase 6 card explicitly required those paths to be documented.
- Root cause and impact: a phase-local absence assertion was encoded as a permanent v1 invariant;
  it blocked only the planned additive Phase 6 contract synchronization.
- Reversible repair: retain `/v1`, OpenAPI `info.version=1.0.0`, every prior path/schema, and add only
  the events/resume/cancel paths. Update the test to require the exact additive set and local
  provisional status. Update the SchemaRegistry's single immutable digest to the new exact contract
  bytes so it continues to reject any unregistered drift.
- Regression: `agent-service/tests/contract/test_openapi.py` plus Phase 6 API/error contract tests.
- Rollback: remove the three additive paths and restore the Phase 2 assertion if all Phase 6 Run
  endpoints are removed. No production, remote, migration, or runtime write occurred.
