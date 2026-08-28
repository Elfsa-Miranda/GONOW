# Phase 9 local-provisional retrospective

Phase 9 connected the default-off Flutter itinerary route to typed Agent contracts while preserving
ordinary chat and the legacy itinerary path. The candidate finished with 34/34 Harness controls,
542 service unit tests, 144 service contract tests, and 82 Flutter tests passing at the exact local
merge OID. This is a local integration checkpoint, not formal acceptance or a production release.

The main engineering lesson was to keep environment failure separate from behavior failure. The
analyzer baseline was frozen instead of hidden; PostgreSQL role/RLS setup was repaired in one
isolated fixture while unknown production mapping stayed fail-closed; Flutter integration tests were
copied byte-for-byte into a deterministic VM fixture; and a generated status board gained a required
JSON round-trip. At integration smoke, a fresh landing lacked `package_config`, so `--no-pub`
executed 0 tests. Supplying locked pub dependencies and rerunning only the affected Flutter set gave
82/82, while Git clean filters proved all incidental line-ending writes had zero staged blob diff.

STAR evidence remains limited to deterministic local verification entry coverage. No claim is made
for product quality, production reliability, cost, latency, adoption, or real-device behavior. The
production itinerary schema/RLS/grant mapping, independent owner review, real-device run,
production-like rollback, governance adoption, formal P09-999 merge, and remote push remain pending.

Rollback from this checkpoint keeps the feature flag off or engages the kill switch, verifies the
legacy route and compatibility matrix, preserves durable Run/Event/audit/outbox facts, and abandons
the local checkpoint without changing `main` or production data.
