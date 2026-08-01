# BLK-P06-990 — stale Run-route security fixture

- Status: `resolved_local`; formal Phase 6 approval remains `pending_external`.
- Trigger: the second complete P06-990 regression reached 222 unit tests and failed `tests.security.test_process_boundaries::test_public_contract_has_no_run_execution_route` before the contract partition could start.
- Root-cause hypothesis confirmed: the Phase 2 test encoded the temporary absence of every `/v1/runs*` path. Phase 6 intentionally publishes exactly three governed paths—events, resume, and cancel—so the substring prohibition no longer represented its security intent.
- Excluded paths: the OpenAPI registry digest and Phase 6 public-contract test both match the current document; no arbitrary Run create/execute route exists; no runtime failure, tenant crossing, secret exposure, production write, or schema drift was observed.
- Impact surface: the stale security fixture caused CI fail-fast and prevented the contract report from being produced. It did not affect runtime routing or the published contract bytes.
- Complete reversible repair: parse the JSON-form OpenAPI document; require the exact three approved Run paths with exact HTTP methods; separately prohibit the `/v1/runs` collection route and retain the contract-registry path assertion. Revert this test-only commit to roll back.
- Recovery condition: the exact failing node must pass, followed by the complete CI and runner-contract regression with zero failure, not-run, skip, or xfail.
- External boundary: independent Engineering, Security, and Mobile review, formal governance, P06-999, remote push, formal merge, production deployment/write, and accepted status remain pending and are not inferred.
