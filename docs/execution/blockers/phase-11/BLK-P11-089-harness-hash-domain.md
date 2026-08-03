# BLK-P11-089 Harness fragment hash-domain mismatch

- Status: repaired locally.
- Reproduction: `HarnessCatalogAggregate` reported 34 unique controls, 149 minimum cases, zero missing implemented test paths, but rejected the valid P11-006 fragment.
- Root cause: the fragment fields `catalog_sha256_before/after` bind `TaskGateCatalog.psd1`, while the aggregator compared them with the separate `harness-test-catalog.yaml` hash.
- Impact: control 23's seven S/I/D citation cases could not be aggregated even though their fragment, status, JUnit-derived counts, and Git object were present.
- Excluded causes: missing test path, control-count drift, minimum-case drift, status downgrade, skipped/xfailed cases, or source fragment absence.
- Reversible repair: compare fragment catalog bindings with the TaskGate Catalog hash, while continuing to record the Harness Catalog hash separately as previous/pre-mutation/new catalog identity. The same correction applies in local and formal execution modes.
- Regression scope: PowerShell parser, TaskGate contract tests, P11-089 Harness aggregation, Evidence, and Workset verification.
- Rollback: revert this repair commit; no catalog content, runtime code, database, external object, or production state is changed.
