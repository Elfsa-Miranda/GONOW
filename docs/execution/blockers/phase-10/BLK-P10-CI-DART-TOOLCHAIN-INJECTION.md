# BLK-P10: mandatory Agent CI omitted locked Dart and report isolation

- Severity: P1 release-gate defect
- Status: repaired locally
- First failing gate: `agent-service/scripts/ci.ps1 -Stage All`
- Production impact: none; no deployment, production write, allocation, merge, or remote push occurred

## Reproduction and complete impact surface

The first complete Agent run reached 694 tests and failed only `test_flutter_http_postgres_worker_candidate_journey`: `GONOW_DART_EXECUTABLE` was empty even though Dart 3.11.5 was installed. The GitHub workflow likewise installed only uv/Python/PostgreSQL. After injecting Dart, all Phase10 tests and supply-chain gates passed, but post-run status exposed two additional effects from the same incomplete cross-language CI composition: `flutter pub get` rewrote tracked platform registrants, and tests with default evidence paths rewrote three historical Phase3 reports.

## Reversible repair and regression

`ci.ps1` now resolves an explicit path, an existing scoped binding, BOOT-005 Flutter, or runner PATH in that order; it requires Dart 3.11.5 and restores the caller environment. The three legacy Phase 3 tests that otherwise write canonical evidence by default are redirected to the CI report root across both the complete Unit collection and the second Contract-only collection. Report variables whose tests require an exact canonical path remain unbound; a first over-broad 32-variable redirection failed 21 path-binding assertions and was rejected without changing tracked evidence. A second regression passed 641 Unit and 163 Contract tests but showed that scoping only the first collection still rewrote P03-005 during the second; that scope was rejected and expanded without changing the report contract. An initially clean repository must remain clean. GitHub CI installs Flutter 3.41.7 with full action commit `1a449444c387b1966244ae4d4f8c696479add0b2` (v2.23.0, cache disabled), uses `dart pub get --enforce-lockfile` so package resolution does not generate Flutter platform registrants, and fails if tracked files change before mandatory gates. Static tests bind the action, versions, ordering, scoped sandbox, and clean-tree behavior. Rollback is a non-force revert; Release B remains disabled until the real Flutter-to-HTTP-to-PostgreSQL-to-Worker journey and clean-tree postcondition both pass.
